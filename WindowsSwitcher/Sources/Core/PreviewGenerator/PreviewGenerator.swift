import AppKit
import CoreGraphics

/// 窗口生命周期事件所需的预览缓存失效能力。
///
/// 将销毁事件协调逻辑与具体截图实现解耦，便于通过确定性测试验证缓存清理调用。
protocol PreviewCacheInvalidating: Sendable {
    func invalidateCache(for windowID: CGWindowID) async
}

// MARK: - 预览缓存配置
struct PreviewCacheConfig {
    /// 内存缓存最大数量
    static let maxMemorySize = 100
    /// 磁盘缓存最大大小（字节）
    static let maxDiskCacheSize: Int64 = 200 * 1024 * 1024  // 200MB
    /// 后台刷新间隔（秒）：超过此时间认为缓存"陈旧"，后台需重新截图
    /// 注意：缓存不会被此 TTL 丢弃，仅用于判断是否需要后台刷新
    static let refreshInterval: TimeInterval = 5.0  // 5秒后认为陈旧，后台刷新
    /// 磁盘缓存有效期（秒）：磁盘文件超过此时间视为过期，清理并重新生成
    static let diskCacheExpiry: TimeInterval = 30.0  // 30秒
    /// 最大并发生成数
    static let maxConcurrentGeneration = 4
}

// MARK: - 预览缓存
actor PreviewCache {
    private var memoryCache: [String: CachedEntry] = [:]
    private let cacheDirectory: URL
    private let persistsToDisk: Bool

    struct CachedEntry {
        let image: NSImage
        let timestamp: Date
        let windowID: CGWindowID
    }

    /// 创建预览缓存。生产环境默认启用磁盘缓存；只验证内存语义的测试可显式关闭，
    /// 避免合成 NSImage 触发 AppKit 编码并污染同一测试进程。
    init(persistsToDisk: Bool = true) {
        self.persistsToDisk = persistsToDisk
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDirectory.appendingPathComponent("WindowsSwitcher/Previews", isDirectory: true)
        if persistsToDisk {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// 获取缓存的预览图（长期保留，不因 TTL 丢弃，用于即时显示）
    /// 返回内存或磁盘中的缓存图，无论新旧。是否需要后台刷新由 isStale 判断
    func get(for windowID: CGWindowID) -> NSImage? {
        let key = "\(windowID)"

        if let entry = memoryCache[key] {
            return entry.image
        }

        // 尝试从磁盘加载（永久保留，仅磁盘过期才清理）
        if persistsToDisk, let image = loadFromDisk(key: key) {
            let entry = CachedEntry(image: image, timestamp: Date(), windowID: windowID)
            memoryCache[key] = entry
            return image
        }

        return nil
    }

    /// 判断指定窗口的缓存是否陈旧（需要后台重新截图）
    /// 缓存不存在或超过 refreshInterval 即视为陈旧
    func isStale(for windowID: CGWindowID) -> Bool {
        let key = "\(windowID)"
        if let entry = memoryCache[key] {
            return Date().timeIntervalSince(entry.timestamp) >= PreviewCacheConfig.refreshInterval
        }
        return true
    }

    /// 设置缓存
    func set(_ image: NSImage, for windowID: CGWindowID) {
        let key = "\(windowID)"
        let entry = CachedEntry(image: image, timestamp: Date(), windowID: windowID)
        memoryCache[key] = entry
        limitMemoryCacheSize()

        // 调用方已通过 actor 的异步边界进入此处，直接完成磁盘持久化，避免为每次写入
        // 再创建无法等待的后台任务。预览生成路径会在返回图片后另起任务调用 set，
        // 因此这里不会延迟首屏展示，同时可防止测试或高频刷新后遗留大量编码任务。
        if persistsToDisk {
            saveToDisk(image: image, key: key)
        }
    }

    /// 使指定窗口的缓存失效
    func invalidate(for windowID: CGWindowID) {
        let key = "\(windowID)"
        memoryCache.removeValue(forKey: key)
        // 同步清理磁盘缓存文件
        if persistsToDisk {
            let fileURL = cacheDirectory.appendingPathComponent("\(key).png")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// 清空所有缓存
    func clear() {
        memoryCache.removeAll()
        guard persistsToDisk else { return }
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// 清理磁盘缓存中过期或超额的文件（控制磁盘占用）
    func cleanupDiskCacheIfNeeded() {
        guard persistsToDisk else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles]) else { return }

        let expiry = PreviewCacheConfig.diskCacheExpiry
        let now = Date()
        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, date: Date, size: Int64)] = []

        for file in files where file.pathExtension == "png" {
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? Int64) ?? 0
            totalSize += size
            // 删除已过期的缓存文件
            if now.timeIntervalSince(date) > expiry {
                try? fm.removeItem(at: file)
                totalSize -= size
            } else {
                fileInfos.append((file, date, size))
            }
        }

        // 若仍超过磁盘配额，按最旧优先删除
        if totalSize > PreviewCacheConfig.maxDiskCacheSize {
            fileInfos.sort { $0.date < $1.date }
            for info in fileInfos {
                if totalSize <= PreviewCacheConfig.maxDiskCacheSize { break }
                try? fm.removeItem(at: info.url)
                totalSize -= info.size
            }
        }
    }

    private func limitMemoryCacheSize() {
        while memoryCache.count > PreviewCacheConfig.maxMemorySize {
            if let oldest = memoryCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                memoryCache.removeValue(forKey: oldest)
            }
        }
    }

    private func saveToDisk(image: NSImage, key: String) {
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
        // 磁盘文件超过 diskCacheExpiry 才视为过期清理（长期保留，支持跨启动复用）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > PreviewCacheConfig.diskCacheExpiry {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL) else {
            return nil
        }
        return image
    }
}

// MARK: - 预览生成器
final class PreviewGenerator: PreviewCacheInvalidating, @unchecked Sendable {
    private let cache = PreviewCache()
    /// 所有生成器共享同一限并发队列，避免多个面板各自创建并发配额。
    /// OperationQueue 只调度可执行任务，不会像“并发队列 + semaphore.wait()”那样
    /// 用等待中的截图任务耗尽 Dispatch 工作线程。
    private static let generationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.windowsswitcher.preview"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = PreviewCacheConfig.maxConcurrentGeneration
        return queue
    }()
    private var diskCleanupTimer: DispatchSourceTimer?

    init() {
        // 启动时清理一次磁盘缓存（控制磁盘占用，删除过期文件）
        Task(priority: .background) { [cache] in
            await cache.cleanupDiskCacheIfNeeded()
        }
        // 每小时定期清理一次磁盘缓存，防止长期运行累积
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [cache] in
            Task(priority: .background) {
                await cache.cleanupDiskCacheIfNeeded()
            }
        }
        timer.resume()
        diskCleanupTimer = timer
    }

    deinit {
        diskCleanupTimer?.cancel()
    }

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
            Self.generationQueue.addOperation {
                let image = Self.captureWindowSync(windowID, size: size)
                continuation.resume(returning: image)

                if let image = image {
                    Task {
                        await cacheRef.set(image, for: windowID)
                    }
                    // 同步更新内存缓存镜像（供主线程同步快速读取）
                    self.updateSyncCache(windowID: windowID, image: image)
                }
            }
        }
    }

    /// 生成实时预览（强制刷新缓存）
    func generateRealtimePreview(for window: WindowModel, size: CGSize) async -> NSImage? {
        let windowID = window.id
        let cacheRef = self.cache

        return await withCheckedContinuation { continuation in
            Self.generationQueue.addOperation {
                let image = Self.captureWindowSync(windowID, size: size)
                continuation.resume(returning: image)

                // 更新缓存，确保下次使用最新内容
                if let image = image {
                    Task {
                        await cacheRef.set(image, for: windowID)
                    }
                    // 同步更新内存缓存镜像
                    self.updateSyncCache(windowID: windowID, image: image)
                }
            }
        }
    }

    /// 仅从缓存获取预览图（不触发生成），用于面板唤起时快速填充
    /// 返回 nil 表示缓存未命中，需要后续异步生成
    func getCachedPreview(for windowID: CGWindowID) async -> NSImage? {
        return await cache.get(for: windowID)
    }

    /// 同步从内存缓存获取预览图（不触发生成，不读磁盘）
    /// 用于面板唤起时瞬时填充，避免空白
    func getCachedPreviewSync(for windowID: CGWindowID) -> NSImage? {
        syncCacheLock.lock()
        defer { syncCacheLock.unlock() }
        return syncMemoryCache[windowID]
    }

    /// 内存缓存镜像（供主线程同步快速读取，避免 actor 异步开销）
    private var syncMemoryCache: [CGWindowID: NSImage] = [:]
    private let syncCacheLock = NSLock()

    /// 更新内存缓存镜像（线程安全）
    private func updateSyncCache(windowID: CGWindowID, image: NSImage) {
        syncCacheLock.lock()
        syncMemoryCache[windowID] = image
        // 限制镜像大小，与 memoryCache 一致
        if syncMemoryCache.count > PreviewCacheConfig.maxMemorySize {
            // 简单丢弃一部分（按 key 任意），避免无限增长
            if let firstKey = syncMemoryCache.keys.first {
                syncMemoryCache.removeValue(forKey: firstKey)
            }
        }
        syncCacheLock.unlock()
    }

    /// 移除同步镜像缓存中的单个条目
    private func removeSyncCache(windowID: CGWindowID) {
        syncCacheLock.lock()
        syncMemoryCache.removeValue(forKey: windowID)
        syncCacheLock.unlock()
    }

    /// 清空同步镜像缓存
    private func clearSyncCache() {
        syncCacheLock.lock()
        syncMemoryCache.removeAll()
        syncCacheLock.unlock()
    }

    /// 批量预取预览到缓存（不返回结果，仅用于后台预热缓存）
    /// 只刷新陈旧的缓存（isStale），避免对新鲜缓存重复截图
    /// 面板可见时不应调用（面板有自己的加载逻辑）
    func prefetchPreviews(for windows: [WindowModel], size: CGSize) async {
        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                // 只对陈旧的缓存重新截图，新鲜的跳过
                guard await cache.isStale(for: window.id) else { continue }
                group.addTask { [self] in
                    _ = await self.generatePreview(for: window, size: size)
                }
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
            Self.generationQueue.addOperation {
                let image = Self.captureWindowFullResolution(windowID, windowFrame: windowFrame)
                continuation.resume(returning: image)
            }
        }
    }

    /// 使缓存失效
    func invalidateCache(for windowID: CGWindowID) async {
        await cache.invalidate(for: windowID)
        removeSyncCache(windowID: windowID)
    }

    func clearCache() async {
        await cache.clear()
        clearSyncCache()
    }

    // MARK: - 私有方法

    private static func captureWindowSync(_ windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard windowExists(windowID) else { return nil }
        guard CGPreflightScreenCaptureAccess() else { return nil }

        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else { return nil }

        let targetSize = NSSize(width: size.width, height: size.height)
        return resizeCGImage(cgImage, to: targetSize)
    }

    private static func captureWindowFullResolution(_ windowID: CGWindowID, windowFrame: CGRect) -> NSImage? {
        guard windowExists(windowID) else { return nil }
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

    /// 在调用系统截图 API 前确认窗口仍存在，避免已关闭窗口或测试伪 ID
    /// 进入 ScreenCaptureKit 的同步等待路径。
    private static func windowExists(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]] else {
            return false
        }

        return windows.contains { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                return false
            }
            return number.uint32Value == windowID
        }
    }

    /// 使用 CGContext 高性能缩放 CGImage，保持源图宽高比（aspect fit），比 lockFocus + draw 快得多
    /// 窄窗口（如 iPhone 镜像）不会被横向拉伸，在 targetSize 内居中适配，多余区域透明
    private static func resizeCGImage(_ cgImage: CGImage, to targetSize: NSSize) -> NSImage? {
        let canvasWidth = Int(targetSize.width * 2)  // Retina 2x
        let canvasHeight = Int(targetSize.height * 2)
        guard canvasWidth > 0 && canvasHeight > 0 else { return nil }

        // 按源图宽高比计算实际绘制尺寸（aspect fit 进 targetSize）
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0 && srcH > 0 else { return nil }
        let scale = min(CGFloat(canvasWidth) / srcW, CGFloat(canvasHeight) / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = (CGFloat(canvasWidth) - drawW) / 2
        let drawY = (CGFloat(canvasHeight) - drawH) / 2

        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        guard let resizedCGImage = context.makeImage() else { return nil }
        // NSImage size 用 targetSize，但像素保持窗口真实比例，渲染时不再变形
        return NSImage(cgImage: resizedCGImage, size: targetSize)
    }
}
