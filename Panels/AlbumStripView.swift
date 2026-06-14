import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - NSView snapshot helper

private extension NSView {
    func snapshot() -> NSImageView {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current {
            layer?.render(in: ctx.cgContext)
        }
        img.unlockFocus()
        let iv = NSImageView(frame: bounds)
        iv.image = img
        iv.wantsLayer = true
        return iv
    }
}

// MARK: - NSCollectionView favorite strip

private final class ChipCell: NSCollectionViewItem {
    private let label = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let bg = NSVisualEffectView()
    private let highlightLayer = CALayer()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .withinWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 5
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)

        highlightLayer.cornerRadius = 5
        highlightLayer.backgroundColor = NSColor.clear.cgColor
        bg.layer?.addSublayer(highlightLayer)

        keyLabel.font = .monospacedSystemFont(ofSize: Layout.chipKeyLabelSize, weight: .medium)
        keyLabel.textColor = NSColor.secondaryLabelColor
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [keyLabel, label])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = bg.layer?.bounds ?? .zero
        CATransaction.commit()
    }

    func configure(node: AlbumNode, index: Int) {
        label.stringValue = node.title
        if index < 10 {
            keyLabel.stringValue = index == 9 ? "0" : "\(index + 1)"
            keyLabel.isHidden = false
        } else {
            keyLabel.isHidden = true
        }
    }

    override var isSelected: Bool {
        didSet { applyHighlight() }
    }

    private func applyHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.backgroundColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
        label.textColor    = isSelected ? .white : .labelColor
        keyLabel.textColor = isSelected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
    }
}

// NSScrollView 子类：彻底屏蔽 overlay scroller 的出现
private final class NoScrollerScrollView: NSScrollView {
    override func flashScrollers() {}
    override var horizontalScroller: NSScroller? {
        get { nil }
        set {}
    }
    override var verticalScroller: NSScroller? {
        get { nil }
        set {}
    }
}

private final class FavoriteCollectionView: NSView,
    NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout
{
    var nodes: [AlbumNode] = [] {
        didSet {
            guard nodes.map(\.id) != oldValue.map(\.id) else { return }
            displayNodes = nodes
            collectionView.reloadData()
        }
    }
    var pressedIndex: Int? = nil {
        didSet {
            guard pressedIndex != oldValue else { return }
            // 更新旧值和新值对应的 cell 高亮状态
            for idx in [oldValue, pressedIndex].compactMap({ $0 }) {
                guard displayNodes.indices.contains(idx) else { continue }
                if let cell = collectionView.item(at: IndexPath(item: idx, section: 0)) as? ChipCell {
                    cell.isSelected = (idx == pressedIndex)
                }
            }
        }
    }
    var onAssign: ((AlbumNode) -> Void)?
    var onReorder: ((Int, Int) -> Void)?

    private var displayNodes: [AlbumNode] = []

    // 拖拽状态
    private var dragSrcIndex: Int? = nil       // displayNodes 中被拖项的当前位置
    private var dragView: NSView? = nil         // 跟随鼠标的浮动缩略图
    private var dragStartX: CGFloat = 0
    private var dragCurrentX: CGFloat = 0
    private var dragOriginalIndex: Int = 0
    private var cachedSizes: [String: NSSize] = [:]
    private var thresholds: [Int: ClosedRange<CGFloat>] = [:]
    private var isBatchUpdating = false         // 防止 performBatchUpdates 重入崩溃

    private let collectionView: NSCollectionView
    private let scrollView: NoScrollerScrollView

    override init(frame: NSRect) {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = Layout.chipSpacing
        layout.minimumLineSpacing = Layout.chipSpacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: Layout.chipHorizontalInset,
                                           bottom: 0, right: Layout.chipHorizontalInset)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ChipCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("chip"))

        scrollView = NoScrollerScrollView()
        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frame)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        collectionView.dataSource = self
        collectionView.delegate = self

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        collectionView.addGestureRecognizer(pan)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        collectionView.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - DataSource

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayNodes.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("chip"), for: indexPath) as! ChipCell
        cell.configure(node: displayNodes[indexPath.item], index: indexPath.item)
        cell.view.isHidden = (dragSrcIndex == indexPath.item)
        return cell
    }

    // MARK: - Layout

    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        guard indexPath.item < displayNodes.count else { return .zero }
        let node = displayNodes[indexPath.item]
        // 拖拽期间用预缓存尺寸，避免 moveItem 后 index 变化导致宽度不匹配
        if let cached = cachedSizes[node.id] { return cached }
        return measureSize(for: node, at: indexPath.item)
    }

    private func measureSize(for node: AlbumNode, at index: Int) -> NSSize {
        let titleAttr = NSAttributedString(string: node.title,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .callout)])
        var w = titleAttr.size().width + 18
        if index < 10 {
            let keyStr = index == 9 ? "0" : "\(index + 1)"
            let keyAttr = NSAttributedString(string: keyStr,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: Layout.chipKeyLabelSize, weight: .medium)])
            w += keyAttr.size().width + 4
        }
        return NSSize(width: ceil(w), height: Layout.chipHeight)
    }

    // MARK: - Pan gesture（行内拖拽排序）

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        let pt = recognizer.location(in: collectionView)

        switch recognizer.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: pt),
                  let cell = collectionView.item(at: indexPath)
            else { return }

            dragSrcIndex = indexPath.item
            dragOriginalIndex = indexPath.item
            dragStartX = pt.x
            dragCurrentX = pt.x

            // 缓存尺寸
            cachedSizes = [:]
            for (i, node) in displayNodes.enumerated() {
                cachedSizes[node.id] = measureSize(for: node, at: i)
            }

            // 预计算各目标 index 对应的位移阈值
            // 向右移到 index k：需要越过 [orig+1 ... k] 各 item 宽度之和的一半
            // 向左移到 index k：需要越过 [k ... orig-1] 各 item 宽度之和的一半（取负）
            thresholds = [:]
            let spacing = CGFloat(6)
            var rightAccum: CGFloat = 0
            for k in (indexPath.item + 1)..<displayNodes.count {
                let w = (cachedSizes[displayNodes[k].id] ?? NSSize(width: 60, height: 26)).width + spacing
                let prev = rightAccum
                rightAccum += w
                // 换到 k 的阈值：前一个累计 + 当前 item 宽的一半（滞后：进入要过半，退出要退回来）
                thresholds[k] = (prev + w * 0.5)...(rightAccum)
            }
            var leftAccum: CGFloat = 0
            for k in stride(from: indexPath.item - 1, through: 0, by: -1) {
                let w = (cachedSizes[displayNodes[k].id] ?? NSSize(width: 60, height: 26)).width + spacing
                let prev = leftAccum
                leftAccum += w
                // lowerBound = -(leftAccum)，upperBound = -(prev + w*0.5)，均为负值且 lower < upper
                thresholds[k] = (-leftAccum)...(-prev - w * 0.5)
            }

            let snap = cell.view.snapshot()
            snap.frame = collectionView.convert(cell.view.frame, from: cell.view.superview)
            snap.alphaValue = 0.85
            snap.shadow = {
                let s = NSShadow()
                s.shadowColor = NSColor.black.withAlphaComponent(0.35)
                s.shadowOffset = NSSize(width: 0, height: -2)
                s.shadowBlurRadius = 6
                return s
            }()
            collectionView.addSubview(snap)
            dragView = snap
            cell.view.isHidden = true

        case .changed:
            guard let src = dragSrcIndex, let dv = dragView else { return }

            let translation = recognizer.translation(in: collectionView)
            dv.frame.origin.x += translation.x
            recognizer.setTranslation(.zero, in: collectionView)
            dragCurrentX = pt.x

            // 用累计位移查阈值表，完全不依赖 layout 的动画中间状态
            let displacement = dragCurrentX - dragStartX
            let newDst = insertIndex(forDisplacement: displacement)
            guard newDst != src else { break }

            reorderPreview(from: src, to: newDst)

        case .ended, .cancelled:
            commitDrag()

        default:
            break
        }
    }

    // 根据累计位移查阈值表，找目标 index；阈值在拖拽开始时一次性计算，不依赖动画中的 layout 状态
    private func insertIndex(forDisplacement d: CGFloat) -> Int {
        // 找所有阈值中包含当前位移的 index；取位移绝对值最大的那个（即最远匹配）
        var best = dragOriginalIndex
        for (index, range) in thresholds {
            if range.contains(d) {
                // 多个 range 同时包含时（不应该但防御一下），取离原点更远的
                if abs(d) >= abs(thresholds[best]?.lowerBound ?? 0) {
                    best = index
                }
            }
        }
        // 若没有 range 包含，找位移最接近的方向上最远的已越过阈值
        if best == dragOriginalIndex {
            if d > 0 {
                // 向右：找所有 lowerBound <= d 的最大 index
                for (index, range) in thresholds where index > dragOriginalIndex && range.lowerBound <= d {
                    if index > best { best = index }
                }
            } else {
                // 向左：找所有 upperBound >= d 的最小 index
                for (index, range) in thresholds where index < dragOriginalIndex && range.upperBound >= d {
                    if index < best { best = index }
                }
            }
        }
        return best
    }

    private func reorderPreview(from src: Int, to dst: Int) {
        guard !isBatchUpdating,
              displayNodes.indices.contains(src),
              displayNodes.indices.contains(dst) else { return }

        var newOrder = displayNodes
        let moved = newOrder.remove(at: src)
        newOrder.insert(moved, at: dst)
        guard newOrder.map(\.id) != displayNodes.map(\.id) else { return }

        let oldIDs = displayNodes.map(\.id)
        let newIDs = newOrder.map(\.id)

        // 1. 记录所有 cell 移动前的 minX（collectionView 坐标系）
        var beforeMinX: [String: CGFloat] = [:]
        for (i, id) in oldIDs.enumerated() {
            if let cell = collectionView.item(at: IndexPath(item: i, section: 0)) {
                beforeMinX[id] = cell.view.frame.minX
            }
        }

        displayNodes = newOrder
        dragSrcIndex = dst
        isBatchUpdating = true

        // 2. 瞬间更新数据和 layout（无动画）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.performBatchUpdates({
            for (newIdx, id) in newIDs.enumerated() {
                if let oldIdx = oldIDs.firstIndex(of: id), oldIdx != newIdx {
                    collectionView.moveItem(
                        at: IndexPath(item: oldIdx, section: 0),
                        to: IndexPath(item: newIdx, section: 0)
                    )
                }
            }
        }, completionHandler: { [weak self] _ in
            guard let self else { return }

            // 3. 对每个 X 位置变化了的 cell，用 transform.translation.x 从偏移量动画回 0
            //    完全在 cell 自身坐标系操作，不受父子坐标系影响
            let duration: CFTimeInterval = Anim.dragSettleDuration
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            let srcID = self.dragSrcIndex.map { self.displayNodes[$0].id }

            for (newIdx, id) in newIDs.enumerated() {
                guard id != srcID else { continue }
                guard let oldX = beforeMinX[id],
                      let cell = self.collectionView.item(at: IndexPath(item: newIdx, section: 0)),
                      let layer = cell.view.layer
                else { continue }

                let newX = cell.view.frame.minX
                let deltaX = oldX - newX   // cell 需要从 oldX 滑到 newX，即从 +deltaX 偏移动画到 0
                guard abs(deltaX) > 0.5 else { continue }

                let anim = CABasicAnimation(keyPath: "transform.translation.x")
                anim.fromValue = deltaX
                anim.toValue = 0
                anim.duration = duration
                anim.timingFunction = timing
                layer.add(anim, forKey: "reorderMove")
            }

            self.isBatchUpdating = false
            for i in 0..<self.displayNodes.count {
                self.collectionView.item(at: IndexPath(item: i, section: 0))?.view.isHidden =
                    (self.dragSrcIndex == i)
            }
        })
        CATransaction.commit()
    }

    private func commitDrag() {
        guard let src = dragSrcIndex else { return }

        // 将浮动视图动画移动到目标 cell 位置后移除
        if let dv = dragView,
           let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: src, section: 0)) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Anim.dragCommitDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dv.animator().frame.origin.x = attrs.frame.origin.x
            } completionHandler: { [weak self] in
                dv.removeFromSuperview()
                self?.dragView = nil
                // 显示落点 cell
                self?.collectionView.item(at: IndexPath(item: src, section: 0))?.view.isHidden = false
            }
        } else {
            dragView?.removeFromSuperview()
            dragView = nil
            collectionView.item(at: IndexPath(item: src, section: 0))?.view.isHidden = false
        }

        let srcNode = displayNodes[src]
        let originalSrc = nodes.firstIndex(where: { $0.id == srcNode.id })
        dragSrcIndex = nil
        isBatchUpdating = false
        cachedSizes = [:]
        thresholds = [:]

        if let originalSrc, originalSrc != src {
            onReorder?(originalSrc, src)
        }
    }

    // MARK: - Click → assign

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard dragSrcIndex == nil else { return }
        let pt = recognizer.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: pt) {
            onAssign?(displayNodes[indexPath.item])
        }
    }
}

private struct FavoriteStripView: NSViewRepresentable {
    let nodes: [AlbumNode]
    let onAssign: (AlbumNode) -> Void
    let onReorder: (Int, Int) -> Void
    var pressedIndex: Int? = nil

    func makeNSView(context: Context) -> FavoriteCollectionView {
        let v = FavoriteCollectionView(frame: .zero)
        v.onAssign = onAssign
        v.onReorder = onReorder
        return v
    }

    func updateNSView(_ nsView: FavoriteCollectionView, context: Context) {
        nsView.nodes = nodes
        nsView.onAssign = onAssign
        nsView.onReorder = onReorder
        nsView.pressedIndex = pressedIndex
    }
}

// MARK: - AlbumStripCombined

struct AlbumStripCombined: View {
    let favoriteNodes: [AlbumNode]
    let recentNodes: [AlbumNode]
    let onAssign: (AlbumNode) -> Void
    let onReorderFavorites: (Int, Int) -> Void
    var isInSingleMode: Bool = false
    var autoHideInSingleMode: Bool = true
    /// 浅色模式下底部渐变过半时由调用方置 true，强制文字用白色
    var forceLightText: Bool = false
    /// 当前长按高亮的收藏索引（由外部键盘监测驱动）
    var pressedIndex: Int? = nil
    /// 长按数字键期间强制显示（即使 autoHideInSingleMode 为 true）
    var forceShow: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private let rowHeight      = Layout.stripRowHeight
    private let hoverTriggerH  = Layout.stripHoverTriggerHeight

    private var shouldHide: Bool {
        isInSingleMode && autoHideInSingleMode && !isHovered && !forceShow
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TrackingAreaView { hovering in isHovered = hovering }
                .frame(height: hoverTriggerH)
                .allowsHitTesting(false)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    favoritesRow
                    recentRow
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight)
            .opacity(shouldHide ? 0 : 1)
            .animation(.easeInOut(duration: Anim.fadeInOut), value: shouldHide)
            .allowsHitTesting(!shouldHide)
        }
        .frame(height: hoverTriggerH)
    }

    // MARK: - Rows

    private var favoritesRow: some View {
        HStack(spacing: 0) {
            rowLabel(icon: "star.fill", title: "收藏", color: .yellow)
            Divider().padding(.vertical, 8)

            if favoriteNodes.isEmpty {
                emptyHint("Hover 相册，点击 ★ 收藏")
            } else {
                FavoriteStripView(
                    nodes: favoriteNodes,
                    onAssign: onAssign,
                    onReorder: onReorderFavorites,
                    pressedIndex: pressedIndex
                )
            }
        }
        .frame(height: rowHeight)
    }

    private var recentRow: some View {
        HStack(spacing: 0) {
            rowLabel(icon: "clock", title: "最近",
                     color: useLightText ? Color.white.opacity(0.6) : Color(.secondaryLabelColor))
            Divider().padding(.vertical, 8)

            if recentNodes.isEmpty {
                emptyHint("归类后自动出现在此")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recentNodes) { node in
                            Button { onAssign(node) } label: {
                                chip(title: node.title)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(height: rowHeight)
    }

    // MARK: - Shared chip visual (recent row only)

    private func chip(title: String) -> some View {
        Text(title)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                        Color.white.opacity(0.12), lineWidth: 1))
            )
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var useLightText: Bool {
        forceLightText || (isInSingleMode && colorScheme == .dark)
    }

    private func rowLabel(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(useLightText ? Color.white.opacity(0.85) : Color.secondary)
        }
        .animation(.easeInOut(duration: Anim.fadeInOut), value: useLightText)
        .frame(width: 60, alignment: .leading)
        .padding(.leading, 10)
    }

    private func emptyHint(_ text: String) -> some View {
        HStack {
            Text(text).font(.caption2)
                .foregroundStyle(useLightText ? AnyShapeStyle(Color.white.opacity(0.4)) : AnyShapeStyle(.tertiary))
                .animation(.easeInOut(duration: Anim.fadeInOut), value: useLightText)
                .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
    }
}
