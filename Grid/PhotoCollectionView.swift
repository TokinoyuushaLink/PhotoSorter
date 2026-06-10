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
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var useThumbnailFit: Bool = false
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
        cv.onWidthWillChange = { [weak c] in c?.captureResizeAnchor() }
        cv.onWidthDidChange  = { [weak c] in c?.applyResizeAnchor() }

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
        gridLayout.scrollToVisible = { [weak c] index in c?.scrollToVisible(flatIndex: index) }

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

        // When fit mode toggles, reconfigure all visible cells immediately
        if c.lastUseFit != useThumbnailFit {
            c.lastUseFit = useThumbnailFit
            let selIDs = externalSelectedIDs?.wrappedValue ?? store.selectedIDs
            for ip in cv.indexPathsForVisibleItems() {
                guard let cell = cv.item(at: ip) as? PhotoCell,
                      let asset = c.asset(at: ip) else { continue }
                cell.configure(asset: asset, store: store,
                               isFocused: focusedID == asset.id,
                               isCellSelected: selIDs.contains(asset.id),
                               useFit: useThumbnailFit)
            }
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
                        ctx.duration = Anim.batchUpdateDuration
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
                cell.updateOverlays(isFocused: nowFocused, isCellSelected: nowSelected)
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
        var lastUseFit: Bool = false
        var anchorIndexPath: IndexPath? = nil
        // Committed snapshot used as the data source — kept in sync before batch updates
        var cachedSections: [SectionData] = []
        private var scrollObs: Any?
        // Flat item index of the first item in the anchor row (stable across column-count changes)
        private var resizeAnchorFlatItem: Int? = nil
        // How far the anchor row's center was from the viewport top (content-space delta)
        private var resizeAnchorViewportDelta: CGFloat = 0

        init(_ parent: PhotoCollectionView) { self.parent = parent }

        deinit {
            if let o = scrollObs { NotificationCenter.default.removeObserver(o) }
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
                heights[i] = i == 0 ? parent.topPadding : Layout.sortedSectionHeaderHeight
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

        // Called before resize: record which item is at the viewport center row.
        func captureResizeAnchor() {
            guard let sv, let cv,
                  let layout = cv.collectionViewLayout as? SquareGridLayout,
                  layout.side > 0, layout.cols > 0 else {
                resizeAnchorFlatItem = nil
                return
            }
            let offsetY   = sv.documentVisibleRect.origin.y
            let viewportH = sv.bounds.height
            let centerY   = offsetY + viewportH / 2

            let sp   = layout.spacing
            let step = layout.side + sp
            let secs = currentSections()
            let infos = layout.sectionInfosSnapshot()

            var flatOffset = 0
            var anchorFlat: Int? = nil
            var anchorRowCenterY: CGFloat = 0

            for (s, info) in infos.enumerated() {
                let count = s < secs.count ? secs[s].assets.count : 0
                guard count > 0 else { continue }
                let cols = layout.cols
                let rows = (count + cols - 1) / cols
                let sectionBottom = info.itemsOriginY + CGFloat(rows) * step - sp

                if centerY <= sectionBottom || s == infos.count - 1 {
                    let rowInSec  = max(0, min(Int((centerY - info.itemsOriginY) / step), rows - 1))
                    let firstItem = rowInSec * cols       // first item index within this section
                    anchorFlat       = flatOffset + min(firstItem, count - 1)
                    anchorRowCenterY = info.itemsOriginY + CGFloat(rowInSec) * step + layout.side / 2
                    break
                }
                flatOffset += count
            }

            if let flat = anchorFlat {
                resizeAnchorFlatItem      = flat
                // How far the row center sits below the viewport top — preserved after resize
                resizeAnchorViewportDelta = anchorRowCenterY - offsetY
            } else {
                resizeAnchorFlatItem = nil
            }
        }

        // After resize: scroll so the anchor row's center stays at the same viewport position.
        // Called every frame during live resize — do NOT clear resizeAnchorFlatItem here.
        func applyResizeAnchor() {
            guard let sv, let cv,
                  let layout = cv.collectionViewLayout as? SquareGridLayout,
                  let anchorFlat = resizeAnchorFlatItem else {
                reportScroll()
                return
            }

            // Ensure layout has finished recalculating for the new width
            cv.layoutSubtreeIfNeeded()

            guard layout.side > 0, layout.cols > 0 else { reportScroll(); return }

            // Find the IndexPath for anchorFlat in the new layout
            let secs = currentSections()
            guard let ip = flatIndexToIndexPath(anchorFlat, secs: secs) else {
                reportScroll(); return
            }

            // Use the layout's row geometry directly (more reliable than layoutAttributesForItem
            // when called right after an invalidation)
            let infos = layout.sectionInfosSnapshot()
            guard ip.section < infos.count else { reportScroll(); return }
            let info  = infos[ip.section]
            let cols  = layout.cols
            let row   = ip.item / cols
            let sp    = layout.spacing
            let newRowCenterY = info.itemsOriginY + CGFloat(row) * (layout.side + sp) + layout.side / 2

            let newOffsetY  = newRowCenterY - resizeAnchorViewportDelta
            let contentH    = layout.collectionViewContentSize.height
            let viewportH   = sv.bounds.height
            let clamped     = max(0, min(newOffsetY, contentH - viewportH))

            sv.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            sv.reflectScrolledClipView(sv.contentView)
            reportScroll()
        }

        // Flat index → IndexPath, using the current column count in layout.
        private func flatIndexToIndexPath(_ flat: Int, secs: [SectionData]) -> IndexPath? {
            var remaining = flat
            for (s, sec) in secs.enumerated() {
                if remaining < sec.assets.count {
                    return IndexPath(item: remaining, section: s)
                }
                remaining -= sec.assets.count
            }
            return nil
        }

        func reportScroll() {
            guard let sv, let cv else { return }
            parent.onScrollChange(sv.documentVisibleRect.origin.y, cv.frame.height, sv.bounds.height)
        }

        // MARK: Scroll to visible

        /// Instantly scroll the grid so that the item at `flatIndex` is within the visible area
        /// (between the top and bottom gradient zones). Meant to be called synchronously before
        /// a dismiss animation begins, so the animation target lands inside the viewport.
        func scrollToVisible(flatIndex flat: Int) {
            NSLog("[scrollToVisible] flat=%d sv=%@ cv=%@", flat, sv != nil ? "SET" : "NIL", cv != nil ? "SET" : "NIL")
            guard let sv, let cv,
                  let ip = indexPath(forFlatIndex: flat),
                  let attrs = cv.collectionViewLayout?.layoutAttributesForItem(at: ip) else {
                NSLog("[scrollToVisible] guard failed ip=%@ attrs=%@",
                      indexPath(forFlatIndex: flat) != nil ? "OK" : "NIL",
                      "?")
                return
            }

            let curOffset = sv.documentVisibleRect.origin.y
            let topInset  = parent.topPadding
            let botInset  = parent.bottomPadding
            let viewportH = sv.bounds.height
            let safeTop    = curOffset + topInset
            let safeBottom = curOffset + viewportH - botInset
            let itemTop    = attrs.frame.minY
            let itemBottom = attrs.frame.maxY

            if itemTop >= safeTop && itemBottom <= safeBottom { return }   // already visible

            let contentH  = cv.collectionViewLayout?.collectionViewContentSize.height ?? cv.frame.height
            let maxOffset = max(0, contentH - viewportH)

            var newOffset: CGFloat
            if itemTop < safeTop {
                newOffset = itemTop - topInset
            } else {
                newOffset = itemBottom + botInset - viewportH
            }
            newOffset = max(0, min(newOffset, maxOffset))
            guard abs(newOffset - curOffset) > 0.5 else { return }

            // sv.contentView.scroll + reflectScrolledClipView is the correct way to
            // programmatically scroll NSScrollView so that documentVisibleRect updates
            // synchronously within the same runloop turn.
            sv.contentView.scroll(to: NSPoint(x: 0, y: newOffset))
            sv.reflectScrolledClipView(sv.contentView)
            reportScroll()
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
                isCellSelected: selIDs.contains(asset.id),
                useFit: parent.useThumbnailFit
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
                           isCellSelected: selIDs.contains(asset.id),
                           useFit: parent.useThumbnailFit)
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
    struct SectionInfo {
        let itemsOriginY: CGFloat   // y where row 0 of this section starts
        let count: Int
        let headerFrame: CGRect     // .zero if no header
    }
    private var sections: [SectionInfo] = []
    private(set) var cols: Int = 2
    private(set) var side: CGFloat = 0
    private var cvWidth: CGFloat = 0
    private var contentSize: NSSize = .zero

    func sectionInfosSnapshot() -> [SectionInfo] { sections }

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
    var onWidthWillChange: (() -> Void)?    // called before width changes, layout still old
    var onWidthDidChange: (() -> Void)?     // called after width changes and layout is invalidated
    // Authoritative width set synchronously in setFrameSize, before invalidateLayout fires.
    // cv.bounds.width may lag by one layout pass; reading this avoids the 5-10px desync.
    private(set) var currentWidth: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - currentWidth) > 0.5
        if widthChanged { onWidthWillChange?() }
        currentWidth = newSize.width
        super.setFrameSize(newSize)
        collectionViewLayout?.invalidateLayout()
        if widthChanged { onWidthDidChange?() }
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

    private var loadTask: Task<Void, Never>?
    private(set) var isFocused      = false
    private(set) var isCellSelected = false
    private(set) var configuredID: String? = nil
    private var useFit: Bool = false
    private var assetAspectRatio: CGFloat = 1

    private let thumbLayer   = CALayer()
    private let borderLayer  = CALayer()
    private let overlayView  = CellOverlayView()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        thumbLayer.masksToBounds = true
        thumbLayer.cornerRadius  = 3
        v.layer?.addSublayer(thumbLayer)

        borderLayer.cornerRadius    = 3
        borderLayer.masksToBounds   = false
        borderLayer.backgroundColor = .clear
        v.layer?.addSublayer(borderLayer)

        overlayView.autoresizingMask = [.width, .height]
        overlayView.wantsLayer = true
        v.addSubview(overlayView)
        self.view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame  = view.bounds
        borderLayer.frame = fitImageRect()
        overlayView.frame = view.bounds
        CATransaction.commit()
        overlayView.fitRect = useFit ? fitImageRect() : nil
    }

    // Sub-rect the image occupies in fit mode; full bounds in fill mode.
    private func fitImageRect() -> CGRect {
        let b = view.bounds
        guard useFit, b.width > 0, b.height > 0 else { return b }
        let ar = assetAspectRatio > 0 ? assetAspectRatio : 1
        let fitW: CGFloat
        let fitH: CGFloat
        if ar >= 1 {
            fitW = b.width
            fitH = b.width / ar
        } else {
            fitH = b.height
            fitW = b.height * ar
        }
        return CGRect(x: (b.width - fitW) / 2, y: (b.height - fitH) / 2,
                      width: fitW, height: fitH)
    }

    func configure(asset: PhotoAsset, store: PhotosStore, isFocused: Bool, isCellSelected: Bool, useFit: Bool = false) {
        let idChanged = configuredID != asset.id
        self.isFocused        = isFocused
        self.isCellSelected   = isCellSelected
        self.configuredID     = asset.id
        self.useFit           = useFit
        self.assetAspectRatio = asset.aspectRatio > 0 ? asset.aspectRatio : 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.contentsGravity = useFit ? .resizeAspect : .resizeAspectFill
        borderLayer.frame = fitImageRect()
        CATransaction.commit()
        overlayView.fitRect = useFit ? fitImageRect() : nil

        if idChanged {
            loadTask?.cancel()
            loadTask = nil
            thumbLayer.contents = nil
        }

        updateBorder(isFocused: isFocused, isSelected: isCellSelected)
        overlayView.update(isVideo: asset.mediaType == .video, isFocused: isFocused, isSelected: isCellSelected)

        if let img = ThumbnailCache.shared.cachedImage(for: asset.id) {
            thumbLayer.contents = img
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
                self.thumbLayer.contents = img
            }
        }
    }

    override func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        configuredID = nil
        isFocused = false
        isCellSelected = false
        useFit = false
        assetAspectRatio = 1
        thumbLayer.contents = nil
        thumbLayer.contentsGravity = .resizeAspectFill
        borderLayer.borderWidth = 0
        overlayView.fitRect = nil
        overlayView.update(isVideo: false, isFocused: false, isSelected: false)
    }

    func updateOverlays(isFocused: Bool, isCellSelected: Bool) {
        self.isFocused      = isFocused
        self.isCellSelected = isCellSelected
        updateBorder(isFocused: isFocused, isSelected: isCellSelected)
        overlayView.update(isVideo: overlayView.isVideo, isFocused: isFocused, isSelected: isCellSelected)
    }

    private func updateBorder(isFocused: Bool, isSelected: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isFocused || isSelected {
            borderLayer.borderColor = NSColor.controlAccentColor.cgColor
            borderLayer.borderWidth = 2.5
        } else {
            borderLayer.borderWidth = 0
        }
        CATransaction.commit()
    }
}

// MARK: - Cell Overlay

final class CellOverlayView: NSView {
    private(set) var isVideo = false
    private var isFocused    = false
    private var isSelected   = false
    // nil = fill mode (full bounds); non-nil = fit mode image rect
    var fitRect: CGRect? = nil { didSet { if fitRect != oldValue { needsDisplay = true } } }

    func update(isVideo: Bool, isFocused: Bool, isSelected: Bool) {
        guard self.isVideo != isVideo || self.isFocused != isFocused || self.isSelected != isSelected else { return }
        self.isVideo    = isVideo
        self.isFocused  = isFocused
        self.isSelected = isSelected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = fitRect ?? bounds
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3).fill()

            let size: CGFloat = 18
            let margin: CGFloat = 4
            let cx = b.maxX - margin - size / 2
            let cy = b.maxY - margin - size / 2
            ctx.saveGState()
            let circle = CGPath(ellipseIn: CGRect(x: cx - size/2, y: cy - size/2, width: size, height: size), transform: nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(circle); ctx.fillPath()
            ctx.setFillColor(accentColor.cgColor)
            ctx.addPath(circle); ctx.fillPath()
            ctx.restoreGState()
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: "✓", attributes: attr)
            let strSize = str.size()
            str.draw(at: CGPoint(x: cx - strSize.width / 2, y: cy - strSize.height / 2))
        }

        if isVideo {
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: "▶", attributes: attr)
            let strSize = str.size()
            let padding: CGFloat = 5
            let capsW = strSize.width + padding * 2
            let capsH = strSize.height + 4
            let capsRect = CGRect(x: b.minX + 4, y: b.minY + 4, width: capsW, height: capsH)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: capsRect, xRadius: capsH / 2, yRadius: capsH / 2).fill()
            str.draw(at: CGPoint(x: capsRect.minX + padding, y: capsRect.minY + 2))
        }
    }

    private var accentColor: NSColor { .controlAccentColor }
}
