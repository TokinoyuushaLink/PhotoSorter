import SwiftUI
import Photos
import AppKit

struct PhotoGridView: View {
    @Bindable var store: PhotosStore
    @Binding var focusedID: String?
    @Binding var focusedFrame: CGRect
    var gridLayout: GridLayout
    let onOpenPreview: () -> Void
    @Binding var topGradientOpacity: CGFloat
    @Binding var bottomGradientOpacity: CGFloat
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0
    var sections: [SectionData]? = nil     // nil = uncategorized mode (uses store.assets)
    var externalSelectedIDs: Binding<Set<String>>? = nil
    var onSelectAll: (() -> Void)? = nil   // called by Cmd+A in section mode
    var onFrameProviderReady: ((@escaping (Int) -> CGRect) -> Void)?

    @State private var frameProvider: ((Int) -> CGRect)?

    private var isEmpty: Bool {
        sections.map { $0.allSatisfy { $0.assets.isEmpty } } ?? store.assets.isEmpty
    }

    var body: some View {
        Group {
            if store.isLoading && sections == nil {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在加载未归类照片…")
                        .foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48)).foregroundStyle(.tertiary)
                    Text(sections != nil ? "本次还没有分类记录" : "所有照片都已归类").font(.title3)
                    if sections == nil {
                        Text("点击「刷新」重新检查")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                GeometryReader { geo in
                    let spacing: CGFloat = 2
                    let cols = max(2, Int(geo.size.width / Layout.gridMinCellWidth))
                    let cellSize = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)

                    PhotoCollectionView(
                        store: store,
                        focusedID: $focusedID,
                        focusedFrame: $focusedFrame,
                        gridLayout: gridLayout,
                        cols: cols,
                        cellSize: cellSize,
                        topPadding: topPadding,
                        bottomPadding: bottomPadding,
                        sections: sections,
                        externalSelectedIDs: externalSelectedIDs,
                        onScrollChange: { offsetY, contentH, containerH in
                            gridLayout.scrollOffset = -offsetY
                            let threshold: CGFloat = 48
                            topGradientOpacity    = min(1, max(0, offsetY / threshold))
                            bottomGradientOpacity = min(1, max(0, (contentH - containerH - offsetY) / threshold))
                        },
                        onFrameProviderReady: { provider in
                            frameProvider = provider
                            onFrameProviderReady?(provider)
                        }
                    )
                    .onChange(of: geo.size, initial: true) { _, _ in
                        rebuildLayout(geo: geo)
                    }
                    .onChange(of: topPadding) { _, _ in
                        rebuildLayout(geo: geo)
                    }
                    .background(
                        KeyEventView { key in
                            switch key {
                            case .space:
                                if let id = focusedID {
                                    // Find flat index across all sections (or store.assets)
                                    let flatIdx: Int?
                                    if let secs = sections {
                                        var off = 0
                                        var found: Int? = nil
                                        for sec in secs {
                                            if let i = sec.assets.firstIndex(where: { $0.id == id }) {
                                                found = off + i; break
                                            }
                                            off += sec.assets.count
                                        }
                                        flatIdx = found
                                    } else {
                                        flatIdx = store.assets.firstIndex(where: { $0.id == id })
                                    }
                                    if let idx = flatIdx {
                                        focusedFrame = frameProvider?(idx) ?? gridLayout.frameFor(index: idx)
                                    }
                                }
                                onOpenPreview()
                            case .selectAll:
                                if let onSelectAll { onSelectAll() } else { store.selectAll() }
                            default:
                                break
                            }
                        }
                    )
                }
            }
        }
    }

    private func rebuildLayout(geo: GeometryProxy) {
        let spacing: CGFloat = 2
        let w = geo.size.width
        let cols = max(2, Int(w / Layout.gridMinCellWidth))
        let cellSize = (w - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let gf = geo.frame(in: .global)
        gridLayout.cols      = cols
        gridLayout.cellSize  = cellSize
        gridLayout.spacing   = spacing
        gridLayout.originX   = gf.minX
        gridLayout.originY   = gf.minY + topPadding
    }
}
