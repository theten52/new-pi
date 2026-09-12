import AppKit
import ImageIO
import UniformTypeIdentifiers

// 使用测试路径解析替身，只允许本探针临时目录；控制器/SwiftUI预览内容使用生产源码。
enum SessionAttachments {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static func resolve(relativePath: String) -> URL? {
        guard !relativePath.contains("/"), !relativePath.contains("..") else { return nil }
        return directory.appendingPathComponent(relativePath)
    }
}

@main @MainActor struct AttachmentPreviewChecks {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
    static func makeImage(width: Int, height: Int, dpiHeight: Int, type: UTType, orientation: Int) throws -> URL {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData else { throw Failure(message: "无位图") }
        // 纯红测试图，后续按真实渲染像素测矩形，而不只验证公式。
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = 240; bytes[offset + 1] = 20; bytes[offset + 2] = 20; bytes[offset + 3] = 255
        } }
        let url = SessionAttachments.directory.appendingPathComponent(UUID().uuidString + "." + (type.preferredFilenameExtension ?? "image"))
        guard let pixels = bitmap.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw Failure(message: "编码失败") }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: dpiHeight
        ]
        // 0 表示字段缺省；ImageIO thumbnail transform 对缺省和显式 1 行为不同。
        if orientation != 0 { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "编码失败") }
        return url
    }
    static func redBounds(_ view: NSView) throws -> CGRect {
        view.layoutSubtreeIfNeeded()
        // SwiftUI 的合成图层不一定进入 cacheDisplay；仅截取本探针自己的图片窗口。
        guard let window = view.window else { throw Failure(message: "无窗口") }
        let capture = SessionAttachments.directory.appendingPathComponent("capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), capture.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture)) else { throw Failure(message: "无法截取测试窗口，请检查录屏权限") }
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.redComponent > 0.6, color.redComponent > color.greenComponent * 2,
                  color.redComponent > color.blueComponent * 2 else { continue }
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else {
            if let path = ProcessInfo.processInfo.environment["NEWPI_PREVIEW_CAPTURE"] {
                try Data(contentsOf: capture).write(to: URL(fileURLWithPath: path))
            }
            throw Failure(message: "未检测到图片像素；view=\(view.frame)，capture=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if CommandLine.arguments.count == 3 {
                    try await inspectImage(at: URL(fileURLWithPath: CommandLine.arguments[1]),
                        capture: URL(fileURLWithPath: CommandLine.arguments[2]))
                } else {
                    try await run()
                }
                exit(0)
            }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL: preview timeout"); exit(1) }
        NSApp.run()
    }
    // 仅显式传入单张图片时启用的本机人工验收，不作为合成回归 PASS 的替代。
    static func inspectImage(at source: URL, capture: URL) async throws {
        guard source.standardizedFileURL != capture.standardizedFileURL else { throw Failure(message: "截图不能覆盖原图") }
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: SessionAttachments.directory, withIntermediateDirectories: true)
        defer { AttachmentPreviewWindowController.shared.close(); try? FileManager.default.removeItem(at: SessionAttachments.directory) }
        let copy = SessionAttachments.directory.appendingPathComponent("preview." + source.pathExtension)
        try data.write(to: copy)
        AttachmentPreviewWindowController.shared.present(relativePath: copy.lastPathComponent, title: "原图只读预览验收")
        try await Task.sleep(for: .milliseconds(250))
        guard let window = NSApp.windows.compactMap({ $0 as? AttachmentPreviewWindow }).first(where: \.isVisible) else {
            throw Failure(message: "没有预览窗口")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), capture.path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "原图的生产预览窗口截图成功，需人工查看比例")
        try require(try Data(contentsOf: source) == data, "原图字节未改动")
        print("INSPECT window=\(window.frame.size) capture=\(capture.path)")
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: SessionAttachments.directory, withIntermediateDirectories: true)
        defer { AttachmentPreviewWindowController.shared.close(); try? FileManager.default.removeItem(at: SessionAttachments.directory) }
        let cases: [(Int, Int, Int, UTType, Int)] = [
            // 原场景元数据：接近正方形，纵向 DPI 为横向两倍；不包含用户原图像素。
            (1244,1230,144,.png,0), (1244,1230,144,.png,1),
            (320,160,72,.png,1), (320,160,36,.tiff,1), (320,160,36,.png,1),
            (320,160,36,.jpeg,1), (100,400,72,.png,1), (30,300,72,.png,1),
            (400,30,72,.png,1), (20,10,72,.png,1), (2000,1000,72,.jpeg,1),
            (320,160,72,.jpeg,6), (320,160,72,.jpeg,8),
            (320,160,144,.tiff,1), (320,160,144,.png,1),
            (320,160,144,.tiff,0), (320,160,144,.jpeg,0), (320,160,36,.png,0)
        ] + (1...8).map { (320,160,144,UTType.jpeg,$0) }
        for (width, height, dpiHeight, type, orientation) in cases {
            let url = try makeImage(width: width, height: height, dpiHeight: dpiHeight, type: type, orientation: orientation)
            let original = try Data(contentsOf: url)
            guard let raw = NSImage(contentsOf: url) else { throw Failure(message: "加载失败") }
            print("SOURCE pixel=\(width)x\(height) NSImage.size=\(raw.size) dpi=72x\(dpiHeight) type=\(type.identifier) orientation=\(orientation)")
            AttachmentPreviewWindowController.shared.present(relativePath: url.lastPathComponent, title: "很长的图片名称-不会挤压正文-" + url.lastPathComponent)
            try await Task.sleep(for: .milliseconds(250))
            let windows = NSApp.windows.compactMap { $0 as? AttachmentPreviewWindow }.filter(\.isVisible)
            try require(windows.count == 1, "单个可见预览窗口")
            guard let window = windows.first, let view = window.contentView else { throw Failure(message: "无内容") }
            let bounds = try redBounds(view)
            let actual = bounds.width / bounds.height
            let expected = (5...8).contains(orientation) ? CGFloat(height) / CGFloat(width) : CGFloat(width) / CGFloat(height)
            print("RENDERED red=\(bounds.size) ratio=\(actual) expected=\(expected) window=\(window.frame.size)")
            try require(abs(actual / expected - 1) < 0.04, "预览真实像素保持原图宽高比")
            if let screen = window.screen {
                try require(window.frame.width <= screen.visibleFrame.width * 0.7 + 1 &&
                    window.frame.height <= screen.visibleFrame.height * 0.7 + 1, "整个预览窗口在屏幕预算内")
            }
            try require(try Data(contentsOf: url) == original, "预览不修改附件字节")
            AttachmentPreviewWindowController.shared.close()
            try require(!window.isVisible, "关闭预览隐藏窗口")
        }
        print("PASS: 图片预览真实渲染比例；未访问用户图片/会话")
    }
}