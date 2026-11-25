import XCTest
import AppKit
import SwiftUI
@testable import WindowsSwitcher

// MARK: - Dock 缩略图渲染几何取证测试
///
/// 复现"部分窗口缩略图很小"问题的运行时证据：
/// 用与 PreviewGenerator.captureWindowSync + resizeCGImage 完全一致的画布语义构造截图
/// （16:9 画布、内容按窗口宽高比 aspect-fit 居中、其余透明），
/// 渲染真实的 DockPreviewItemView，再分析红色内容像素的实际包围盒。
///
/// 预期（修复后）：所有宽高比下红色内容都铺满 previewWidth×previewHeight 预览框。
/// 若实际包围盒更小，说明绘制区又被按窗口比例收缩。
@MainActor
final class DockThumbnailGeometryTests: XCTestCase {

    private let previewW: CGFloat = 114
    private let previewH: CGFloat = 64

    private struct RenderResult {
        let redBBox: CGRect       // 红色内容像素包围盒（视图坐标）
        let opaqueBBox: CGRect    // 全部非透明像素包围盒（画布可见范围）
    }

    /// 复刻 resizeCGImage：targetSize 逻辑尺寸、2x 像素画布、内容 aspect-fit 居中、其余透明。
    /// 内容用纯红填充以便像素分析。
    private func makeCapturedImage(windowAspect: CGFloat) -> NSImage {
        let targetW = Int(previewW)
        let targetH = Int(previewH)
        let canvasW = targetW * 2
        let canvasH = targetH * 2

        let srcW = CGFloat(canvasH) * windowAspect  // 内容像素尺寸（任意，保持宽高比即可）
        let srcH = CGFloat(canvasH)
        let scale = min(CGFloat(canvasW) / srcW, CGFloat(canvasH) / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = (CGFloat(canvasW) - drawW) / 2
        let drawY = (CGFloat(canvasH) - drawH) / 2

        let context = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        let cgImage = context.makeImage()!
        return NSImage(cgImage: cgImage, size: NSSize(width: targetW, height: targetH))
    }

    private func makeWindowModel(frame: CGRect, id: CGWindowID) -> WindowModel {
        WindowModel(
            id: id,
            appName: "TestApp",
            bundleIdentifier: "com.test.app",
            windowTitle: "窗口\(id)",
            appIcon: NSImage(size: NSSize(width: 16, height: 16)),
            frame: frame,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: getpid(),
            isStandardWindow: true
        )
    }

    /// 渲染 DockPreviewItemView 并做像素包围盒分析。
    private func renderAndAnalyze(windowAspect: CGFloat) -> RenderResult {
        ConfigManager.shared.reset()

        let windowH: CGFloat = 800
        let window = makeWindowModel(
            frame: CGRect(x: 0, y: 0, width: windowH * windowAspect, height: windowH),
            id: CGWindowID(1000 + Int(windowAspect * 100))
        )
        let item = DockPreviewItem(windowModel: window)
        let captured = makeCapturedImage(windowAspect: windowAspect)

        let view = DockPreviewItemView(
            item: item,
            isHovered: false,
            previewWidth: previewW,
            previewHeight: previewH,
            itemWidth: 130,
            itemHeight: 110,
            cachedImage: captured,
            onTap: {},
            onHover: { _ in }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("无法创建位图")
            return RenderResult(redBBox: .null, opaqueBBox: .null)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let pixels = rep.bitmapData else {
            XCTFail("无位图数据")
            return RenderResult(redBBox: .null, opaqueBBox: .null)
        }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel

        var redMinX = Int.max, redMaxX = -1, redMinY = Int.max, redMaxY = -1
        var opaqueMinX = Int.max, opaqueMaxX = -1, opaqueMinY = Int.max, opaqueMaxY = -1

        for y in 0..<h {
            let row = pixels + y * bpr
            for x in 0..<w {
                let p = row + x * spp
                let r = p[0], g = p[1], b = p[2]
                let a: UInt8 = spp >= 4 ? p[3] : 255
                if a > 16 {
                    opaqueMinX = min(opaqueMinX, x); opaqueMaxX = max(opaqueMaxX, x)
                    opaqueMinY = min(opaqueMinY, y); opaqueMaxY = max(opaqueMaxY, y)
                }
                if a > 16 && r > 180 && g < 80 && b < 80 {
                    redMinX = min(redMinX, x); redMaxX = max(redMaxX, x)
                    redMinY = min(redMinY, y); redMaxY = max(redMaxY, y)
                }
            }
        }

        guard redMaxX >= 0 else {
            XCTFail("未找到红色内容像素，aspect=\(windowAspect)")
            return RenderResult(redBBox: .null, opaqueBBox: .null)
        }

        let scaleX = CGFloat(rep.pixelsWide) / hosting.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / hosting.bounds.height
        let redBBox = CGRect(
            x: CGFloat(redMinX) / scaleX, y: CGFloat(redMinY) / scaleY,
            width: CGFloat(redMaxX - redMinX + 1) / scaleX,
            height: CGFloat(redMaxY - redMinY + 1) / scaleY
        )
        let opaqueBBox = CGRect(
            x: CGFloat(opaqueMinX) / scaleX, y: CGFloat(opaqueMinY) / scaleY,
            width: CGFloat(opaqueMaxX - opaqueMinX + 1) / scaleX,
            height: CGFloat(opaqueMaxY - opaqueMinY + 1) / scaleY
        )
        return RenderResult(redBBox: redBBox, opaqueBBox: opaqueBBox)
    }

    private func expectedContentSize(windowAspect: CGFloat) -> CGSize {
        // 修复后：缩略图铺满整个预览框，.fill 的溢出裁切恰好去除画布透明边
        CGSize(width: previewW, height: previewH)
    }

    private func assertRender(windowAspect: CGFloat, tolerance: CGFloat = 3.0,
                              file: StaticString = #filePath, line: UInt = #line) {
        let result = renderAndAnalyze(windowAspect: windowAspect)
        let expected = expectedContentSize(windowAspect: windowAspect)
        print("[geometry] aspect=\(windowAspect) 红色内容 bbox=\(result.redBBox.size) 期望=\(expected) " +
              "opaqueBBox=\(result.opaqueBBox.size)")
        XCTAssertEqual(result.redBBox.width, expected.width, accuracy: tolerance,
                       "内容宽度不符 aspect=\(windowAspect)", file: file, line: line)
        XCTAssertEqual(result.redBBox.height, expected.height, accuracy: tolerance,
                       "内容高度不符 aspect=\(windowAspect)", file: file, line: line)
    }

    // 16:9 标准窗口：应占满整个卡片预览区
    func testThumbnailFillsCardFor16x9() {
        assertRender(windowAspect: 16.0 / 9.0)
    }

    // 典型满屏窗口（1728×1000）
    func testThumbnailFillsCardForMaximized() {
        assertRender(windowAspect: 1.73)
    }

    // iTerm2 实测尺寸（741×497）
    func testThumbnailForTerminalWindow() {
        assertRender(windowAspect: 1.49)
    }

    // 4:3 窗口
    func testThumbnailFor43Window() {
        assertRender(windowAspect: 4.0 / 3.0)
    }

    // 竖长窗口
    func testThumbnailForPortraitWindow() {
        assertRender(windowAspect: 0.8)
    }
}
