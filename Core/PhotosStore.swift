import Photos
import AppKit
import SwiftUI


// MARK: - Asset Model

struct PhotoAsset: Identifiable, Equatable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaType: PHAssetMediaType
    var preview: NSImage?
    var isGIF: Bool

    var aspectRatio: CGFloat {
        pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1
    }

    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool { lhs.id == rhs.id }

    static let placeholder = PhotoAsset(
        id: "__placeholder__", creationDate: nil,
        pixelWidth: 1, pixelHeight: 1,
        mediaType: .image, isGIF: false
    )
}

// MARK: - PhotosStore
// 职责：照片列表状态管理、PHAsset 缓存、归类写入、选中状态。
// 预览图加载由 PreviewLoader 负责（注入依赖）。

@Observable
final class PhotosStore {

    var authStatus: PHAuthorizationStatus = .notDetermined
    var assets: [PhotoAsset] = []
    var isLoading = false
    var selectedIDs: Set<String> = []

    private var phAssetCache: [String: PHAsset] = [:]
    private var assetIndexByID: [String: Int] = [:]
    private let previewLoader = PreviewLoader()

    func phAsset(for id: String) -> PHAsset? { phAssetCache[id] }

    init() {}

    // MARK: Auth

    func requestAuthorization() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.authStatus = status
                if status == .authorized || status == .limited { self?.loadUncategorized() }
            }
        }
    }

    func checkCurrentAuthorization() {
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .authorized || authStatus == .limited { loadUncategorized() }
    }

    // MARK: Load

    func loadUncategorized() {
        isLoading = true
        assets = []
        selectedIDs = []
        phAssetCache = [:]
        assetIndexByID = [:]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var idsInAlbums = Set<String>()
            let albums = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .any, options: nil)
            albums.enumerateObjects { col, _, _ in
                PHAsset.fetchAssets(in: col, options: nil)
                    .enumerateObjects { a, _, _ in idsInAlbums.insert(a.localIdentifier) }
            }

            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let all = PHAsset.fetchAssets(with: opts)

            var result: [PhotoAsset] = []
            var cache: [String: PHAsset] = [:]
            all.enumerateObjects { phAsset, _, _ in
                guard !idsInAlbums.contains(phAsset.localIdentifier) else { return }
                let isGIF = PHAssetResource.assetResources(for: phAsset)
                    .contains { $0.uniformTypeIdentifier == "com.compuserve.gif" }
                result.append(PhotoAsset(
                    id: phAsset.localIdentifier,
                    creationDate: phAsset.creationDate,
                    pixelWidth: phAsset.pixelWidth,
                    pixelHeight: phAsset.pixelHeight,
                    mediaType: phAsset.mediaType,
                    isGIF: isGIF
                ))
                cache[phAsset.localIdentifier] = phAsset
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.assets = result
                self.phAssetCache = cache
                self.assetIndexByID = Dictionary(
                    uniqueKeysWithValues: result.enumerated().map { ($1.id, $0) }
                )
                self.isLoading = false
                self.loadPreviewsBatched()
            }
        }
    }

    // MARK: Previews

    func loadPreviewIfNeeded(for id: String) {
        guard let idx = assetIndexByID[id], idx < assets.count, assets[idx].preview == nil else { return }
        guard let phAsset = phAssetCache[id] else { return }
        previewLoader.loadIfNeeded(id: id, phAsset: phAsset) { [weak self] image in
            guard let self,
                  let idx = self.assetIndexByID[id],
                  idx < self.assets.count,
                  self.assets[idx].id == id else { return }
            withoutAnimation { self.assets[idx].preview = image }
        }
    }

    private func loadPreviewsBatched() {
        let items = assets.compactMap { a -> (id: String, phAsset: PHAsset)? in
            guard let ph = phAssetCache[a.id] else { return nil }
            return (id: a.id, phAsset: ph)
        }
        previewLoader.loadBatched(items: items) { [weak self] id, image in
            guard let self,
                  let idx = self.assetIndexByID[id],
                  idx < self.assets.count,
                  self.assets[idx].id == id else { return }
            withoutAnimation { self.assets[idx].preview = image }
        }
    }

    // MARK: Selection

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func selectAll() { selectedIDs = Set(assets.map(\.id)) }
    func clearSelection() { selectedIDs = [] }
    func selectRange(from fromIndex: Int, to toIndex: Int) {
        let lo = min(fromIndex, toIndex)
        let hi = max(fromIndex, toIndex)
        guard lo >= 0, hi < assets.count else { return }
        for i in lo...hi { selectedIDs.insert(assets[i].id) }
    }

    // MARK: Add to Existing Album

    func addIDs(_ ids: [String], to collection: PHAssetCollection,
                albumNode: AlbumNode? = nil, history: SortHistory? = nil,
                completion: (() -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        performAdd(to: collection, displayName: collection.localizedTitle ?? "",
                   ids: ids, albumNode: albumNode, history: history, completion: completion)
    }

    // MARK: Direct Remove (for pending-delete from uncategorized view)

    func removeAssetsDirectly(ids: [String]) {
        removeAssets(ids: ids)
    }

    // MARK: Restore (Undo)

    func restoreAssets(_ restoredAssets: [PhotoAsset]) {
        for asset in restoredAssets {
            guard !assets.contains(where: { $0.id == asset.id }) else { continue }
            // Insert at correct creationDate-descending position
            let insertIdx = assets.firstIndex(where: {
                ($0.creationDate ?? .distantPast) < (asset.creationDate ?? .distantPast)
            }) ?? assets.count
            assets.insert(asset, at: insertIdx)
            phAssetCache[asset.id] = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject
        }
        rebuildAssetIndex()
    }

    // MARK: Private

    private func performAdd(to album: PHAssetCollection,
                            displayName: String, ids: [String],
                            albumNode: AlbumNode?, history: SortHistory?,
                            completion: (() -> Void)?) {
        let snapshots = ids.compactMap { id in assets.first(where: { $0.id == id }) }
        removeAssets(ids: ids)
        if let node = albumNode, let history {
            history.record(SortAction(albumNode: node, originalAssets: snapshots))
        }
        completion?()
        NotificationCenter.default.post(name: .assetsDidSort,
                                        object: "已将 \(ids.count) 张照片归入「\(displayName)」")
    }

    private func removeAssets(ids: [String]) {
        let idSet = Set(ids)
        assets.removeAll { idSet.contains($0.id) }
        ids.forEach {
            phAssetCache.removeValue(forKey: $0)
            assetIndexByID.removeValue(forKey: $0)
        }
        selectedIDs.subtract(idSet)
    }

    private func rebuildAssetIndex() {
        assetIndexByID = Dictionary(
            uniqueKeysWithValues: assets.enumerated().map { ($1.id, $0) }
        )
    }
}
