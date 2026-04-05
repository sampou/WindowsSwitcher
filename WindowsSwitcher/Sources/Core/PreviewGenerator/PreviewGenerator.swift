import AppKit
import CoreGraphics

actor PreviewCache {
    // MARK: - 内存缓存
    private var memoryCache: [String: CachedEntry] = [:]
    private let maxMemorySize = 50
    
    // MARK: - 磁盘缓存
    private let cacheDirectory: URL
    private let maxDiskCacheSize: Int64 = 100 * 1024 * 1024  // 100MB
    
    // MARK: - 配置
    var expiryInterval: TimeInterval = 300  // 5分钟缓存有效期
    
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

class PreviewGenerator {
    private let cache = PreviewCache()
    private let queue = DispatchQueue(label: "com.windowsswitcher.preview", qos: .userInitiated)

    init() {
        // BUG-017: 将缓存过期时间与配置中的 previewUpdateInterval 对齐
        let interval = ConfigManager.shared.config.behavior.previewUpdateInterval
        Task { await cache.setExpiry(interval > 0 ? interval * 10 : 5.0) }
    }

    func generatePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 计算窗口内容哈希
        let windowHash = await cache.computeWindowHash(for: window)

        // 检查缓存（包括内存和磁盘）
        if let cached = await cache.get(for: window.id, windowHash: windowHash) {
            Logger.info("==> PreviewGenerator: cache HIT for \(window.appName), time: \((CFAbsoluteTimeGetCurrent() - startTime)*1000)ms")
            return cached
        }

        Logger.info("==> PreviewGenerator: cache MISS for \(window.appName), generating...")

        return await withCheckedContinuation { continuation in
            queue.async {
                let t0 = CFAbsoluteTimeGetCurrent()
                let image = self.captureWindow(window.id, size: size)
                Logger.info("==> PreviewGenerator: captureWindow took \((CFAbsoluteTimeGetCurrent() - t0)*1000)ms for \(window.appName)")
                // BUG-008: 先 resume，再异步写缓存，确保 continuation 在所有路径都被调用
                continuation.resume(returning: image)
                if let image {
                    Task { await self.cache.set(image, for: window.id, windowHash: windowHash) }
                }
                Logger.info("==> PreviewGenerator: TOTAL time: \((CFAbsoluteTimeGetCurrent() - startTime)*1000)ms for \(window.appName)")
            }
        }
    }

    func clearCache() async { await cache.clear() }

    private func captureWindow(_ windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        // 直接返回原始图片，不缩放
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
