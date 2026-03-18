import AppKit
import CoreGraphics

actor PreviewCache {
    private var cache: [CGWindowID: (image: NSImage, timestamp: Date)] = [:]
    private let maxSize = 50
    var expiryInterval: TimeInterval = 5.0  // BUG-017: 可由外部配置

    func get(_ windowID: CGWindowID) -> NSImage? {
        guard let entry = cache[windowID] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) < expiryInterval else {
            cache.removeValue(forKey: windowID)
            return nil
        }
        return entry.image
    }

    func set(_ image: NSImage, for windowID: CGWindowID) {
        if cache.count >= maxSize { evictOldest() }
        cache[windowID] = (image, Date())
    }

    func clear() { cache.removeAll() }

    func setExpiry(_ interval: TimeInterval) { expiryInterval = interval }

    private func evictOldest() {
        if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
            cache.removeValue(forKey: oldest.key)
        }
    }
}

class PreviewGenerator {
    private let cache = PreviewCache()
    private let queue = DispatchQueue(label: "com.windowsswitcher.preview", qos: .userInitiated)

    init() {
        // BUG-017: 将缓存过期时间与配置中的 previewUpdateInterval 对齐
        let interval = ConfigManager.shared.config.behavior.previewUpdateInterval
        Task { await cache.setExpiry(interval > 0 ? interval * 10 : 5.0) }
    }

    func generatePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        if let cached = await cache.get(window.id) { return cached }

        return await withCheckedContinuation { continuation in
            queue.async {
                let image = self.captureWindow(window.id, size: size)
                // BUG-008: 先 resume，再异步写缓存，确保 continuation 在所有路径都被调用
                continuation.resume(returning: image)
                if let image {
                    Task { await self.cache.set(image, for: window.id) }
                }
            }
        }
    }

    func clearCache() async { await cache.clear() }

    private func captureWindow(_ windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let image = NSImage(cgImage: cgImage, size: size)
        return image
    }
}
