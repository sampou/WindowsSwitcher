import AppKit
import CoreGraphics

// MARK: - 预览缓存配置
struct PreviewCacheConfig {
    /// 内存缓存最大数量
    static let maxMemorySize = 100
    /// 磁盘缓存最大大小（字节）
    static let maxDiskCacheSize: Int64 = 200 * 1024 * 1024  // 200MB
    /// 缓存有效期（秒）- 短缓存确保实时性
    static let cacheExpiry: TimeInterval = 0.5  // 500ms
    /// 最大并发生成数
    static let maxConcurrentGeneration = 4
}

// MARK: - 预览缓存
actor PreviewCache {
    private var memoryCache: [String: CachedEntry] = [:]
    private let cacheDirectory: URL

    struct CachedEntry {
        let image: NSImage
        let timestamp: Date
        let windowID: CGWindowID
    }

    init() {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("WindowsSwitcher/Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// 获取缓存的预览图
    func get(for windowID: CGWindowID) -> NSImage? {
        let key = "\(windowID)"

        if let entry = memoryCache[key] {
            let age = Date().timeIntervalSince(entry.timestamp)
            if age < PreviewCacheConfig.cacheExpiry {
                return entry.image
            }
        }

        // 尝试从磁盘加载
        if let image = loadFromDisk(key: key) {
            let entry = CachedEntry(image: image, timestamp: Date(), windowID: windowID)
            memoryCache[key] = entry
            return image
        }

        return nil
    }

    /// 设置缓存
    func set(_ image: NSImage, for windowID: CGWindowID) {
        let key = "\(windowID)"
        let entry = CachedEntry(image: image, timestamp: Date(), windowID: windowID)
        memoryCache[key] = entry
        limitMemoryCacheSize()

        // 异步存入磁盘
        Task(priority: .background) {
            await saveToDisk(image: image, key: key)
        }
    }

    /// 使指定窗口的缓存失效
    func invalidate(for windowID: CGWindowID) {
        let key = "\(windowID)"
        memoryCache.removeValue(forKey: key)
    }

    /// 清空所有缓存
    func clear() {
        memoryCache.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func limitMemoryCacheSize() {
        while memoryCache.count > PreviewCacheConfig.maxMemorySize {
            if let oldest = memoryCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                memoryCache.removeValue(forKey: oldest)
            }
        }
    }

    private func saveToDisk(image: NSImage, key: String) async {
        let fileURL = cacheDirectory.appendingPathComponent("\(key).png")

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        try? pngData.write(to: fileURL)
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(key).png")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            return nil
        }
        return image
    }
}

// MARK: - 预览生成器
final class PreviewGenerator: @unchecked Sendable {
    private let cache = PreviewCache()
    private let queue = DispatchQueue(
        label: "com.windowsswitcher.preview",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let semaphore = DispatchSemaphore(value: PreviewCacheConfig.maxConcurrentGeneration)

    /// 生成单个窗口预览（带缓存）
    func generatePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        // 检查缓存
        if let cached = await cache.get(for: window.id) {
            return cached
        }

        // 生成新预览
        let windowID = window.id
        let cacheRef = self.cache

        return await withCheckedContinuation { continuation in
            queue.async {
                self.semaphore.wait()
                defer { self.semaphore.signal() }

                let image = Self.captureWindowSync(windowID, size: size)
                continuation.resume(returning: image)

                if let image = image {
                    Task {
                        await cacheRef.set(image, for: windowID)
                    }
                }
            }
        }
    }

    /// 生成实时预览（强制刷新缓存）
    func generateRealtimePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        let windowID = window.id

        return await withCheckedContinuation { continuation in
            queue.async {
                self.semaphore.wait()
                defer { self.semaphore.signal() }

                let image = Self.captureWindowSync(windowID, size: size)
                continuation.resume(returning: image)
            }
        }
    }

    /// 批量生成预览
    func generatePreviews(for windows: [WindowModel], size: CGSize) async -> [CGWindowID: NSImage] {
        var results: [CGWindowID: NSImage] = [:]

        for window in windows {
            if let image = await generatePreview(for: window, size: size) {
                results[window.id] = image
            }
        }

        return results
    }

    /// 生成原始分辨率预览
    func generateFullResolutionPreview(for window: WindowModel) async -> NSImage? {
        let windowID = window.id
        let windowFrame = window.frame

        return await withCheckedContinuation { continuation in
            queue.async {
                let image = Self.captureWindowFullResolution(windowID, windowFrame: windowFrame)
                continuation.resume(returning: image)
            }
        }
    }

    /// 使缓存失效
    func invalidateCache(for windowID: CGWindowID) async {
        await cache.invalidate(for: windowID)
    }

    func clearCache() async {
        await cache.clear()
    }

    // MARK: - 私有方法

    private static func captureWindowSync(_ windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let targetSize = NSSize(width: size.width, height: size.height)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // 高质量缩放
        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        nsImage.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: nsImage.size),
            operation: .copy,
            fraction: 1.0
        )
        resizedImage.unlockFocus()

        return resizedImage
    }

    private static func captureWindowFullResolution(_ windowID: CGWindowID, windowFrame: CGRect) -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let logicalSize = NSSize(width: windowFrame.width, height: windowFrame.height)
        return NSImage(cgImage: cgImage, size: logicalSize)
    }
}
