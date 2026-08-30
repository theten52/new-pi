import AppKit
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
              let image = NSImage(contentsOf: fileURL) else {
            NSSound.beep()
            return
        }
        close()

        // 尺寸适配：图片等比缩到主屏可视区 70% 以内，加上说明与内边距。
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = visible.width * 0.7
        let maxH = visible.height * 0.7
        var size = image.size
        if size.width > maxW || size.height > maxH {
            let scale = min(maxW / size.width, maxH / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        let contentSize = NSSize(
            width: max(size.width + 40, 220),
            height: size.height + 56
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
            rootView: AttachmentPreviewContent(image: image, title: title) { [weak self] in
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
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(20)
        }
        .frame(minWidth: 180, minHeight: 120)
    }
}
