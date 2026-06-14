import Photos
import AppKit

/// 负责为 PhotoAsset 加载预览图（原始比例，供单图模式使用）。
/// 与 PhotosStore 解耦：通过回调写回 assets 数组，不持有 Store 引用。
final class PreviewLoader {

    private let queue = DispatchQueue(label: "photosorter.previews", qos: .userInitiated)

    /// 按需加载单张预览（进入单图模式时触发）。
    /// - Parameters:
    ///   - id: PhotoAsset.id
    ///   - phAsset: 对应的 PHAsset
    ///   - completion: 主线程回调，返回加载好的 NSImage
    func loadIfNeeded(id: String, phAsset: PHAsset, completion: @escaping (NSImage) -> Void) {
        queue.async {
            self.loadOne(id: id, phAsset: phAsset, completion: completion)
        }
    }

    /// 批量预加载（loadUncategorized 完成后触发）。
    /// - Parameters:
    ///   - items: (id, PHAsset) 列表（快照，避免后续数组变化干扰）
    ///   - completion: 每张加载完成后的主线程回调
    func loadBatched(items: [(id: String, phAsset: PHAsset)],
                     completion: @escaping (String, NSImage) -> Void) {
        for (i, start) in stride(from: 0, to: items.count, by: Layout.previewBatchSize).enumerated() {
            let batch = Array(items[start..<min(start + Layout.previewBatchSize, items.count)])
            queue.asyncAfter(deadline: .now() + Double(i) * Layout.previewBatchDelay) { [weak self] in
                guard let self else { return }
                for item in batch {
                    self.loadOne(id: item.id, phAsset: item.phAsset, completion: { img in
                        completion(item.id, img)
                    })
                }
            }
        }
    }

    // MARK: - Private

    private func loadOne(id: String, phAsset: PHAsset, completion: @escaping (NSImage) -> Void) {
        let uuid = id.components(separatedBy: "/").first ?? id
        let firstChar = String(uuid.prefix(1)).uppercased()
        if let base = PhotoLibrary.derivativesBase,
           let image = NSImage(contentsOfFile: "\(base)/\(firstChar)/\(uuid)_1_105_c.jpeg") {
            let normalized = normalizeForSwiftUI(image)
            DispatchQueue.main.async { completion(normalized) }
            return
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        PHImageManager.default().requestImage(
            for: phAsset, targetSize: Layout.previewSize,
            contentMode: .aspectFit, options: opts
        ) { image, _ in
            guard let image else { return }
            let normalized = normalizeForSwiftUI(image)
            DispatchQueue.main.async { completion(normalized) }
        }
    }
}
