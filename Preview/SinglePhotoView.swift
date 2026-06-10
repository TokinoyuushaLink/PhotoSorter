import SwiftUI
import Photos
import AVKit

// MARK: - Single Photo Viewer

struct SinglePhotoView: View {
    let assets: [PhotoAsset]
    let initialIndex: Int
    var enterTrigger: Int = 0            // increment to re-run entry animation (interrupt dismiss)
    let sourceFrame: CGRect
    let getGridFrame: (Int) -> CGRect
    let onIndexChange: (Int) -> Void
    let onDismissBegin: () -> Void     // called at dismiss start so gradient syncs with animation
    // Called with the flat grid index just before the dismiss animation; use to scroll grid into view
    var onBeforeDismiss: ((Int) -> Void)? = nil
    let onDismiss: (Int) -> Void
    var onShortcut: ((Int) -> Void)? = nil
    var panelWidth: CGFloat = 0          // right panel width; photo endRect stops at panel left edge
    var swipeExcludeBottom: CGFloat = 0  // height excluded from swipe zone bottom (floating strip)
    var swipeExcludeRight: CGFloat = 0   // width excluded from swipe zone right (floating panel)
    var useThumbnailFit: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    @State private var currentIndex: Int
    @State private var appeared = false
    @State private var mediaVisible = false   // true after entry animation completes
    @State private var videoPlayers: [Int: AVPlayer] = [:]
    @State private var gifFrames: [Int: GIFContent] = [:]
    @State private var navOffset: CGFloat = 0
    @State private var isGestureActive = false
    @State private var isNavAnimating = false
    @State private var showInspector = false
    @State private var isHoveringVideoArea = false
    @State private var containerGlobalFrame: CGRect = .zero
    @State private var videoLoop: Bool = UserDefaults.standard.bool(forKey: Prefs.videoLoop)

    // Bound to ContentView's focusedFrame so window layout changes (fullscreen) propagate here
    @Binding var dismissSourceFrame: CGRect

    init(assets: [PhotoAsset], initialIndex: Int, enterTrigger: Int = 0,
         sourceFrame: Binding<CGRect>,
         getGridFrame: @escaping (Int) -> CGRect,
         onIndexChange: @escaping (Int) -> Void,
         onDismissBegin: @escaping () -> Void,
         onBeforeDismiss: ((Int) -> Void)? = nil,
         onDismiss: @escaping (Int) -> Void,
         onShortcut: ((Int) -> Void)? = nil,
         panelWidth: CGFloat = 0,
         swipeExcludeBottom: CGFloat = 0,
         swipeExcludeRight: CGFloat = 0,
         useThumbnailFit: Bool = false) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.enterTrigger = enterTrigger
        self.sourceFrame = sourceFrame.wrappedValue
        self.getGridFrame = getGridFrame
        self.onIndexChange = onIndexChange
        self.onDismissBegin = onDismissBegin
        self.onBeforeDismiss = onBeforeDismiss
        self.onDismiss = onDismiss
        self.onShortcut = onShortcut
        self.panelWidth = panelWidth
        self.swipeExcludeBottom = swipeExcludeBottom
        self.swipeExcludeRight = swipeExcludeRight
        self.useThumbnailFit = useThumbnailFit
        _currentIndex = State(initialValue: initialIndex)
        _dismissSourceFrame = sourceFrame
    }


    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                backdrop
                    .opacity(appeared ? 1 : 0)

                neighborCard(offset: -1, containerWidth: w, containerHeight: h)
                currentCard(containerWidth: w, containerHeight: h, containerGlobalFrame: containerGlobalFrame)
                neighborCard(offset: +1, containerWidth: w, containerHeight: h)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
            .overlay(alignment: .topLeading) {
                SwipeNavigationView(
                    containerWidth: max(0, w - swipeExcludeRight),
                    onDrag: { handleDrag(fraction: $0) },
                    onSettle: { settleGesture(direction: $0) }
                )
                .frame(width: max(0, w - swipeExcludeRight),
                       height: max(0, geo.size.height - swipeExcludeBottom))
                .allowsHitTesting(true)
            }
            // Video controls + hover trigger, both pinned to bottom of video area.
            // Trigger zone sits directly above the bottom strip's own hover zone (swipeExcludeBottom),
            // so the two regions share an edge with no gap or overlap.
            .overlay(alignment: .bottomLeading) {
                if assets.indices.contains(currentIndex),
                   assets[currentIndex].mediaType == .video {
                    let videoAreaW = max(0, w - panelWidth)
                    let barW = videoAreaW * 0.7
                    // Trigger height: bar height (~28pt) + 12pt bottom gap + 16pt above bar
                    let triggerH: CGFloat = Layout.videoTriggerHeight
                    ZStack(alignment: .bottom) {
                        // NSTrackingArea — same width as the bar, sits flush above the strip
                        // allowsHitTesting gates NSTrackingArea; disabled until entry animation done.
                        TrackingAreaView { isHoveringVideoArea = $0 }
                            .frame(width: barW, height: triggerH)
                            .allowsHitTesting(mediaVisible)

                        if mediaVisible, let player = videoPlayers[currentIndex] {
                            VideoControlsBar(player: player)
                                .frame(width: barW)
                                .padding(.bottom, 16)
                                .opacity(isHoveringVideoArea ? 1 : 0)
                                .animation(.easeInOut(duration: Anim.fadeInOut), value: isHoveringVideoArea)
                                .allowsHitTesting(isHoveringVideoArea)
                        }
                    }
                    .frame(width: barW, height: triggerH)
                    .offset(x: (videoAreaW - barW) / 2, y: -swipeExcludeBottom)
                }
            }
        }
        .background(KeyMonitorView(onKey: handleKey, onShortcut: onShortcut))
        .overlay(alignment: .topLeading) { inspectorOverlay }
        .background(GeometryReader { bg in
            Color.clear
                .onChange(of: bg.size, initial: true) { _, _ in
                    containerGlobalFrame = bg.frame(in: .global)
                }
        })
        .task(id: enterTrigger) { await enterSequence() }
        .onChange(of: currentIndex) { _, idx in onIndexChange(idx) }
        .onChange(of: assets, handleAssetsChange)
        .onChange(of: mediaVisible) { _, visible in
            guard visible, let player = videoPlayers[currentIndex] else { return }
            player.seek(to: .zero)
            player.play()
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoLoopToggled)) { note in
            if let val = note.object as? Bool { videoLoop = val }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard videoLoop,
                  let item = note.object as? AVPlayerItem,
                  let player = videoPlayers[currentIndex],
                  player.currentItem === item else { return }
            player.seek(to: .zero)
            player.play()
        }
    }

    // MARK: - Body Fragments

    private var backdrop: some View {
        Color.clear
    }

    @ViewBuilder
    private func neighborCard(offset: Int, containerWidth w: CGFloat, containerHeight h: CGFloat) -> some View {
        let idx = currentIndex + offset
        if assets.indices.contains(idx) {
            let rect = CGRect(x: 0, y: 0, width: max(0, w - panelWidth), height: h)
            PhotoCardView(asset: assets[idx], appeared: true,
                          localSourceFrame: nil, videoPlayer: nil, gifContent: nil,
                          containerRect: rect, useThumbnailFit: useThumbnailFit)
                .offset(x: (CGFloat(offset) + navOffset) * w)
                .opacity(appeared ? 1 : 0)
        }
    }

    @ViewBuilder
    private func currentCard(containerWidth w: CGFloat, containerHeight h: CGFloat, containerGlobalFrame gf: CGRect) -> some View {
        if assets.indices.contains(currentIndex) {
            let localSourceFrame: CGRect? = {
                let src = dismissSourceFrame
                guard src.width > Layout.cardSourceFrameMinWidth else { return nil }
                return CGRect(x: src.minX - gf.minX, y: src.minY - gf.minY,
                              width: src.width, height: src.height)
            }()
            let rect = CGRect(x: 0, y: 0, width: max(0, w - panelWidth), height: h)
            PhotoCardView(
                asset: assets[currentIndex],
                appeared: appeared,
                localSourceFrame: localSourceFrame,
                videoPlayer: mediaVisible && !isNavAnimating ? videoPlayers[currentIndex] : nil,
                gifContent: mediaVisible && !isNavAnimating ? gifFrames[currentIndex] : nil,
                containerRect: rect,
                useThumbnailFit: useThumbnailFit
            )
            .offset(x: navOffset * w)
            .id(currentIndex)
        }
    }

    @ViewBuilder
    private var inspectorOverlay: some View {
        if showInspector, assets.indices.contains(currentIndex) {
            ImageInspectorHUD(asset: assets[currentIndex],
                              previewSize: assets[currentIndex].preview?.size,
                              index: currentIndex, total: assets.count)
                .padding(14)
        }
    }

    // MARK: - Entry / Exit

    private func enterSequence() async {
        // Reset in case we're interrupting a dismiss animation
        mediaVisible = false
        withoutAnimation { appeared = false }
        loadMedia(for: currentIndex)
        try? await Task.sleep(for: .milliseconds(Anim.enterDelayMs))
        guard !Task.isCancelled else { return }
        withAnimation(Anim.enter) { appeared = true }
        try? await Task.sleep(for: .milliseconds(Anim.mediaReadyDelayMs))
        guard !Task.isCancelled else { return }
        mediaVisible = true
    }

    private func dismiss() {
        videoPlayers[currentIndex]?.pause()
        runDismissAnimation(index: currentIndex)
    }

    private func runDismissAnimation(index: Int) {
        onDismissBegin()
        isHoveringVideoArea = false
        // Scroll grid so target cell is visible before reading its frame and animating to it
        onBeforeDismiss?(index)
        let target = getGridFrame(index)
        if target != .zero { dismissSourceFrame = target }
        withAnimation(Anim.dismiss) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Anim.dismissDelay) {
            onDismiss(index)
        }
    }

    // MARK: - Navigation

    private func handleKey(_ key: CapturedKey) {
        switch key {
        case .space:     dismiss()
        case .left:      navigateInstant(-1)
        case .right:     navigateInstant(+1)
        case .info:      showInspector.toggle()
        case .playPause: toggleCurrentVideo()
        default:         break
        }
    }

    private func toggleCurrentVideo() {
        guard let player = videoPlayers[currentIndex] else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func handleDrag(fraction: CGFloat) {
        isGestureActive = true
        let hasPrev = assets.indices.contains(currentIndex - 1)
        let hasNext = assets.indices.contains(currentIndex + 1)
        let clamped: CGFloat
        if fraction > 0 { clamped = hasPrev ? min(fraction, 1) : 0 }
        else             { clamped = hasNext ? max(fraction, -1) : 0 }
        withoutAnimation { navOffset = clamped }
    }

    private func settleGesture(direction: Int) {
        isGestureActive = false
        guard appeared else { withoutAnimation { navOffset = 0 }; return }

        let newIndex = currentIndex + direction
        guard direction != 0, assets.indices.contains(newIndex) else {
            withAnimation(Anim.gestureCancel) { navOffset = 0 }
            return
        }

        videoPlayers[currentIndex]?.pause()

        // Commit the index switch immediately and reposition navOffset so the incoming
        // card starts from exactly where it sat during the drag — no jump, no snap.
        //
        // Before:  current at navOffset·w,  incoming (neighbor at +direction) at (direction+navOffset)·w
        // After:   currentIndex = newIndex, navOffset += direction
        //          → new current is still at (direction+navOffset)·w — same pixel position ✓
        //          → old current becomes a neighbor at (−direction + navOffset+direction)·w = navOffset·w ✓
        //
        // Then spring navOffset → 0: incoming card enters, outgoing slides off naturally.
        withoutAnimation {
            currentIndex = newIndex
            navOffset += CGFloat(direction)
            isNavAnimating = true
        }
        withAnimation(Anim.gestureSettle) { navOffset = 0 } completion: {
            isNavAnimating = false
        }

        updateDismissFrame(for: newIndex)
        loadMedia(for: newIndex)
    }

    private func navigateInstant(_ delta: Int) {
        guard appeared, !isGestureActive else { return }
        let newIndex = currentIndex + delta
        guard assets.indices.contains(newIndex) else { return }
        videoPlayers[currentIndex]?.pause()
        withoutAnimation { currentIndex = newIndex; navOffset = 0 }
        updateDismissFrame(for: newIndex)
        loadMedia(for: newIndex)
    }

    private func updateDismissFrame(for index: Int) {
        let frame = getGridFrame(index)
        if frame != .zero { dismissSourceFrame = frame }
    }

    // MARK: - Asset Change Handler

    private func handleAssetsChange(_ oldAssets: [PhotoAsset], _ newAssets: [PhotoAsset]) {
        guard appeared,
              oldAssets.indices.contains(currentIndex),
              !newAssets.contains(where: { $0.id == oldAssets[currentIndex].id }) else { return }
        guard !newAssets.isEmpty else { dismiss(); return }

        let oldIndex = currentIndex
        videoPlayers[oldIndex]?.pause()
        gifFrames.removeValue(forKey: oldIndex)
        videoPlayers.removeValue(forKey: oldIndex)
        let newIndex = min(currentIndex, newAssets.count - 1)

        withoutAnimation { currentIndex = newIndex; navOffset = 0 }
        loadMedia(for: newIndex)
    }

    // MARK: - Media Loading

    private func loadMedia(for index: Int) {
        guard assets.indices.contains(index) else { return }
        let asset = assets[index]
        if asset.mediaType == .video {
            if let player = videoPlayers[index] {
                player.seek(to: .zero)
                if mediaVisible { player.play() }
            } else {
                loadVideo(for: index)
            }
        } else if asset.isGIF {
            loadGIF(for: index)
        }
    }

    private func loadVideo(for index: Int) {
        guard videoPlayers[index] == nil else { return }
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assets[index].id], options: nil).firstObject else { return }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .automatic
        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
            guard let avAsset else { return }
            let item   = AVPlayerItem(asset: avAsset)
            let player = AVPlayer(playerItem: item)
            // KVO: wait for readyToPlay so AVPlayerLayer has a frame before we show it —
            // avoids the black-flash that occurs when the layer renders before decode completes.
            class Holder { var obs: NSKeyValueObservation? }
            let holder = Holder()
            holder.obs = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
                let status = observedItem.status
                guard status == .readyToPlay || status == .failed else { return }
                holder.obs = nil
                guard status == .readyToPlay else { return }
                // Store player without showing yet — display happens when mediaVisible = true
                // so the static preview image handles the entire entry animation (stages 2-4).
                DispatchQueue.main.async {
                    self.videoPlayers[index] = player
                    if index == self.currentIndex, self.mediaVisible { player.play() }
                }
            }
        }
    }

    private func loadGIF(for index: Int) {
        guard gifFrames[index] == nil else { return }
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assets[index].id], options: nil).firstObject else { return }
        let resources = PHAssetResource.assetResources(for: phAsset)
        guard let gifResource = resources.first(
            where: { $0.uniformTypeIdentifier == "com.compuserve.gif" }) else { return }
        let accumulated = NSMutableData()
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(
            for: gifResource, options: opts,
            dataReceivedHandler: { accumulated.append($0) },
            completionHandler: { error in
                guard error == nil,
                      let content = GIFContent(data: accumulated as Data) else { return }
                DispatchQueue.main.async {
                    withoutAnimation { self.gifFrames[index] = content }
                }
            }
        )
    }
}

// MARK: - Photo Card

struct PhotoCardView: View {
    let asset: PhotoAsset
    let appeared: Bool
    let localSourceFrame: CGRect?  // nil for neighbor cards; already in this view's local coordinates
    let videoPlayer: AVPlayer?
    let gifContent: GIFContent?
    var containerRect: CGRect = .zero  // photo fits within this rect; .zero = full geo
    var useThumbnailFit: Bool = false

    var body: some View {
        GeometryReader { geo in
            let area         = containerRect == .zero ? CGRect(origin: .zero, size: geo.size) : containerRect
            let endRect      = fittedRect(aspect: aspectRatio, in: area)
            let animRect     = appeared ? endRect : startRect(endRect: endRect, area: area)
            let cornerRadius: CGFloat = appeared ? 0 : Layout.cardCornerRadius

            // Static image / GIF layer — always follows animRect
            imageLayer(width: animRect.width, height: animRect.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .position(x: animRect.midX, y: animRect.midY)

            // Entry animation: thumbnail fades out as appeared → true
            if let thumb = ThumbnailCache.shared.cachedImage(for: asset.id) {
                if useThumbnailFit {
                    Image(nsImage: thumb)
                        .resizable().scaledToFit()
                        .frame(width: animRect.width, height: animRect.height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .position(x: animRect.midX, y: animRect.midY)
                        .opacity(appeared ? 0 : 1)
                        .allowsHitTesting(false)
                } else {
                    Image(nsImage: thumb)
                        .resizable().scaledToFill()
                        .frame(width: animRect.width, height: animRect.height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .position(x: animRect.midX, y: animRect.midY)
                        .opacity(appeared ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }

            // Video player: fixed at endRect size, scaled down via scaleEffect so SwiftUI
            // spring animation drives the transform (frame changes don't animate on NSView).
            if let player = videoPlayer {
                let scaleX = endRect.width  > 0 ? animRect.width  / endRect.width  : 1
                let scaleY = endRect.height > 0 ? animRect.height / endRect.height : 1
                VideoPlayerLayerView(player: player,
                                     opacity: appeared ? 1 : 0,
                                     cornerRadius: cornerRadius / min(scaleX, scaleY))
                    .frame(width: endRect.width, height: endRect.height)
                    .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
                    .position(x: animRect.midX, y: animRect.midY)
            }
        }
    }

    private var aspectRatio: CGFloat {
        if let img = asset.preview, img.size.height > 0 { return img.size.width / img.size.height }
        return asset.aspectRatio
    }

    private func startRect(endRect: CGRect, area: CGRect) -> CGRect {
        guard let src = localSourceFrame else {
            let sz = min(area.width, area.height) * Layout.cardFallbackSizeRatio
            return CGRect(x: area.midX - sz/2, y: area.midY - sz/2, width: sz, height: sz)
        }
        let cellSide = src.width
        if useThumbnailFit {
            // Compute the sub-rect the image actually occupies inside the square cell (aspect fit)
            let ar = aspectRatio > 0 ? aspectRatio : 1
            let fitW: CGFloat
            let fitH: CGFloat
            if ar >= 1 {
                fitW = cellSide
                fitH = cellSide / ar
            } else {
                fitH = cellSide
                fitW = cellSide * ar
            }
            let ox = src.minX + (cellSide - fitW) / 2
            let oy = src.minY + (cellSide - fitH) / 2
            return CGRect(x: ox, y: oy, width: fitW, height: fitH)
        }
        return CGRect(x: src.minX, y: src.minY, width: cellSide, height: cellSide)
    }

    @ViewBuilder
    private func imageLayer(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if asset.preview == nil && gifContent == nil,
               let thumb = ThumbnailCache.shared.cachedImage(for: asset.id) {
                Image(nsImage: thumb).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
            }
            if let gif = gifContent {
                GIFPlayerView(content: gif)
                    .frame(width: width, height: height)
                    .transition(.identity)
            } else if let img = asset.preview {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
                    .transition(.identity)
            }
        }
        .frame(width: width, height: height)
    }

    private func fittedRect(aspect: CGFloat, in area: CGRect) -> CGRect {
        let w = area.width, h = area.height
        let r: CGRect
        if aspect > w / h {
            let ih = w / aspect
            r = CGRect(x: 0, y: (h - ih) / 2, width: w, height: ih)
        } else {
            let iw = h * aspect
            r = CGRect(x: (w - iw) / 2, y: 0, width: iw, height: h)
        }
        return r.offsetBy(dx: area.minX, dy: area.minY)
    }
}

// MARK: - Inspector HUD

struct ImageInspectorHUD: View {
    let asset: PhotoAsset
    var previewSize: CGSize? = nil
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Inspector  [i to close]")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider()
            row("index", "#\(index + 1) / \(total)  (\(asset.mediaType == .video ? "video" : "photo"))")
            Divider()
            row("localIdentifier", asset.id)
            Divider()
            row("phAsset px", "\(asset.pixelWidth) \u{d7} \(asset.pixelHeight)  (原始像素)")
            row("phAsset ratio", ratioStr(asset.aspectRatio))
            Divider()
            if let t = ThumbnailCache.shared.cachedImage(for: asset.id) {
                let tr = t.size.height > 0 ? t.size.width / t.size.height : 0
                row("thumb.size", "\(fmt(t.size.width)) \u{d7} \(fmt(t.size.height))")
                row("thumb ratio", String(format: "%.3f", tr) +
                    (abs(tr - 1.0) < 0.05 ? "  \u{2248}1:1 \u{2713}" : "  not square"))
                let tReps = t.representations
                row("thumb reps", "\(tReps.count)  " + (tReps.isEmpty ? "(lazy)" :
                    tReps.prefix(1).map { "\(type(of: $0))" }.joined()))
            } else {
                row("thumbnail", "nil (not cached)")
            }
            Divider()
            let uuid = asset.id.components(separatedBy: "/").first ?? asset.id
            let firstChar = String(uuid.prefix(1)).uppercased()
            let diskPath = PhotoLibrary.derivativesBase.map { "\($0)/\(firstChar)/\(uuid)_1_105_c.jpeg" }
            let hasDisk = diskPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            row("preview.src", hasDisk ? "disk (_105_c)" : "PHImageManager")
            if let ps = previewSize {
                row("preview.size", "\(fmt(ps.width)) \u{d7} \(fmt(ps.height))")
            } else {
                row("preview.size", "nil (loading…)")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(width: 280)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
    }

    private func ratioStr(_ r: CGFloat) -> String {
        String(format: "%.4f (%@)", r, r > 1.02 ? "landscape" : r < 0.98 ? "portrait" : "square")
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.0f", v) }
}
