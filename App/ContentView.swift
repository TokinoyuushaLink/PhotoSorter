import SwiftUI
import Photos
import AppKit

// MARK: - ContentView

struct ContentView: View {
    @State private var photosStore: PhotosStore
    @State private var albumsStore = AlbumsStore()
    @State private var sortHistory = SortHistory()
    @State private var showSortedView = false
    @State private var sortedSelectedIDs: Set<String> = []

    @State private var showCommitConfirm = false       // confirm before batch-writing sorted photos
    @State private var showQuitConfirm = false        // quit-time alert (has pending deletes)
    @State private var showQuitUncategorized = false  // quit-time alert (no pending deletes)
    @State private var showRefreshConfirm = false     // refresh alert while in sorted view
    @State private var rightWidth: CGFloat = Layout.columnWidth + 1
    @State private var sidebarVisible: Bool = UserDefaults.standard.object(forKey: Prefs.sidebarVisible) == nil
        ? true
        : UserDefaults.standard.bool(forKey: Prefs.sidebarVisible)

    @State private var focusedID: String?
    @State private var focusedFrame: CGRect = .zero
    @State private var isInSingleMode = false
    @State private var showingPreview = false      // structural: gates isInSingleMode UI rendering
    @State private var previewOpacity: CGFloat = 0 // animation: owned by SinglePhotoView via binding
    @State private var dismissBegun = false        // true from dismiss-begin until SinglePhotoView gone
    @State private var singleModeInitialIndex: Int = 0
    @State private var singleModeCurrentIndex: Int = 0
    // Pending onDismiss work; cancelled if enter interrupts the dismiss animation
    @State private var pendingDismissWork: DispatchWorkItem?
    // Incremented each time we (re-)enter single mode; SinglePhotoView re-runs entry animation
    @State private var singleEnterTrigger: Int = 0
    // Snapshot of the queue shown in SinglePhotoView (全部 or 多选子集)
    @State private var singleModeAssets: [PhotoAsset] = []
    // Briefly show top overlay with hint text when entering multi-select queue
    @State private var multiQueueHint = false
    @State private var statusTextOpacity: Double = 1
    @State private var displayedStatusText: String = ""
    @State private var displayedLargeTitleText: String = ""
    @State private var largeTitleTextOpacity: Double = 1
    @State private var topHintText: String? = nil
    @State private var topHintTask: Task<Void, Never>? = nil
    @State private var gridLayout = GridLayout()
    @State private var stripPressedIndex: Int? = nil
    // sessionID of the spaceDown that triggered the current single-mode entry
    @State private var spaceEnterSessionID: Int? = nil

    private let topGradientH  = Layout.topGradientHeight
    private let stripH        = Layout.stripHeight
    private let stripFadeH    = Layout.stripFadeHeight

    @State private var topGradientOpacity: CGFloat = 0
    @State private var bottomGradientOpacity: CGFloat = 1
    @State private var titlebarHeight: CGFloat = 28
    @State private var autoHideStrip: Bool = UserDefaults.standard.object(forKey: Prefs.autoHideStrip) == nil
        ? true
        : UserDefaults.standard.bool(forKey: Prefs.autoHideStrip)
    @State private var thumbnailFit: Bool = UserDefaults.standard.bool(forKey: Prefs.thumbnailFit)

    init() {
        _photosStore = State(initialValue: PhotosStore())
    }

    private var showOverlays: Bool {
        !showingPreview && !photosStore.assets.isEmpty && !photosStore.isLoading
    }

    // Strip hides while in single mode; starts showing as soon as dismiss begins
    private var stripHiddenInSingleMode: Bool { showingPreview && !dismissBegun }

    @Environment(\.colorScheme) private var colorScheme

    // 渐变始终用黑色；深浅模式的峰值不透明度在各渐变调用处分离
    private let gradientBase: Color = .black

    // 顶部渐变过半（>0.5）时，浅色模式下文字切到白色
    private var topLabelIsWhite: Bool {
        colorScheme == .dark || topGradientOpacity > 0.5
    }

    // 底部渐变过半时，浅色模式下收藏条文字切到白色
    private var bottomLabelIsWhite: Bool {
        let hasPhotos = !photosStore.assets.isEmpty || totalSortedAndDeleteCount > 0
        return hasPhotos && (colorScheme == .dark || bottomGradientOpacity > 0.5)
    }

    // 大标题：随顶部渐变 0→0.5 段淡出；multiQueueHint 时强制隐藏（提示走小标题行）
    private var largeTitleOpacity: Double {
        multiQueueHint ? 0 : max(0, 1 - Double(topGradientOpacity) * 2)
    }
    // 小标题和顶部渐变：multiQueueHint 时强制显示；否则随顶部渐变 0.5→1 段淡入
    private var smallTitleOpacity: Double {
        multiQueueHint ? 1 : max(0, Double(topGradientOpacity) * 2 - 1)
    }

    // 面板总宽度 = 分割线(1pt) + 列浏览器；隐藏时为 0，各层 padding 自动收回
    private var panelTotalWidth: CGFloat { sidebarVisible ? 1 + rightWidth : 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 层 1：照片网格（padding 右边让出面板空间，PhotoGridView 内部 geo 坐标天然正确）
            PhotoGridView(
                store: photosStore,
                focusedID: $focusedID,
                focusedFrame: $focusedFrame,
                gridLayout: gridLayout,
                onOpenPreview: enterSingleMode,
                topGradientOpacity: $topGradientOpacity,
                bottomGradientOpacity: $bottomGradientOpacity,
                topPadding: ((!photosStore.assets.isEmpty || totalSortedAndDeleteCount > 0) && !photosStore.isLoading) ? topGradientH : 0,
                bottomPadding: stripH + stripFadeH,
                useThumbnailFit: thumbnailFit,
                sections: showSortedView ? sortedSections : nil,
                externalSelectedIDs: showSortedView ? $sortedSelectedIDs : nil,
                onSelectAll: showSortedView ? {
                    sortedSelectedIDs = Set(sortedSections.flatMap { $0.assets.map(\.id) })
                } : nil
            )
            .padding(.trailing, panelTotalWidth)

            // 层 2：单图背景遮罩 — opacity由SinglePhotoView通过backdropOpacity binding驱动，
            // 进入/向下拖/取消/dismiss的动画时序完全由SinglePhotoView控制
            Color(colorScheme == .dark ? NSColor.black : NSColor.windowBackgroundColor)
                .ignoresSafeArea()
                .opacity(previewOpacity)
                .allowsHitTesting(false)

            // 层 3：单图预览（宽度限制到面板左边，照片动画在网格侧内运动）
            if isInSingleMode { singlePhotoView.transition(.identity) }


            // 层 4：渐变 + 标题文字（在 SinglePhotoView 上方，进入单图时淡出）
            if (!photosStore.assets.isEmpty || totalSortedAndDeleteCount > 0) && !photosStore.isLoading {
                VStack(spacing: 0) {
                    topGradientOverlay.opacity(multiQueueHint ? 1 : smallTitleOpacity)
                    Spacer()
                }
                .padding(.trailing, panelTotalWidth)
                .allowsHitTesting(false)
                .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
                .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

                smallTitleOverlay
                    .padding(.trailing, panelTotalWidth)
                    .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
                    .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

                largeTitleOverlay
                    .padding(.trailing, panelTotalWidth)
                    .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
                    .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(
                        colors: [gradientBase.opacity(0), gradientBase.opacity(colorScheme == .dark ? 0.65 : 0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: stripFadeH + stripH)
                    .opacity(bottomGradientOpacity)
                }
                .padding(.trailing, panelTotalWidth)
                .allowsHitTesting(false)
                .opacity(1 - previewOpacity)
            }

            // 层 5：底部收藏条（网格侧浮层，不延伸到右侧面板）
            VStack(spacing: 0) {
                Spacer()
                AlbumStripCombined(
                    favoriteNodes: albumsStore.favoriteNodes,
                    recentNodes: albumsStore.recentNodes,
                    onAssign: assignToAlbum,
                    onReorderFavorites: albumsStore.reorderFavorites,
                    isInSingleMode: stripHiddenInSingleMode,
                    autoHideInSingleMode: autoHideStrip,
                    forceLightText: bottomLabelIsWhite,
                    pressedIndex: stripPressedIndex
                )
            }
            .padding(.trailing, panelTotalWidth)

            // 层 6：右侧面板（右对齐浮动，始终可交互）
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ResizeDivider(width: $rightWidth, minWidth: Layout.columnWidth + 1, maxWidth: 520, side: .right)
                ColumnBrowserView(
                    roots: albumsStore.roots,
                    albumsStore: albumsStore,
                    onAssign: assignToAlbum
                )
                .frame(width: rightWidth)
                .background(.ultraThickMaterial)
                .animation(Anim.enter, value: previewOpacity > 0.5)
            }
            .offset(x: sidebarVisible ? 0 : 1 + rightWidth)
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)

            // 层 7.5：标题栏区域 + 右侧控件（侧边栏按钮；模式切换在其下方）
            // MovableTitleBarBackground 垫底保证未命中按钮的点击仍可拖动窗口
            VStack(spacing: 0) {
                MovableTitleBarBackground()
                    .frame(height: Layout.titlebarAreaHeight)
                    .overlay(alignment: .trailing) {
                        Button(action: toggleSidebar) {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    previewOpacity > 0.5
                                        ? Color.primary.opacity(0.35)
                                        : (!sidebarVisible && !topLabelIsWhite
                                            ? Color.accentColor
                                            : (topLabelIsWhite ? Color.white : Color.primary))
                                )
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("显示/隐藏相册面板 (⌘\\)")
                        .padding(.trailing, sidebarVisible ? 1 + rightWidth + 2 : 4)
                        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)
                        .animation(.easeInOut(duration: Anim.fadeInOut), value: previewOpacity > 0.5)
                        .animation(.easeInOut(duration: Anim.fadeInOut), value: topLabelIsWhite)
                    }

                if !showingPreview && totalSortedAndDeleteCount > 0 {
                    HStack(alignment: .center, spacing: 4) {
                        Spacer()
                        Button {
                            showCommitConfirm = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 18, height: 18)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.white)
                            }
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("确认分类（将所有已分类照片写入相册）")
                        modeSwitchControl
                            .padding(.trailing, 0)
                    }
                    .padding(.trailing, sidebarVisible ? 1 + rightWidth + 10 : 42)
                    .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)
                    .transition(.opacity)
                    .confirmationDialog(
                        "确认分类",
                        isPresented: $showCommitConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("确认分类") { commitAll() }
                            .keyboardShortcut(.defaultAction)
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将 \(totalSortedAndDeleteCount) 张照片写入对应相册，此操作不可撤销。")
                    }
                }

                Spacer()
            }
            .animation(.easeInOut(duration: Anim.fadeInOut), value: previewOpacity > 0.5)
            .animation(.easeInOut(duration: Anim.fadeInOut), value: totalSortedAndDeleteCount > 0)

            // 层 7：全局反馈层
            if needsPermission { permissionOverlay }

            GlobalKeyMonitor()
                .allowsHitTesting(false)

            UndoRedoMonitor(
                canUndo: sortHistory.canUndo,
                canRedo: sortHistory.canRedo,
                onUndo: undoLastAction,
                onRedo: redoLastAction,
                onDelete: showSortedView && !isInSingleMode ? returnSelectedToUncategorized : nil,
                onCmdDelete: moveSelectedToPendingDelete,
                onToggleSidebar: toggleSidebar
            )
            .allowsHitTesting(false)
        }
        .onAppear {
            photosStore.checkCurrentAuthorization()
            albumsStore.reload()
            displayedStatusText = statusText
            displayedLargeTitleText = largeTitleSource
        }
        .onChange(of: statusText) { oldText, newText in
            func prefix(_ s: String) -> String { s.components(separatedBy: CharacterSet.decimalDigits).first ?? s }
            if prefix(oldText) == prefix(newText) {
                displayedStatusText = newText
            } else {
                withAnimation(.easeInOut(duration: Anim.fadeInOut)) { statusTextOpacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + Anim.fadeInOut) {
                    displayedStatusText = newText
                    withAnimation(.easeInOut(duration: Anim.fadeInOut)) { statusTextOpacity = 1 }
                }
            }
        }
        .onChange(of: largeTitleSource) { oldText, newText in
            func prefix(_ s: String) -> String { s.components(separatedBy: CharacterSet.decimalDigits).first ?? s }
            if prefix(oldText) == prefix(newText) {
                displayedLargeTitleText = newText
            } else {
                withAnimation(.easeInOut(duration: Anim.fadeInOut)) { largeTitleTextOpacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + Anim.fadeInOut) {
                    displayedLargeTitleText = newText
                    withAnimation(.easeInOut(duration: Anim.fadeInOut)) { largeTitleTextOpacity = 1 }
                }
            }
        }
        .onChange(of: photosStore.authStatus) { _, status in
            guard status == .authorized || status == .limited else { return }
            photosStore.loadUncategorized()
            albumsStore.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
            if totalSortedAndDeleteCount > 0 {
                showRefreshConfirm = true
            } else {
                photosStore.loadUncategorized()
                albumsStore.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoHideStripToggled)) { note in
            if let val = note.object as? Bool { autoHideStrip = val }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailFitToggled)) { note in
            if let val = note.object as? Bool { thumbnailFit = val }
        }
        // Space down: enter single mode, record sessionID so SinglePhotoView can ignore this release.
        .onReceive(NotificationCenter.default.publisher(for: .spaceDown)) { note in
            guard let ev = note.object as? SpaceKeyEvent else { return }
            guard !isInSingleMode else { return }
            spaceEnterSessionID = ev.sessionID
            enterSingleMode()
        }
        // Number key up (short press only) → assign
        .onReceive(NotificationCenter.default.publisher(for: .keyUp)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            let nodes = albumsStore.favoriteNodes
            guard nodes.indices.contains(key) else { return }
            assignToAlbum(nodes[key])
            stripPressedIndex = key
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnHighlightDelay + Anim.columnClearDelay) {
                if stripPressedIndex == key { stripPressedIndex = nil }
            }
        }
        // Number key long-press start → show strip highlight
        .onReceive(NotificationCenter.default.publisher(for: .keyLongPress)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            stripPressedIndex = key
        }
        // Number key long-press end → clear highlight (no assign)
        .onReceive(NotificationCenter.default.publisher(for: .keyLongPressEnd)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnClearDelay) {
                if stripPressedIndex == key { stripPressedIndex = nil }
            }
        }
        // Quit alert: pending deletes exist → block and warn user to delete first
        .alert("还有待删除的照片", isPresented: $showQuitConfirm) {
            Button("返回") {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        } message: {
            Text("有 \(sortHistory.pendingDeleteAssets.count) 张照片在「待删除」分组中尚未删除。\n请先点击垃圾桶图标完成删除，再退出。")
        }
        // Quit alert: has classified photos → confirm and write to Photos on confirm
        .alert("确认归类", isPresented: $showQuitUncategorized) {
            Button("确认归类并退出") {
                commitAllAndQuit()
            }
            Button("取消", role: .cancel) {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        } message: {
            let sorted = sortHistory.totalSortedCount
            let uncategorized = photosStore.assets.count
            if uncategorized > 0 {
                Text("将把 \(sorted) 张照片写入相册，还有 \(uncategorized) 张未归类照片将保留。")
            } else {
                Text("将把 \(sorted) 张照片写入相册。")
            }
        }
        // Refresh alert: in sorted view with pending operations → confirm discard
        .alert("确认刷新", isPresented: $showRefreshConfirm) {
            Button("确定", role: .destructive) {
                sortHistory.clearAll()
                showSortedView = false
                sortedSelectedIDs = []
                photosStore.loadUncategorized()
                albumsStore.reload()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("刷新将清除所有已分类操作（共 \(totalSortedAndDeleteCount) 张），此操作不可撤销。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldTerminateWithConfirm)) { _ in
            if sortHistory.hasPendingDeletes {
                showQuitConfirm = true
            } else if sortHistory.totalSortedCount > 0 {
                showQuitUncategorized = true
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmDeletePending)) { _ in
            permanentlyDeletePending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sortedSelectionShouldClear)) { _ in
            sortedSelectedIDs = []
            focusedID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .sortedViewShouldDismiss)) { _ in
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { showSortedView = false }
            sortedSelectedIDs = []
            focusedID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetsDidSort)) { note in
            if let msg = note.object as? String { showTopHint(msg) }
            guard !showSortedView, photosStore.assets.isEmpty, totalSortedAndDeleteCount > 0 else { return }
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { showSortedView = true }
            photosStore.clearSelection()
            focusedID = nil
        }
    }

    // MARK: - Top gradient overlay (gradient only, no text)

    private var topGradientOverlay: some View {
        LinearGradient(
            colors: [gradientBase.opacity(colorScheme == .dark ? 0.6 : 0.45), gradientBase.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: topGradientH)
    }

    // MARK: - Top labels

    // 小标题层：固定在 titlebar 区域（38pt），不随全屏模式变化
    private var smallTitleOverlay: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 1) {
                    Text("PhotoSorter")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(displayedStatusText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .opacity(statusTextOpacity)
                        .animation(.easeInOut(duration: Anim.fadeInOut), value: statusTextOpacity)
                }
                .opacity(multiQueueHint || topGradientOpacity > 0.5 ? 1 : 0)
                .animation(.easeInOut(duration: Anim.fastFade), value: topGradientOpacity > 0.5)
                .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Layout.titlebarAreaHeight)
            .allowsHitTesting(false)

            Spacer().allowsHitTesting(false)
        }
    }

    private func updateTitlebarHeight() {
        guard let win = NSApp.mainWindow else { return }
        let h = win.frame.height - win.contentLayoutRect.maxY
        if abs(h - titlebarHeight) > 0.5 { titlebarHeight = h }
    }

    // 已分类模式：大标题显示状态文字，无副标题
    // 未归类模式：大标题显示 app 名，副标题显示状态文字
    private var largeTitleSource: String { showSortedView ? statusText : "PhotoSorter" }

    // 大标题层：用 NSWindow.contentLayoutRect 算出的真实 titlebar 高度定位，全屏窗口化均正确
    private var largeTitleOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayedLargeTitleText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .opacity(largeTitleTextOpacity)
                .id(showSortedView)
                .transition(.opacity)
            if !showSortedView {
                Text(displayedStatusText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .opacity(statusTextOpacity)
                    .animation(.easeInOut(duration: Anim.fadeInOut), value: statusTextOpacity)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 16)
        .padding(.top, titlebarHeight + 10)
        .opacity(largeTitleOpacity)
        // showingPreview / multiQueueHint 触发时带动画淡出，独立于 topGradientOpacity 驱动的渐变逻辑
        .opacity(multiQueueHint ? 0 : 1 - previewOpacity)
        .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: Anim.fadeInOut), value: showSortedView)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in updateTitlebarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in updateTitlebarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in updateTitlebarHeight() }
        .onAppear { updateTitlebarHeight() }
    }

    @Namespace private var modeSwitchNS

    private var modeSwitchControl: some View {
        HStack(spacing: 0) {
            modeButton(title: "未归类", count: photosStore.assets.count, active: !showSortedView) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { showSortedView = false }
                topGradientOpacity = 0
                bottomGradientOpacity = 0
                sortedSelectedIDs = []
                focusedID = nil
            }
            modeButton(title: "已分类", count: totalSortedAndDeleteCount, active: showSortedView) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { showSortedView = true }
                topGradientOpacity = 0
                bottomGradientOpacity = 0
                photosStore.clearSelection()
                focusedID = nil
            }
        }
        .background(
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }

    private func modeButton(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if active {
                            Capsule().fill(Color.accentColor)
                                .matchedGeometryEffect(id: "modePill", in: modeSwitchNS)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subviews

    private var permissionOverlay: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("需要照片库权限")
                    .font(.title2.weight(.semibold))
                if photosStore.authStatus == .denied || photosStore.authStatus == .restricted {
                    Text("请前往\n系统设置 → 隐私与安全性 → 照片\n开启 PhotoSorter 的访问权限。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text("PhotoSorter 需要访问您的照片\n才能显示和整理未分类的图像。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("授权访问") { photosStore.requestAuthorization() }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(40)
        }
    }

    // MARK: - Computed

    private var totalSortedAndDeleteCount: Int {
        sortHistory.totalSortedCount + sortHistory.pendingDeleteAssets.count
    }

    private var sortedSections: [SectionData] {
        var secs = sortHistory.groupedByAlbum.map {
            SectionData(header: $0.albumNode.title, assets: $0.assets)
        }
        if !sortHistory.pendingDeleteAssets.isEmpty {
            let sorted = sortHistory.pendingDeleteAssets.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            secs.append(SectionData(header: "待删除", assets: sorted, isDeleteGroup: true))
        }
        return secs
    }

    private var needsPermission: Bool {
        photosStore.authStatus == .notDetermined
        || photosStore.authStatus == .denied
        || photosStore.authStatus == .restricted
    }

    private var statusText: String {
        if let hint = topHintText { return hint }
        if multiQueueHint { return "已进入多选队列（\(singleModeAssets.count) 张）" }
        if showSortedView {
            let sel = sortedSelectedIDs.count
            let total = totalSortedAndDeleteCount
            if sel > 0 { return "已选 \(sel) / \(total) 张（已分类）" }
            return "已分类 \(total) 张"
        }
        let sel   = photosStore.selectedIDs.count
        let total = photosStore.assets.count
        if sel > 0 { return "已选 \(sel) / \(total) 张" }
        return "共 \(total) 张未归类"
    }

    private var assignIDs: [String] {
        if showSortedView {
            if !sortedSelectedIDs.isEmpty { return Array(sortedSelectedIDs) }
            if isInSingleMode, singleModeAssets.indices.contains(singleModeCurrentIndex) {
                return [singleModeAssets[singleModeCurrentIndex].id]
            }
            if let id = focusedID { return [id] }
            return []
        }
        if !photosStore.selectedIDs.isEmpty { return Array(photosStore.selectedIDs) }
        if isInSingleMode, singleModeAssets.indices.contains(singleModeCurrentIndex) {
            return [singleModeAssets[singleModeCurrentIndex].id]
        }
        if let id = focusedID { return [id] }
        return []
    }

    // MARK: - Actions

    @ViewBuilder private var singlePhotoView: some View {
        SinglePhotoView(
            assets: singleModeAssets,
            initialIndex: singleModeInitialIndex,
            enterTrigger: singleEnterTrigger,
            sourceFrame: $focusedFrame,
            backdropOpacity: $previewOpacity,
            getGridFrame: { localIdx in
                let id = localIdx < singleModeAssets.count ? singleModeAssets[localIdx].id : nil
                guard let eid = id else {
                    return gridLayout.frameFor(index: localIdx)
                }
                let flatIdx: Int?
                if showSortedView {
                    let secs = sortedSections
                    var off = 0
                    var found: Int? = nil
                    for sec in secs {
                        if let i = sec.assets.firstIndex(where: { $0.id == eid }) {
                            found = off + i; break
                        }
                        off += sec.assets.count
                    }
                    flatIdx = found
                } else {
                    flatIdx = photosStore.assets.firstIndex(where: { $0.id == eid })
                }
                return gridLayout.frameFor(index: flatIdx ?? localIdx)
            },
            onIndexChange: { singleModeCurrentIndex = $0 },
            onBeforeDismiss: { localIdx in
                let id = localIdx < singleModeAssets.count ? singleModeAssets[localIdx].id : nil
                guard let eid = id else { return }
                let flatIdx: Int?
                if showSortedView {
                    let secs = sortedSections
                    var off = 0
                    var found: Int? = nil
                    for sec in secs {
                        if let i = sec.assets.firstIndex(where: { $0.id == eid }) {
                            found = off + i; break
                        }
                        off += sec.assets.count
                    }
                    flatIdx = found
                } else {
                    flatIdx = photosStore.assets.firstIndex(where: { $0.id == eid })
                }
                if let idx = flatIdx { gridLayout.scrollToVisible?(idx) }
            },
            onDismissBegin: { dismissBegun = true },
            onDismiss: { finalIndex in
                let work = DispatchWorkItem {
                    isInSingleMode = false
                    showingPreview = false
                    dismissBegun = false
                    let dismissedID = singleModeAssets.indices.contains(finalIndex)
                        ? singleModeAssets[finalIndex].id : nil
                    if let id = dismissedID { focusedID = id }
                }
                pendingDismissWork = work
                DispatchQueue.main.async(execute: work)
            },
            spaceEnterSessionID: spaceEnterSessionID,
            panelWidth: panelTotalWidth,
            swipeExcludeBottom: stripH,
            swipeExcludeRight: panelTotalWidth,
            useThumbnailFit: thumbnailFit
        )
        .transition(.identity)
    }

    private func enterSingleMode() {
        // Dismiss animation in flight: cancel the pending isInSingleMode=false callback
        // and re-trigger the entry animation on the existing SinglePhotoView.
        if isInSingleMode {
            pendingDismissWork?.cancel()
            pendingDismissWork = nil
            showingPreview = true
            dismissBegun = false
            singleEnterTrigger += 1
            return
        }
        guard let id = focusedID else { return }

        // Refresh focusedFrame from layout math before entering, so the entry animation
        // always starts from the correct cell position regardless of scroll state.
        if showSortedView {
            let secs = sortedSections
            var off = 0
            for sec in secs {
                if let i = sec.assets.firstIndex(where: { $0.id == id }) {
                    let frame = gridLayout.frameFor(index: off + i)
                    if frame != .zero { focusedFrame = frame }
                    break
                }
                off += sec.assets.count
            }
        } else {
            if let idx = photosStore.assets.firstIndex(where: { $0.id == id }) {
                let frame = gridLayout.frameFor(index: idx)
                if frame != .zero { focusedFrame = frame }
            }
        }

        if showSortedView {
            // 已分类模式：多选 → 选中集队列；单选/无选 → 所在分组（含待删除组）作为队列
            let secs = sortedSections
            if sortedSelectedIDs.count > 1 {
                let allSorted = secs.flatMap(\.assets)
                let queue = allSorted.filter { sortedSelectedIDs.contains($0.id) }
                guard !queue.isEmpty else { return }
                let startIdx = queue.firstIndex(where: { $0.id == id }) ?? 0
                singleModeAssets       = queue
                singleModeInitialIndex = startIdx
                singleModeCurrentIndex = startIdx
                multiQueueHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Anim.hintDuration) {
                    withAnimation(.easeInOut(duration: Anim.multiHintFade)) { multiQueueHint = false }
                }
            } else {
                // 找 id 所在的分组作为队列
                let queue = secs.first(where: { $0.assets.contains(where: { $0.id == id }) })?.assets
                    ?? secs.flatMap(\.assets)
                guard let startIdx = queue.firstIndex(where: { $0.id == id }) else { return }
                singleModeAssets       = queue
                singleModeInitialIndex = startIdx
                singleModeCurrentIndex = startIdx
            }
        } else {
            let sel = photosStore.selectedIDs
            if sel.count > 1 {
                // 多选模式：队列 = 选中照片（保持 assets 原始顺序）
                let queue = photosStore.assets.filter { sel.contains($0.id) }
                guard !queue.isEmpty else { return }
                let startIdx = queue.firstIndex(where: { $0.id == id }) ?? 0
                singleModeAssets       = queue
                singleModeInitialIndex = startIdx
                singleModeCurrentIndex = startIdx
                multiQueueHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Anim.hintDuration) {
                    withAnimation(.easeInOut(duration: Anim.multiHintFade)) { multiQueueHint = false }
                }
            } else {
                // 无选中（或仅单选）：队列 = 全部照片
                guard let idx = photosStore.assets.firstIndex(where: { $0.id == id }) else { return }
                singleModeAssets       = photosStore.assets
                singleModeInitialIndex = idx
                singleModeCurrentIndex = idx
            }
        }

        showingPreview = true
        isInSingleMode = true
        singleEnterTrigger += 1
    }

    private func toggleSidebar() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            sidebarVisible.toggle()
        }
        UserDefaults.standard.set(sidebarVisible, forKey: Prefs.sidebarVisible)
    }


    private func showTopHint(_ text: String, duration: Double = Anim.hintDuration) {
        topHintTask?.cancel()
        topHintText = text
        topHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            topHintText = nil
        }
    }

    private func assignToAlbum(_ node: AlbumNode) {
        guard !node.isFolder, let collection = node.assetCollection else { return }
        let ids = assignIDs
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }
        let isSingleGrid = !isInSingleMode && photosStore.selectedIDs.isEmpty && focusedID != nil
        let preFocusIdx  = focusedID.flatMap { id in photosStore.assets.firstIndex(where: { $0.id == id }) }
        let assignedIDSet = Set(ids)
        photosStore.addIDs(ids, to: collection, albumNode: node, history: sortHistory) {
            albumsStore.recordRecent(node)
            albumsStore.reload()
            if isInSingleMode {
                singleModeAssets = singleModeAssets.filter { !assignedIDSet.contains($0.id) }
            } else {
                guard isSingleGrid else { return }
                let remaining = photosStore.assets
                if remaining.isEmpty { focusedID = nil }
                else if let idx = preFocusIdx {
                    focusedID = remaining[min(idx, remaining.count - 1)].id
                }
            }
        }
    }

    // MARK: - Delete Actions

    // Cmd+Delete: pending-delete group → uncategorized; album group → pending delete; uncategorized → pending delete
    private func moveSelectedToPendingDelete() {
        let ids = showSortedView ? assignIDsForSorted() : assignIDs
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }

        if showSortedView {
            let idSet = Set(ids)
            let pendingIDs = Set(sortHistory.pendingDeleteAssets.map(\.id))

            // Pending-delete group → restore to uncategorized (records restoreFromPendingDelete)
            let toRestore = sortHistory.pendingDeleteAssets.filter { idSet.contains($0.id) }
            if !toRestore.isEmpty {
                let restoreIDs = Set(toRestore.map(\.id))
                sortHistory.removeFromPendingDelete(ids: restoreIDs)
                photosStore.restoreAssets(toRestore)
                sortHistory.record(SortAction(kind: .restoreFromPendingDelete, assets: toRestore))
                showTopHint("已将 \(toRestore.count) 张照片归还未归类")
                postSortedCompletionNotification(history: sortHistory)
                syncSingleModeAssetsIfNeeded()
            }

            // Album groups → pending delete (records moveToPendingDelete per album)
            let toDelete = sortHistory.groupedByAlbum.flatMap(\.assets).filter { idSet.contains($0.id) && !pendingIDs.contains($0.id) }
            if !toDelete.isEmpty {
                moveAlbumAssetsToPendingDelete(assets: toDelete)
            }

            if toRestore.isEmpty && toDelete.isEmpty { showTopHint("请先选择照片") }
        } else {
            // Uncategorized → pending delete (records moveToPendingDelete with nil source album)
            let toDelete = photosStore.assets.filter { ids.contains($0.id) }
            guard !toDelete.isEmpty else { return }
            let isSingleGrid = !isInSingleMode && photosStore.selectedIDs.isEmpty && focusedID != nil
            let preFocusIdx = focusedID.flatMap { id in photosStore.assets.firstIndex(where: { $0.id == id }) }
            sortHistory.addPendingDelete(toDelete)
            photosStore.removeAssetsDirectly(ids: ids)
            photosStore.clearSelection()
            sortHistory.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: nil), assets: toDelete))
            showTopHint("已标记 \(toDelete.count) 张照片为待删除")
            if isSingleGrid {
                let remaining = photosStore.assets
                focusedID = remaining.isEmpty ? nil : remaining[min(preFocusIdx ?? 0, remaining.count - 1)].id
            }
            syncSingleModeAssetsIfNeeded()
        }
    }

    // Delete (no modifier) in sorted view only: album → uncategorized (pure memory, records returnToUncategorized)
    private func returnSelectedToUncategorized() {
        guard showSortedView else { return }
        let ids = assignIDsForSorted()
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }

        let groups = sortHistory.groupedByAlbum
        var allRestored: [PhotoAsset] = []
        for g in groups {
            let matching = g.assets.filter { ids.contains($0.id) }
            if !matching.isEmpty {
                allRestored.append(contentsOf: matching)
                sortHistory.record(SortAction(kind: .returnToUncategorized(albumNode: g.albumNode), assets: matching))
            }
        }
        guard !allRestored.isEmpty else { return }

        sortHistory.removeAssetsFromHistory(ids: Set(ids))
        photosStore.restoreAssets(allRestored)
        showTopHint("已将 \(allRestored.count) 张照片归还未归类")
        postSortedCompletionNotification(history: sortHistory)
        syncSingleModeAssetsIfNeeded()
    }

    // Move assets from album groups into pending-delete (pure memory, records moveToPendingDelete)
    private func moveAlbumAssetsToPendingDelete(assets: [PhotoAsset]) {
        let groups = sortHistory.groupedByAlbum
        let ids = Set(assets.map(\.id))
        for g in groups {
            let matching = g.assets.filter { ids.contains($0.id) }
            if !matching.isEmpty {
                sortHistory.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: g.albumNode), assets: matching))
            }
        }
        sortHistory.addPendingDelete(assets)
        sortHistory.removeAssetsFromHistory(ids: ids)
        showTopHint("已标记 \(assets.count) 张照片为待删除")
        postSortedCompletionNotification(history: sortHistory)
    }

    // Posts sortedViewShouldDismiss if sorted view is now empty, else clears selection only.
    private func postSortedCompletionNotification(history: SortHistory) {
        ContentView.postSortedCompletionNotification(history: history)
    }

    private static func postSortedCompletionNotification(history: SortHistory) {
        let isEmpty = history.totalSortedCount == 0 && history.pendingDeleteAssets.isEmpty
        NotificationCenter.default.post(
            name: isEmpty ? .sortedViewShouldDismiss : .sortedSelectionShouldClear,
            object: nil
        )
    }

    private func permanentlyDeletePending() {
        let assets = sortHistory.pendingDeleteAssets
        guard !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        var phAssets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { a, _, _ in phAssets.append(a) }
        let history = sortHistory
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(phAssets as NSFastEnumeration)
        }) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                // Permanently deleted — clear from pending and wipe any undo that referenced them
                let deletedIDs = Set(assets.map(\.id))
                history.removeAssetsFromHistory(ids: deletedIDs)
                history.clearPendingDeletes()
                ContentView.postSortedCompletionNotification(history: history)
            }
        }
    }

    private func assignIDsForSorted() -> [String] {
        if !sortedSelectedIDs.isEmpty { return Array(sortedSelectedIDs) }
        if let id = focusedID { return [id] }
        return []
    }

    // MARK: - Single Mode Queue Sync

    // 单图模式下，按 photosStore.assets 顺序重建队列：恢复的照片穿插回原位，已归类的移出。
    private func syncSingleModeAssetsIfNeeded() {
        guard isInSingleMode else { return }
        let newQueue = photosStore.assets
        guard newQueue.map(\.id) != singleModeAssets.map(\.id) else { return }

        let currentID = singleModeAssets.indices.contains(singleModeCurrentIndex)
            ? singleModeAssets[singleModeCurrentIndex].id : nil

        singleModeAssets = newQueue

        if let id = currentID, let idx = newQueue.firstIndex(where: { $0.id == id }) {
            singleModeCurrentIndex = idx
        } else {
            singleModeCurrentIndex = min(singleModeCurrentIndex, max(0, newQueue.count - 1))
        }
    }

    // MARK: - Undo / Redo

    private func undoLastAction() {
        guard let action = sortHistory.popUndo() else { return }
        let history = sortHistory
        let store = photosStore

        switch action.kind {

        case .classify(let albumNode):
            // Undo classify: restore to uncategorized (pure memory — not yet in Photos)
            store.restoreAssets(action.assets)
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片从「\(albumNode.title)」移回")
            ContentView.postSortedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .returnToUncategorized(let albumNode):
            // Undo return-to-uncategorized: move back into album group (pure memory)
            let ids = action.assets.map(\.id)
            store.removeAssetsDirectly(ids: ids)
            history.record(SortAction(kind: .classify(albumNode: albumNode), assets: action.assets))
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片移回「\(albumNode.title)」")
            ContentView.postSortedCompletionNotification(history: history)

        case .moveToPendingDelete(let sourceAlbumNode):
            // Undo move-to-pending: remove from pending, restore to album group or uncategorized
            let restoreAssets = action.assets
            let restoreIDs = Set(restoreAssets.map(\.id))
            history.removeFromPendingDelete(ids: restoreIDs)
            if let albumNode = sourceAlbumNode {
                // Came from album group — re-insert into history as classify
                history.record(SortAction(kind: .classify(albumNode: albumNode), assets: restoreAssets))
                history.pushRedo(action)
                showTopHint("已撤销：\(restoreAssets.count) 张照片移回「\(albumNode.title)」")
                ContentView.postSortedCompletionNotification(history: history)
            } else {
                // Came from uncategorized
                store.restoreAssets(restoreAssets)
                history.pushRedo(action)
                showTopHint("已撤销：\(restoreAssets.count) 张照片从待删除移回未归类")
                ContentView.postSortedCompletionNotification(history: history)
                syncSingleModeAssetsIfNeeded()
            }

        case .restoreFromPendingDelete:
            // Undo restore-from-pending: move back to pending delete
            history.addPendingDelete(action.assets)
            store.removeAssetsDirectly(ids: action.assets.map(\.id))
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片移回待删除")
            ContentView.postSortedCompletionNotification(history: history)
        }
    }

    private func redoLastAction() {
        guard let action = sortHistory.popRedo() else { return }
        let history = sortHistory
        let store = photosStore

        switch action.kind {

        case .classify(let albumNode):
            // Redo classify: remove from uncategorized, back into album group
            store.removeAssetsDirectly(ids: action.assets.map(\.id))
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片归入「\(albumNode.title)」")
            ContentView.postSortedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .returnToUncategorized(let albumNode):
            // Redo return: remove from album group, restore to uncategorized
            let ids = Set(action.assets.map(\.id))
            history.removeAssetsFromHistory(ids: ids)
            store.restoreAssets(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片从「\(albumNode.title)」归还未归类")
            ContentView.postSortedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .moveToPendingDelete(let sourceAlbumNode):
            // Redo move-to-pending: remove from album group or uncategorized, add to pending
            let ids = Set(action.assets.map(\.id))
            if sourceAlbumNode != nil {
                history.removeAssetsFromHistory(ids: ids)
            } else {
                store.removeAssetsDirectly(ids: Array(ids))
            }
            history.addPendingDelete(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片标记为待删除")
            ContentView.postSortedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .restoreFromPendingDelete:
            // Redo restore: remove from pending, restore to uncategorized
            history.removeFromPendingDelete(ids: Set(action.assets.map(\.id)))
            store.restoreAssets(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片从待删除移回未归类")
            ContentView.postSortedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()
        }
    }

    private func fetchPHAssets(for assets: [PhotoAsset]) -> [PHAsset] {
        var result: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
            .enumerateObjects { a, _, _ in result.append(a) }
        return result
    }

    // Batch-write all classified photos to Photos framework (no quit).
    private func commitAll() {
        let groups = sortHistory.groupedByAlbum
        let pending = sortHistory.pendingDeleteAssets

        var total = groups.count + (pending.isEmpty ? 0 : 1)
        guard total > 0 else { return }

        func done() {
            total -= 1
            guard total == 0 else { return }
            sortHistory.clearAll()
            showSortedView = false
            ContentView.postSortedCompletionNotification(history: sortHistory)
            showTopHint("分类完成")
        }

        for g in groups {
            guard let collection = g.albumNode.assetCollection else { done(); continue }
            let phAssets = fetchPHAssets(for: g.assets)
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }

        if !pending.isEmpty {
            var phAssets: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: pending.map(\.id), options: nil)
                .enumerateObjects { a, _, _ in phAssets.append(a) }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }
    }

    // Batch-write all classified photos to Photos framework, then quit.
    private func commitAllAndQuit() {
        let groups = sortHistory.groupedByAlbum
        guard !groups.isEmpty else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        var total = groups.count
        guard total > 0 else { NSApp.reply(toApplicationShouldTerminate: true); return }

        func done() {
            total -= 1
            if total == 0 { NSApp.reply(toApplicationShouldTerminate: true) }
        }

        for g in groups {
            guard let collection = g.albumNode.assetCollection else { done(); continue }
            let phAssets = fetchPHAssets(for: g.assets)
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }
    }
}

// MARK: - Resize Divider

enum DividerSide { case left, right }

struct ResizeDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let side: DividerSide

    @State private var isDragging = false
    @State private var startX: CGFloat = 0
    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    startX = value.startLocation.x
                                    startWidth = width
                                }
                                let delta = side == .left
                                    ? value.location.x - startX
                                    : startX - value.location.x
                                width = max(minWidth, min(maxWidth, startWidth + delta))
                            }
                            .onEnded { _ in isDragging = false }
                    )
            )
    }
}

// MARK: - View Extensions

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Movable Title Bar Background

/// 透明垫层：mouseDownCanMoveWindow = true，让未被子视图命中的点击传回窗口拖动。
struct MovableTitleBarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = _MovableView()
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class _MovableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
