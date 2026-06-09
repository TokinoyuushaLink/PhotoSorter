import SwiftUI
import AppKit

// MARK: - Section Data

struct SectionData {
    let header: String?           // nil = no header (uncategorized mode)
    let assets: [PhotoAsset]
    var isDeleteGroup: Bool = false
}

// MARK: - PhotoCollectionView

struct PhotoCollectionView: NSViewRepresentable {
    @Bindable var store: PhotosStore
    @Binding var focusedID: String?
    @Binding var focusedFrame: CGRect
    var gridLayout: GridLayout
    var cols: Int
    var cellSize: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    // When non-nil, use section-based rendering instead of store.assets
    var sections: [SectionData]?
    // When non-nil, section-mode tap/selection operates on this set instead of store.selectedIDs
    var externalSelectedIDs: Binding<Set<String>>?
    let onScrollChange: (_ offsetY: CGFloat, _ contentH: CGFloat, _ containerH: CGFloat) -> Void
    var onFrameProviderReady: ((_ provider: @escaping (Int) -> CGRect) -> Void)?

    private static let headerID = NSUserInterfaceItemIdentifier("SectionHeader")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = SquareGridLayout()

        let cv = TapCollectionView()
        cv.collectionViewLayout = layout
        cv.dataSource = context.coordinator
        cv.delegate   = context.coordinator
        cv.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.reuseID)
        cv.register(
            SectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: Self.headerID
        )
        cv.isSelectable = false
        cv.backgroundColors = [.clear]

        let c = context.coordinator
        cv.onTapItem = { [weak c] ip, isCmd, isShift in
            c?.handleTap(indexPath: ip, isCommand: isCmd, isShift: isShift)
        }
        cv.onTapBackground = { [weak c] in c?.handleBackgroundTap() }

        let sv = NSScrollView()
        sv.documentView = cv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.scrollerStyle = .overlay
        sv.backgroundColor = .clear
        sv.drawsBackground = false

        c.cv = cv
        c.sv = sv
        c.observeScroll(sv)

        onFrameProviderReady?({ [weak c] index in c?.swiftUIFrame(forFlatIndex: index) ?? .zero })

        DispatchQueue.main.async { [weak c] in c?.reportScroll() }

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self

        guard let cv = c.cv,
              let layout = cv.collectionViewLayout as? SquareGridLayout else { return }

        if c.lastTopPad != topPadding || c.lastBottomPad != bottomPadding {
            c.lastTopPad    = topPadding
            c.lastBottomPad = bottomPadding
            layout.topPadding    = topPadding
            layout.bottomPadding = bottomPadding
            layout.invalidateLayout()
            DispatchQueue.main.async { [weak c] in c?.reportScroll() }
        }

        let newOriginY = gridLayout.originY
        if c.lastGridOriginY != newOriginY {
            c.lastGridOriginY = newOriginY
            DispatchQueue.main.async { [weak c] in c?.reportScroll() }
        }

        // Reload check — differs based on whether we're in section mode
        let newSections = sections
        let needsReload: Bool
        if let newSections {
            // Section mode: compare flattened count + first id + header signatures
            let newCount = newSections.reduce(0) { $0 + $1.assets.count }
            let newFirst = newSections.first?.assets.first?.id
            let newHeaders = newSections.map { (header: $0.header ?? "", isDelete: $0.isDeleteGroup) }
            let headersChanged = newHeaders.count != c.lastSectionHeaders.count
                || zip(newHeaders, c.lastSectionHeaders).contains { $0 != ($1.header, $1.isDelete) }
            needsReload = newCount != c.flatAssetIDs.count
                || (newCount > 0 && newFirst != c.flatAssetIDs.first)
                || c.lastSectionCount != newSections.count
                || headersChanged
        } else {
            let newCount = store.assets.count
            needsReload = newCount != c.flatAssetIDs.count
                || (newCount > 0 && store.assets[0].id != c.flatAssetIDs.first)
                || c.lastSectionCount != 1
        }

        if needsReload {
            let newSectionData = newSections ?? [SectionData(header: nil, assets: store.assets)]
            let oldSectionData = c.cachedSections

            // Try animated batch update when only items changed within existing sections
            let canAnimate = newSectionData.count == oldSectionData.count
                && zip(newSectionData, oldSectionData).allSatisfy {
                    $0.header == $1.header && $0.isDeleteGroup == $1.isDeleteGroup
                }

            if canAnimate && !oldSectionData.isEmpty {
                var deletes: [IndexPath] = []
                var inserts: [IndexPath] = []
                for (s, (newSec, oldSec)) in zip(newSectionData, oldSectionData).enumerated() {
                    let oldIDs = oldSec.assets.map(\.id)
                    let newIDs = newSec.assets.map(\.id)
                    let oldSet = Set(oldIDs)
                    let newSet = Set(newIDs)
                    for (i, id) in oldIDs.enumerated() where !newSet.contains(id) {
                        deletes.append(IndexPath(item: i, section: s))
                    }
                    for (i, id) in newIDs.enumerated() where !oldSet.contains(id) {
                        inserts.append(IndexPath(item: i, section: s))
                    }
                }

                // Commit new state before batch update so data source is consistent
                c.cachedSections = newSectionData
                c.flatAssetIDs = newSectionData.flatMap { $0.assets.map(\.id) }
                c.lastSectionCount = newSectionData.count
                c.lastSectionHeaders = newSectionData.map { (header: $0.header ?? "", isDelete: $0.isDeleteGroup) }
                c.syncLayoutHeaders(newSectionData)

                if !deletes.isEmpty || !inserts.isEmpty {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.28
                        cv.animator().performBatchUpdates({
                            if !deletes.isEmpty { cv.deleteItems(at: Set(deletes)) }
                            if !inserts.isEmpty { cv.insertItems(at: Set(inserts)) }
                        }, completionHandler: nil)
                    }
                }
            } else {
                // Section structure changed — full reload
                c.cachedSections = newSectionData
                c.flatAssetIDs = newSectionData.flatMap { $0.assets.map(\.id) }
                c.lastSectionCount = newSectionData.count
                c.lastSectionHeaders = newSectionData.map { (header: $0.header ?? "", isDelete: $0.isDeleteGroup) }
                c.syncLayoutHeaders(newSectionData)
                cv.reloadData()
            }
            cv.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak c] in c?.reportScroll() }
            return
        }

        // Incremental cell refresh — focus/selection state
        let selIDs = externalSelectedIDs?.wrappedValue ?? store.selectedIDs
        let visibleIPs = cv.indexPathsForVisibleItems()
        for ip in visibleIPs {
            guard let cell = cv.item(at: ip) as? PhotoCell,
                  let asset = c.asset(at: ip) else { continue }
            let nowFocused  = focusedID == asset.id
            let nowSelected = selIDs.contains(asset.id)
            if cell.isFocused != nowFocused || cell.isCellSelected != nowSelected {
                cell.configure(asset: asset, store: store, isFocused: nowFocused, isCellSelected: nowSelected)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PhotoCollectionView
        weak var cv: TapCollectionView?
        weak var sv: NSScrollView?
        var flatAssetIDs: [String] = []
        var lastSectionCount: Int = 0
        var lastSectionHeaders: [(header: String, isDelete: Bool)] = []
        var lastTopPad: CGFloat  = -1
        var lastBottomPad: CGFloat = -1
        var lastGridOriginY: CGFloat = .nan
        var anchorIndexPath: IndexPath? = nil
        // Committed snapshot used as the data source — kept in sync before batch updates
        var cachedSections: [SectionData] = []
        private var scrollObs: Any?
        private var windowObs: Any?

        init(_ parent: PhotoCollectionView) { self.parent = parent }

        deinit {
            if let o = scrollObs { NotificationCenter.default.removeObserver(o) }
            if let o = windowObs { NotificationCenter.default.removeObserver(o) }
        }

        // MARK: Helpers

        private func currentSections() -> [SectionData] {
            // cachedSections is committed before any batch update, so always consistent
            // with what NSCollectionView thinks the data is.
            if !cachedSections.isEmpty { return cachedSections }
            if let s = parent.sections { return s }
            return [SectionData(header: nil, assets: parent.store.assets)]
        }

        func asset(at ip: IndexPath) -> PhotoAsset? {
            let secs = currentSections()
            guard ip.section < secs.count, ip.item < secs[ip.section].assets.count else { return nil }
            return secs[ip.section].assets[ip.item]
        }

        func syncLayoutHeaders(_ secs: [SectionData]) {
            guard let layout = cv?.collectionViewLayout as? SquareGridLayout else { return }
            var heights: [Int: CGFloat] = [:]
            for (i, sec) in secs.enumerated() where sec.header != nil {
                heights[i] = i == 0 ? parent.topPadding : 48
            }
            layout.headerHeights = heights
            layout.topPadding    = parent.topPadding
            layout.bottomPadding = parent.bottomPadding
        }

        // Flat index → IndexPath in current section layout
        private func indexPath(forFlatIndex flat: Int) -> IndexPath? {
            let secs = currentSections()
            var remaining = flat
            for (s, sec) in secs.enumerated() {
                if remaining < sec.assets.count { return IndexPath(item: remaining, section: s) }
                remaining -= sec.assets.count
            }
            return nil
        }

        // MARK: Scroll / Window

        func observeScroll(_ sv: NSScrollView) {
            scrollObs = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: sv, queue: .main
            ) { [weak self] _ in self?.reportScroll() }
        }

        func observeWindow(_ window: NSWindow) {
            guard windowObs == nil else { return }
            windowObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.reportScroll() }
            }
        }

        func reportScroll() {
            guard let sv, let cv else { return }
            parent.onScrollChange(sv.documentVisibleRect.origin.y, cv.frame.height, sv.bounds.height)
        }

        // MARK: Frame

        func swiftUIFrame(forFlatIndex flat: Int) -> CGRect {
            guard let ip = indexPath(forFlatIndex: flat) else { return .zero }
            return swiftUIFrame(for: ip)
        }

        private func swiftUIFrame(for ip: IndexPath) -> CGRect {
            guard let cv, let sv, let window = cv.window,
                  let contentView = window.contentView,
                  let attrs = cv.collectionViewLayout?.layoutAttributesForItem(at: ip) else { return .zero }
            observeWindow(window)
            let scrollY = sv.documentVisibleRect.origin.y
            let itemInCV = CGRect(
                x: attrs.frame.origin.x,
                y: attrs.frame.origin.y - scrollY,
                width: attrs.frame.width,
                height: attrs.frame.height
            )
            let itemInContent = cv.convert(itemInCV, to: contentView)
            let swiftUIY = contentView.bounds.height - itemInContent.maxY
            return CGRect(x: itemInContent.minX, y: swiftUIY,
                          width: itemInContent.width, height: itemInContent.height)
        }

        // MARK: Tap Handling

        func handleTap(indexPath ip: IndexPath, isCommand: Bool, isShift: Bool) {
            guard let asset = asset(at: ip) else { return }

            parent.focusedID    = asset.id
            parent.focusedFrame = swiftUIFrame(for: ip)

            if let ext = parent.externalSelectedIDs {
                // Section mode: selection operates on external binding, range within same section
                let sectionAssets = currentSections()[ip.section].assets
                if isShift {
                    let anchorItem = anchorIndexPath?.section == ip.section ? (anchorIndexPath?.item ?? ip.item) : ip.item
                    let lo = min(anchorItem, ip.item)
                    let hi = max(anchorItem, ip.item)
                    var ids = ext.wrappedValue
                    for i in lo...hi { ids.insert(sectionAssets[i].id) }
                    ext.wrappedValue = ids
                } else if isCommand {
                    var ids = ext.wrappedValue
                    if ids.contains(asset.id) { ids.remove(asset.id) } else { ids.insert(asset.id) }
                    ext.wrappedValue = ids
                    anchorIndexPath = ip
                } else {
                    ext.wrappedValue = []
                    anchorIndexPath = ip
                }
            } else {
                // Uncategorized mode: selection operates on store
                let secs = currentSections()
                let flatIndex = (0..<ip.section).reduce(0) { $0 + secs[$1].assets.count } + ip.item
                if isShift {
                    let anchorFlat = anchorIndexPath.map { anchor in
                        (0..<anchor.section).reduce(0) { $0 + secs[$1].assets.count } + anchor.item
                    } ?? flatIndex
                    parent.store.selectRange(from: anchorFlat, to: flatIndex)
                } else if isCommand {
                    parent.store.toggleSelection(asset.id)
                    anchorIndexPath = ip
                } else {
                    parent.store.clearSelection()
                    anchorIndexPath = ip
                }
            }
        }

        func handleBackgroundTap() {
            parent.focusedID = nil
            anchorIndexPath = nil
            if let ext = parent.externalSelectedIDs {
                ext.wrappedValue = []
            } else {
                parent.store.clearSelection()
            }
            NotificationCenter.default.post(name: .refocusCapture, object: nil)
        }

        // MARK: DataSource

        func numberOfSections(in cv: NSCollectionView) -> Int {
            currentSections().count
        }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            let secs = currentSections()
            guard section < secs.count else { return 0 }
            return secs[section].assets.count
        }

        func collectionView(_ cv: NSCollectionView,
                            itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: PhotoCell.reuseID, for: ip) as! PhotoCell
            guard let asset = asset(at: ip) else { return cell }
            let selIDs = parent.externalSelectedIDs?.wrappedValue ?? parent.store.selectedIDs
            cell.configure(
                asset: asset,
                store: parent.store,
                isFocused: parent.focusedID == asset.id,
                isCellSelected: selIDs.contains(asset.id)
            )
            return cell
        }

        func collectionView(_ cv: NSCollectionView,
                            viewForSupplementaryElementOfKind kind: String,
                            at ip: IndexPath) -> NSView {
            let view = cv.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: PhotoCollectionView.headerID,
                for: ip
            ) as! SectionHeaderView
            let secs = currentSections()
            if ip.section < secs.count {
                view.label         = secs[ip.section].header ?? ""
                view.isDeleteGroup = secs[ip.section].isDeleteGroup
            }
            return view
        }

        func collectionView(_ cv: NSCollectionView,
                            willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt ip: IndexPath) {
            guard let asset = asset(at: ip), let cell = item as? PhotoCell else { return }
            guard cell.configuredID != asset.id else { return }
            let selIDs = parent.externalSelectedIDs?.wrappedValue ?? parent.store.selectedIDs
            cell.configure(asset: asset, store: parent.store,
                           isFocused: parent.focusedID == asset.id,
                           isCellSelected: selIDs.contains(asset.id))
        }
    }
}

// MARK: - Section Header View

final class SectionHeaderView: NSView, NSCollectionViewElement {
    var label: String = "" { didSet { textField.stringValue = label } }
    var isDeleteGroup: Bool = false { didSet { updateAppearance() } }

    private let textField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: Layout.sectionHeaderFontSize, weight: .bold)
        tf.textColor = .labelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    private lazy var trashButton: NSButton = {
        let btn = NSButton()
        let cfg = NSImage.SymbolConfiguration(pointSize: Layout.sectionHeaderTrashSize, weight: .regular)
        btn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")?.withSymbolConfiguration(cfg)
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.contentTintColor = NSColor.systemRed
        btn.target = self
        btn.action = #selector(trashTapped)
        btn.toolTip = "永久删除全部待删除照片"
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        return btn
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(textField)
        addSubview(trashButton)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            trashButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 8),
            trashButton.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: Layout.sectionHeaderTrashButtonSize),
            trashButton.heightAnchor.constraint(equalToConstant: Layout.sectionHeaderTrashButtonSize),
        ])
    }

    private func updateAppearance() {
        textField.textColor = isDeleteGroup ? NSColor.systemRed : NSColor.labelColor
        trashButton.isHidden = !isDeleteGroup
    }

    @objc private func trashTapped() {
        NotificationCenter.default.post(name: .confirmDeletePending, object: nil)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isDeleteGroup = false
        label = ""
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Grid Layout

final class SquareGridLayout: NSCollectionViewLayout {
    var spacing: CGFloat = 2
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0
    var headerHeights: [Int: CGFloat] = [:]

    // Per-section geometry computed in prepare() — no per-item objects stored.
    private struct SectionInfo {
        let itemsOriginY: CGFloat   // y where row 0 of this section starts
        let count: Int
        let headerFrame: CGRect     // .zero if no header
    }
    private var sections: [SectionInfo] = []
    private var cols: Int = 2
    private var side: CGFloat = 0
    private var cvWidth: CGFloat = 0
    private var contentSize: NSSize = .zero

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }

        let w = cv.bounds.width
        guard w > 0 else { return }

        let sp = spacing
        let c = max(2, Int(w / Layout.gridMinCellWidth))
        let s = (w - sp * CGFloat(c - 1)) / CGFloat(c)
        cols = c; side = s; cvWidth = w

        let nsecs = cv.numberOfSections
        var infos: [SectionInfo] = []
        infos.reserveCapacity(nsecs)
        var y: CGFloat = 0

        for sec in 0..<nsecs {
            var headerFrame = CGRect.zero
            if let hh = headerHeights[sec], hh > 0 {
                headerFrame = CGRect(x: 0, y: y, width: w, height: hh)
                y += hh
            } else if sec == 0 {
                y += topPadding
            }
            let count = cv.numberOfItems(inSection: sec)
            infos.append(SectionInfo(itemsOriginY: y, count: count, headerFrame: headerFrame))
            let rows = count > 0 ? (count + c - 1) / c : 0
            if rows > 0 { y += CGFloat(rows) * (s + sp) - sp }
            if sec == nsecs - 1 { y += bottomPadding }
        }

        sections = infos
        contentSize = NSSize(width: w, height: max(y, 0))
    }

    override var collectionViewContentSize: NSSize { contentSize }

    // Build attributes on-demand for only the items intersecting rect.
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        let sp = spacing
        for (s, info) in sections.enumerated() {
            // Header
            if info.headerFrame != .zero, info.headerFrame.intersects(rect) {
                let a = NSCollectionViewLayoutAttributes(
                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    with: IndexPath(item: 0, section: s))
                a.frame = info.headerFrame
                result.append(a)
            }
            guard info.count > 0 else { continue }
            // Binary-search the first and last visible row
            let step = side + sp
            let firstRow = max(0, Int((rect.minY - info.itemsOriginY) / step))
            let lastRow  = min((info.count - 1) / cols,
                               Int((rect.maxY - info.itemsOriginY) / step))
            guard firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                let firstItem = row * cols
                let lastItem  = min(firstItem + cols - 1, info.count - 1)
                for i in firstItem...lastItem {
                    let a = NSCollectionViewLayoutAttributes(
                        forItemWith: IndexPath(item: i, section: s))
                    a.frame = frameForItem(i, originY: info.itemsOriginY)
                    result.append(a)
                }
            }
        }
        return result
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard ip.section < sections.count else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: ip)
        a.frame = frameForItem(ip.item, originY: sections[ip.section].itemsOriginY)
        return a
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String,
                                                        at ip: IndexPath)
        -> NSCollectionViewLayoutAttributes? {
        guard ip.section < sections.count else { return nil }
        let hf = sections[ip.section].headerFrame
        guard hf != .zero else { return nil }
        let a = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: kind, with: ip)
        a.frame = hf
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != cvWidth
    }

    private func frameForItem(_ i: Int, originY: CGFloat) -> CGRect {
        let col = i % cols
        let row = i / cols
        let sp = spacing
        return CGRect(
            x: CGFloat(col) * (side + sp),
            y: originY + CGFloat(row) * (side + sp),
            width: side, height: side)
    }
}

// MARK: - Custom NSCollectionView

final class TapCollectionView: NSCollectionView {
    var onTapItem: ((IndexPath, Bool, Bool) -> Void)?
    var onTapBackground: (() -> Void)?
    // Authoritative width set synchronously in setFrameSize, before invalidateLayout fires.
    // cv.bounds.width may lag by one layout pass; reading this avoids the 5-10px desync.
    private(set) var currentWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        currentWidth = newSize.width
        super.setFrameSize(newSize)
        collectionViewLayout?.invalidateLayout()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: pt) {
            onTapItem?(ip, event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift))
        } else {
            onTapBackground?()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .refocusCapture, object: nil)
        }
    }
}

// MARK: - Cell

final class PhotoCell: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("PhotoCell")

    private var hosting: NSHostingView<ThumbnailView>?
    private var loadTask: Task<Void, Never>?
    private(set) var isFocused      = false
    private(set) var isCellSelected = false
    private(set) var configuredID: String? = nil

    override func loadView() { self.view = NSView() }

    func configure(asset: PhotoAsset, store: PhotosStore, isFocused: Bool, isCellSelected: Bool) {
        let idChanged = configuredID != asset.id
        self.isFocused      = isFocused
        self.isCellSelected = isCellSelected
        self.configuredID   = asset.id

        if idChanged {
            loadTask?.cancel()
            loadTask = nil
            setThumbnail(nil, asset: asset, isFocused: isFocused, isCellSelected: isCellSelected)
        } else {
            updateOverlays(isFocused: isFocused, isCellSelected: isCellSelected)
        }

        if let img = ThumbnailCache.shared.cachedImage(for: asset.id) {
            setThumbnail(img, asset: asset, isFocused: isFocused, isCellSelected: isCellSelected)
            return
        }

        guard loadTask == nil else { return }
        let id = asset.id
        loadTask = Task { [weak self] in
            guard let phAsset = store.phAsset(for: id) else { return }
            let img = await ThumbnailCache.shared.thumbnail(for: id, phAsset: phAsset)
            guard !Task.isCancelled, let self, self.configuredID == id else { return }
            await MainActor.run {
                guard self.configuredID == id else { return }
                self.setThumbnail(img, asset: asset, isFocused: self.isFocused, isCellSelected: self.isCellSelected)
            }
        }
    }

    override func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        configuredID = nil
        isFocused = false
        isCellSelected = false
        hosting?.rootView = ThumbnailView(asset: .placeholder, thumbnail: nil, isFocused: false, isSelected: false)
    }

    private func setThumbnail(_ img: NSImage?, asset: PhotoAsset, isFocused: Bool, isCellSelected: Bool) {
        let tv = ThumbnailView(asset: asset, thumbnail: img, isFocused: isFocused, isSelected: isCellSelected)
        if let h = hosting {
            h.rootView = tv
        } else {
            let h = NSHostingView(rootView: tv)
            h.sizingOptions = []
            h.frame = view.bounds
            h.autoresizingMask = [.width, .height]
            view.addSubview(h)
            hosting = h
        }
    }

    private func updateOverlays(isFocused: Bool, isCellSelected: Bool) {
        guard var tv = hosting?.rootView else { return }
        if tv.isFocused != isFocused || tv.isSelected != isCellSelected {
            tv.isFocused  = isFocused
            tv.isSelected = isCellSelected
            hosting?.rootView = tv
        }
    }
}
