import Photos
import AppKit

// Scroll-driven thumbnail loader. Cells request images directly via `thumbnail(for:phAsset:)`;
// no batch timer, no store mutation, no SwiftUI re-render signal needed.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    private var cache:   [String: NSImage] = [:]
    private var pending: Set<String>       = []
    // FIFO eviction order
    private var order:   [String]          = []
    private let maxSize  = 400

    enum ThumbSource { case disk, phImageManager }
    private var sources: [String: ThumbSource] = [:]

    // Returns cached image immediately (no suspension) — call from cell configure before
    // launching an async task so already-loaded thumbnails appear without a Task hop.
    func cachedImage(for id: String) -> NSImage? {
        cache[id]
    }

    func cachedSource(for id: String) -> ThumbSource? {
        sources[id]
    }

    // Full async path: direct disk read, fallback to PHImageManager.
    func thumbnail(for id: String, phAsset: PHAsset) async -> NSImage? {
        if let img = cache[id] { return img }
        if pending.contains(id) {
            for _ in 0..<20 {
                await Task.yield()
                if let img = cache[id] { return img }
            }
            return cache[id]
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
        store(id: id, image: normalized, source: source)
        return normalized
    }

    func invalidate() {
        cache   = [:]
        sources = [:]
        pending = []
        order   = []
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

    func store(id: String, image: NSImage, source: ThumbSource = .phImageManager) {
        cache[id] = image
        sources[id] = source
        order.append(id)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > maxSize, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
            sources.removeValue(forKey: oldest)
        }
    }
}
