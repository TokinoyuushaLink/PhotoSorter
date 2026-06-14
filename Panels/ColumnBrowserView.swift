import SwiftUI

struct ColumnBrowserView: View {
    var roots: [AlbumNode]
    var albumsStore: AlbumsStore
    var onAssign: (AlbumNode) -> Void

    @State private var columns: [[AlbumNode]] = []
    @State private var selections: [String?] = []
    @State private var visibleWidth: CGFloat = Layout.columnWidth * 2
    @State private var scrollGeneration = 0
    @State private var colHeight: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { colIdx, nodes in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 1) {
                                ForEach(nodes) { node in
                                    ColumnRowView(
                                        node: node,
                                        isSelected: colIdx < selections.count && selections[colIdx] == node.id,
                                        isFavorite: albumsStore.isFavorite(node),
                                        onSelect: { handleSelect(node: node, atColumn: colIdx) },
                                        onToggleFavorite: { albumsStore.toggleFavorite(node) }
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.top, Layout.titlebarAreaHeight)
                        .frame(minHeight: colHeight, alignment: .center)
                        }
                        .id(colIdx)
                        .frame(width: Layout.columnWidth)

                        Divider()
                    }
                }
                // 面板宽度不足以显示两列时，展开子列后无动画对齐到最右列左端
                .onChange(of: scrollGeneration) { _, _ in
                    guard columns.count > 1,
                          visibleWidth < Layout.columnWidth * 2 + 2 else { return }
                    proxy.scrollTo(columns.count - 1, anchor: .leading)
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { visibleWidth = geo.size.width; colHeight = geo.size.height }
                    .onChange(of: geo.size) { _, s in visibleWidth = s.width; colHeight = s.height }
            }
        )
        .onAppear {
            columns = [roots]
            selections = [nil]
        }
        .onChange(of: roots) { _, newRoots in
            columns = [newRoots]
            selections = [nil]
        }
    }

    private func handleSelect(node: AlbumNode, atColumn colIdx: Int) {
        var newSelections = Array(selections.prefix(colIdx + 1))
        newSelections[colIdx] = node.id

        if node.isFolder, let children = node.children, !children.isEmpty {
            columns = Array(columns.prefix(colIdx + 1)) + [children]
            selections = newSelections + [nil]
            scrollGeneration += 1
        } else {
            columns = Array(columns.prefix(colIdx + 1))
            // 相册：短暂高亮后清除，文件夹高亮由上面分支维持
            selections = Array(selections.prefix(colIdx + 1))
            if !node.isFolder {
                onAssign(node)
                DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnHighlightDelay) {
                    selections = newSelections
                    DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnClearDelay) {
                        newSelections[colIdx] = nil
                        selections = newSelections
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct ColumnRowView: View {
    let node: AlbumNode
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder.fill" : "photo.on.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(node.isFolder
                    ? (isSelected ? Color.white : Color(nsColor: .systemBlue))
                    : (isSelected ? .white : .secondary))
                .frame(width: 16, alignment: .center)

            Text(node.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .primary)

            Spacer(minLength: 0)

            if !node.isFolder && (isHovered || isFavorite) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundStyle(isFavorite
                            ? (isSelected || colorScheme == .dark ? Color.yellow : Color(nsColor: .secondaryLabelColor))
                            : (isSelected ? Color.white.opacity(0.6) : .secondary))
                }
                .buttonStyle(.plain)
            }

            if node.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor
                      : (isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }
}

