import Photos
import Foundation

// MARK: - Tree Node

final class AlbumNode: Identifiable, Equatable {
    static func == (lhs: AlbumNode, rhs: AlbumNode) -> Bool { lhs.id == rhs.id }

    let id: String
    let title: String
    let kind: Kind

    enum Kind {
        case folder
        case album(PHAssetCollection)
    }

    var children: [AlbumNode]?  // nil = leaf (album); [] = empty folder

    init(id: String, title: String, kind: Kind, children: [AlbumNode]? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.children = children
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var assetCollection: PHAssetCollection? {
        if case .album(let col) = kind { return col }
        return nil
    }
}

// MARK: - AlbumsStore

@Observable
final class AlbumsStore {

    var roots: [AlbumNode] = []
    var recentAlbumIDs: [String] = []
    var recentNodes: [AlbumNode] = []
    var favoriteIDs: [String] = []       // ordered; position determines keyboard shortcut
    var favoriteNodes: [AlbumNode] = []

    private let recentKey   = "ps.recentAlbums"
    private let favoriteKey = "ps.favoriteAlbums"
    private var observers: [NSObjectProtocol] = []

    init() {
        loadPersistedData()
        observers.append(NotificationCenter.default.addObserver(
            forName: .clearFavoritesRequested, object: nil, queue: .main
        ) { [weak self] _ in self?.clearFavorites() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .clearRecentRequested, object: nil, queue: .main
        ) { [weak self] _ in self?.clearRecent() })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Load

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = Self.buildTree()
            DispatchQueue.main.async {
                guard let self else { return }
                self.roots = tree
                self.rebuildDerivedLists()
            }
        }
    }

    // MARK: Search

    func search(query: String) -> [AlbumNode] {
        let lowered = query.lowercased()
        return allAlbumNodes(in: roots).filter { $0.title.lowercased().contains(lowered) }
    }

    // MARK: Favorites

    func toggleFavorite(_ node: AlbumNode) {
        if let idx = favoriteIDs.firstIndex(of: node.id) {
            favoriteIDs.remove(at: idx)
        } else {
            favoriteIDs.append(node.id)
        }
        UserDefaults.standard.set(favoriteIDs, forKey: favoriteKey)
        rebuildDerivedLists()
    }

    func isFavorite(_ node: AlbumNode) -> Bool {
        favoriteIDs.contains(node.id)
    }

    func clearFavorites() {
        favoriteIDs = []
        UserDefaults.standard.set(favoriteIDs, forKey: favoriteKey)
        rebuildDerivedLists()
    }

    // to 是 NSCollectionView 给出的 drop 最终插入位置（before 语义，remove 之前的 index 空间）
    func reorderFavorites(from: Int, to: Int) {
        guard favoriteIDs.indices.contains(from) else { return }
        let clampedTo = min(to, favoriteIDs.count - 1)
        guard from != clampedTo else { return }
        let id = favoriteIDs.remove(at: from)
        // remove 之后 to 若在 from 右侧，index 整体左移一位
        let insertAt = from < clampedTo ? clampedTo - 1 : clampedTo
        favoriteIDs.insert(id, at: insertAt)
        UserDefaults.standard.set(favoriteIDs, forKey: favoriteKey)
        rebuildDerivedLists()
    }

    // MARK: Recent

    func recordRecent(_ node: AlbumNode) {
        var ids = recentAlbumIDs.filter { $0 != node.id }
        ids.insert(node.id, at: 0)
        if ids.count > Layout.recentAlbumsMaxCount {
            ids = Array(ids.prefix(Layout.recentAlbumsMaxCount))
        }
        recentAlbumIDs = ids
        UserDefaults.standard.set(ids, forKey: recentKey)
        rebuildDerivedLists()
    }

    func clearRecent() {
        recentAlbumIDs = []
        UserDefaults.standard.set(recentAlbumIDs, forKey: recentKey)
        rebuildDerivedLists()
    }

    // MARK: Private

    private func loadPersistedData() {
        recentAlbumIDs = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        favoriteIDs = UserDefaults.standard.stringArray(forKey: favoriteKey) ?? []
    }

    private func rebuildDerivedLists() {
        let leavesByID = Dictionary(
            uniqueKeysWithValues: allAlbumNodes(in: roots).map { ($0.id, $0) }
        )
        favoriteNodes = favoriteIDs.compactMap { leavesByID[$0] }  // preserve insertion order
        recentNodes = recentAlbumIDs.compactMap { leavesByID[$0] }
    }

    private func allAlbumNodes(in nodes: [AlbumNode]) -> [AlbumNode] {
        nodes.flatMap { node in
            node.isFolder ? allAlbumNodes(in: node.children ?? []) : [node]
        }
    }

    // MARK: Tree Builder

    private static func buildTree() -> [AlbumNode] {
        var roots: [AlbumNode] = []
        PHCollectionList.fetchTopLevelUserCollections(with: nil)
            .enumerateObjects { collection, _, _ in
                if let list = collection as? PHCollectionList {
                    roots.append(buildFolderNode(list))
                } else if let album = collection as? PHAssetCollection {
                    roots.append(AlbumNode(
                        id: album.localIdentifier,
                        title: album.localizedTitle ?? "未命名",
                        kind: .album(album)
                    ))
                }
            }
        return roots
    }

    private static func buildFolderNode(_ list: PHCollectionList) -> AlbumNode {
        var childNodes: [AlbumNode] = []
        PHCollection.fetchCollections(in: list, options: nil)
            .enumerateObjects { collection, _, _ in
                if let subList = collection as? PHCollectionList {
                    childNodes.append(buildFolderNode(subList))
                } else if let album = collection as? PHAssetCollection {
                    childNodes.append(AlbumNode(
                        id: album.localIdentifier,
                        title: album.localizedTitle ?? "未命名",
                        kind: .album(album)
                    ))
                }
            }
        return AlbumNode(
            id: list.localIdentifier,
            title: list.localizedTitle ?? "文件夹",
            kind: .folder,
            children: childNodes
        )
    }
}
