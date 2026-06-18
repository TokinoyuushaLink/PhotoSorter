import Photos
import AppKit

// NSImage is safe to pass across actor boundaries in this codebase: all reads and writes
// happen on the main thread or within ThumbnailCache's serialized actor context.
extension NSImage: @unchecked @retroactive Sendable {}

// Scroll-driven thumbnail loader. Cells request images directly via `thumbnail(for:phAsset:)`;
// no batch timer, no store mutation, no SwiftUI re-render signal needed.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    enum ThumbSource { case disk, phImageManager }

    // Separate lock-protected store so cachedImage can be called synchronously from any
    // context (SwiftUI body, cell configure) without an actor hop or async/await.
    private let store = SyncCache()

    private var pending: Set<String> = []

    // Returns cached image immediately — no actor hop, safe to call from SwiftUI body.
    nonisolated func cachedImage(for id: String) -> NSImage? {
        store.get(id)
    }

    nonisolated func cachedSource(for id: String) -> ThumbSource? {
        store.getSource(id)
    }

    // Full async path: direct disk read, fallback to PHImageManager.
    func thumbnail(for id: String, phAsset: PHAsset) async -> NSImage? {
        if let img = store.get(id) { return img }
        if pending.contains(id) {
            for _ in 0..<20 {
                await Task.yield()
                if let img = store.get(id) { return img }
            }
            return store.get(id)
        }
        pending.insert(id)

        let img: NSImage?
        let source: ThumbSource
        if let direct = directReadImage(phAsset: phAsset) {
            img = direct
            source = .disk
        } else {
            img = await phImageManagerLoad(phAsset: phAsset)
            source = .phImageManager
        }

        pending.remove(id)
        guard let img else { return nil }
        let normalized = normalizeForSwiftUI(img)
        store.set(id, image: normalized, source: source)
        return normalized
    }

    func invalidate() {
        store.removeAll()
        pending = []
    }

    func storeImage(id: String, image: NSImage, source: ThumbSource = .phImageManager) {
        store.set(id, image: image, source: source)
    }

    // MARK: - Private

    private func directReadImage(phAsset: PHAsset) -> NSImage? {
        guard let base = PhotoLibrary.mastersBase else { return nil }
        let uuid = phAsset.localIdentifier.components(separatedBy: "/").first ?? phAsset.localIdentifier
        let dir  = "\(base)/\(String(uuid.prefix(1)).uppercased())"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let match = files.first(where: { $0.hasPrefix(uuid) })
        else { return nil }
        return NSImage(contentsOfFile: "\(dir)/\(match)")
    }

    private func phImageManagerLoad(phAsset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode   = .fast
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: Layout.thumbnailSize,
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in cont.resume(returning: image) }
        }
    }
}

// Lock-protected dictionary so cachedImage/cachedSource can be called from nonisolated context.
private final class SyncCache: @unchecked Sendable {
    private var cache: [String: NSImage] = [:]
    private var sources: [String: ThumbnailCache.ThumbSource] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let maxSize = 400

    func get(_ id: String) -> NSImage? {
        lock.withLock { cache[id] }
    }

    func getSource(_ id: String) -> ThumbnailCache.ThumbSource? {
        lock.withLock { sources[id] }
    }

    func set(_ id: String, image: NSImage, source: ThumbnailCache.ThumbSource = .phImageManager) {
        lock.withLock {
            cache[id] = image
            sources[id] = source
            order.append(id)
            while cache.count > maxSize, let oldest = order.first {
                order.removeFirst()
                cache.removeValue(forKey: oldest)
                sources.removeValue(forKey: oldest)
            }
        }
    }

    func removeAll() {
        lock.withLock { cache = [:]; sources = [:]; order = [] }
    }
}
