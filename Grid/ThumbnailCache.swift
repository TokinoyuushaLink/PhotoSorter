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
    private let maxSize  = 400             // ~160 MB BGRA at 320×320

    // Returns cached image immediately (no suspension) — call from cell configure before
    // launching an async task so already-loaded thumbnails appear without a Task hop.
    func cachedImage(for id: String) -> NSImage? {
        cache[id]
    }

    // Full async path: returns cached result or fires a PHImageManager request.
    func thumbnail(for id: String, phAsset: PHAsset) async -> NSImage? {
        if let img = cache[id] { return img }
        if pending.contains(id) {
            // Another task is already loading this id — wait by polling cheaply.
            // In practice this is rare; a simple retry after a short yield is sufficient.
            for _ in 0..<20 {
                await Task.yield()
                if let img = cache[id] { return img }
            }
            return cache[id]
        }
        pending.insert(id)

        let img = await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat   // single callback, no double-fire
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

        pending.remove(id)
        guard let img else { return nil }
        let normalized = normalizeForSwiftUI(img)
        store(id: id, image: normalized)
        return normalized
    }

    // Eagerly cancel pending PHImageManager requests when the cell is reused.
    // We can't cancel individual PHImageManager requests without tracking request IDs,
    // so we just mark the id as no longer needed; the Task on the cell side is cancelled
    // by PhotoCell.prepareForReuse — which is sufficient.

    func invalidate() {
        cache   = [:]
        pending = []
        order   = []
    }

    // MARK: - Private

    func store(id: String, image: NSImage) {
        cache[id] = image
        order.append(id)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > maxSize, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
