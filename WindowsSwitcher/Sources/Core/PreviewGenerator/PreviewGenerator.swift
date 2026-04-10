import AppKit
import CoreGraphics

actor PreviewCache {
    // MARK: - 内存缓存
    private var memoryCache: [String: CachedEntry] = [:]
    private let maxMemorySize = 80  // 增加内存缓存数量

    // MARK: - 磁盘缓存
    private let cacheDirectory: URL
    private let maxDiskCacheSize: Int64 = 200 * 1024 * 1024  // 200MB

    // MARK: - 配置 - 使用长时间缓存，基于内容哈希判断是否更新
    var expiryInterval: TimeInterval = 600  // 10分钟缓存有效期

    // MARK: - 初始化
    init() {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("WindowsSwitcher/Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - 缓存条目
    struct CachedEntry {
        let image: NSImage
        let windowHash: String  // 窗口内容哈希，用于检测变化
        let timestamp: Date
        let windowID: CGWindowID
    }
    
    // MARK: - 公共方法
    
    /// 获取缓存的预览图（检查内容哈希是否匹配）
    func get(for windowID: CGWindowID, windowHash: String) -> NSImage? {
        let key = cacheKey(windowID: windowID, windowHash: windowHash)
        
        // 1. 检查内存缓存
        if let entry = memoryCache[key] {
            if Date().timeIntervalSince(entry.timestamp) < expiryInterval {
                return entry.image
            } else {
                memoryCache.removeValue(forKey: key)
            }
        }
        
        // 2. 检查磁盘缓存
        if let image = loadFromDisk(key: key) {
            // 存入内存缓存
            let entry = CachedEntry(image: image, windowHash: windowHash, timestamp: Date(), windowID: windowID)
            memoryCache[key] = entry
            limitMemoryCacheSize()
            return image
        }
        
        return nil
    }
    
    /// 设置缓存
    func set(_ image: NSImage, for windowID: CGWindowID, windowHash: String) {
        let key = cacheKey(windowID: windowID, windowHash: windowHash)
        
        // 存入内存缓存
        let entry = CachedEntry(image: image, windowHash: windowHash, timestamp: Date(), windowID: windowID)
        memoryCache[key] = entry
        limitMemoryCacheSize()
        
        // 异步存入磁盘
        Task {
            await saveToDisk(image: image, key: key)
        }
    }
    
    /// 计算窗口内容哈希（用于检测窗口是否变化）
    func computeWindowHash(for window: WindowModel) -> String {
        // 基于窗口的关键属性计算哈希
        let hashInput = "\(window.id)_\(window.frame)_\(window.windowTitle)_\(window.isMinimized)_\(window.isHidden)"
        return String(hashInput.hash)
    }
    
    /// 清空所有缓存
    func clear() {
        memoryCache.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func setExpiry(_ interval: TimeInterval) {
        expiryInterval = interval
    }
    
    // MARK: - 私有方法
    
    private func cacheKey(windowID: CGWindowID, windowHash: String) -> String {
        return "\(windowID)_\(windowHash)"
    }
    
    private func limitMemoryCacheSize() {
        while memoryCache.count > maxMemorySize {
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
        
        // 清理过期磁盘缓存
        await cleanDiskCacheIfNeeded()
    }
    
    private func loadFromDisk(key: String) -> NSImage? {
        let fileURL = cacheDirectory.appendingPathComponent("\(key).png")
        
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            return nil
        }
        
        return image
    }
    
    private func cleanDiskCacheIfNeeded() async {
        // 获取磁盘缓存总大小
        let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
        
        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, size: Int64, date: Date)] = []
        
        for file in files ?? [] {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) {
                let size = (attributes[.size] as? Int64) ?? 0
                let date = (attributes[.modificationDate] as? Date) ?? Date.distantPast
                totalSize += size
                fileInfos.append((url: file, size: size, date: date))
            }
        }
        
        // 如果超过最大大小，删除最旧的文件
        if totalSize > maxDiskCacheSize {
            let sortedFiles = fileInfos.sorted { $0.date < $1.date }
            var sizeToFree = totalSize - maxDiskCacheSize + 10 * 1024 * 1024  // 多清理10MB
            
            for file in sortedFiles {
                if sizeToFree <= 0 { break }
                try? FileManager.default.removeItem(at: file.url)
                sizeToFree -= file.size
            }
        }
    }
}

final class PreviewGenerator: @unchecked Sendable {
    private let cache = PreviewCache()
    // 使用并发队列，支持多线程并行生成缩略图
    private let queue = DispatchQueue(label: "com.windowsswitcher.preview", qos: .userInitiated, attributes: .concurrent)
    // 信号量限制并发生成数量
    private let semaphore = DispatchSemaphore(value: 3)

    init() {
        // 使用固定的长时间缓存（10分钟），只有在窗口内容变化时才更新
        // 缓存过期不影响正常使用，因为我们会根据内容哈希判断是否需要重新生成
        Task { await cache.setExpiry(600) }
    }

    /// 生成单个窗口预览
    func generatePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        // 检查缓存（包括内存和磁盘）
        if let cached = await cache.get(for: window.id, windowHash: await cache.computeWindowHash(for: window)) {
            return cached
        }

        let windowID = window.id
        let windowHash = await cache.computeWindowHash(for: window)
        let cacheRef = self.cache
        let semaphoreRef = self.semaphore
        let queueRef = self.queue

        return await withCheckedContinuation { continuation in
            queueRef.async {
                // 限制并发数量
                semaphoreRef.wait()
                defer { semaphoreRef.signal() }

                let image = Self.captureWindowSync(windowID, size: size)
                continuation.resume(returning: image)

                if let image {
                    Task {
                        await cacheRef.set(image, for: windowID, windowHash: windowHash)
                    }
                }
            }
        }
    }

    /// 批量生成预览（用于面板打开时）
    func generatePreviews(for windows: [WindowModel], size: CGSize) async -> [CGWindowID: NSImage] {
        var results: [CGWindowID: NSImage] = [:]

        // 使用简单的顺序处理避免 Sendable 问题
        for window in windows {
            if let image = await generatePreview(for: window, size: size) {
                results[window.id] = image
            }
        }

        return results
    }

    func clearCache() async { await cache.clear() }

    /// 捕获窗口截图 - 优化分辨率（静态方法，可在任意线程调用）
    private static func captureWindowSync(_ windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        // 使用 bestResolution 获取高质量截图，然后缩放到目标尺寸
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        // 缩放到目标尺寸
        let targetSize = NSSize(width: size.width, height: size.height)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // 缩放图片
        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: targetSize),
                    from: NSRect(origin: .zero, size: nsImage.size),
                    operation: .copy,
                    fraction: 1.0)
        resizedImage.unlockFocus()

        return resizedImage
    }
}
