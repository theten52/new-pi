import AppKit
import CoreImage
import ImageIO
import NewPiCore
import SwiftUI

/// 用户气泡附件缩略图的点击放大预览（BACKLOG-IMAGE-INPUT 二期；原生浮层）。
///
/// JS 侧点击缩略图 → `attachmentTap` message（携带相对附件路径）→ 这里经
/// `SessionAttachments.resolve`（受控边界）解析后读盘展示；不经 WKWebView 传图数据，
/// 不开任意本地文件读取。单窗口复用：再次点击换图。
@MainActor
final class AttachmentPreviewWindowController {
    static let shared = AttachmentPreviewWindowController()

    private var window: AttachmentPreviewWindow?
    /// Esc 关闭的本地事件监听（present 时注册，close 时移除）。
    private var escMonitor: Any?

    func present(relativePath: String, title: String) {
        guard let fileURL = SessionAttachments.resolve(relativePath: relativePath),
              let image = Self.loadPreviewImage(at: fileURL) else {
            NSSound.beep()
            return
        }
        close()

        // 先扣除内边距与标题，再等比缩图；整个窗口不超过可视区 70%。
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = max(1, visible.width * 0.7 - 40)
        let maxH = max(1, visible.height * 0.7 - 66)
        var size = image.size
        if size.width > maxW || size.height > maxH {
            let scale = min(maxW / size.width, maxH / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let contentSize = NSSize(
            width: max(size.width + 40, min(220, visible.width * 0.7)),
            height: size.height + 66
        )

        let window = AttachmentPreviewWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.animationBehavior = .utilityWindow
        window.contentView = NSHostingView(
            rootView: AttachmentPreviewContent(image: image, imageSize: size, contentSize: contentSize, title: title) { [weak self] in
                self?.close()
            }
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // borderless 窗口不走标准 performClose 快捷键，本地监听 Esc。
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.close()
                return nil
            }
            return event
        }
    }

    // NSImage(contentsOf:) 的逻辑尺寸会受 DPI 影响，非等比 DPI 会把屏幕图片拉伸。
    // thumbnail 的 WithTransform 在方向字段缺省时也会按 DPI 重采样，不能用于屏幕比例归一化。
    // 直接解码像素，单独应用 EXIF 的旋转/镜像；不改动磁盘附件。
    private static func loadPreviewImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        if (2...8).contains(orientation) {
            let oriented = CIImage(cgImage: pixels).oriented(forExifOrientation: orientation)
            guard let transformed = CIContext().createCGImage(oriented, from: oriented.extent) else { return nil }
            pixels = transformed
        }
        return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
    }

    func close() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}

/// borderless 窗口需要显式允许成为 key window（否则收不到键盘事件）。
final class AttachmentPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct AttachmentPreviewContent: View {
    let image: NSImage
    let imageSize: NSSize
    let contentSize: NSSize
    let title: String
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width, height: imageSize.height)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .frame(width: contentSize.width - 40, height: 16)
            }
            .padding(20)
        }
        .frame(width: contentSize.width, height: contentSize.height)
    }
}
