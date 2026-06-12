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
    var useThumbnailFit: Bool = false
    var sections: [SectionData]? = nil
    var externalSelectedIDs: Binding<Set<String>>? = nil
    var onSelectAll: (() -> Void)? = nil

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
                    PhotoCollectionView(
                        store: store,
                        focusedID: $focusedID,
                        focusedFrame: $focusedFrame,
                        gridLayout: gridLayout,
                        topPadding: topPadding,
                        bottomPadding: bottomPadding,
                        useThumbnailFit: useThumbnailFit,
                        sections: sections,
                        externalSelectedIDs: externalSelectedIDs,
                        onScrollChange: { offsetY, contentH, containerH in
                            gridLayout.scrollOffset = -offsetY
                            let threshold: CGFloat = 48
                            topGradientOpacity    = min(1, max(0, offsetY / threshold))
                            bottomGradientOpacity = min(1, max(0, (contentH - containerH - offsetY) / threshold))
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
