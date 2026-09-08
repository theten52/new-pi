import AppKit
import SwiftUI

/// Settings 使用独立 NSWindowController，而不是 SwiftUI `Settings` scene：
/// 创建窗口时即可带上 `.fullSizeContentView`，在 macOS 26 获得正确的圆角与材质标题栏，
/// 同时明确控制最小尺寸、单实例与窗口位置恢复。
@MainActor
final class NewPiSettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: NewPiSettingsWindowController?

    static func show() {
        if shared == nil {
            shared = NewPiSettingsWindowController(
                viewModel: NewPiRootViewModelStore.shared.viewModel
            )
        }
        shared?.showWindow(nil)
    }

    private init(viewModel: NewPiViewModel) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 900, height: 650)),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 800, height: 540)
        window.contentViewController = NSHostingController(
            rootView: NewPiSettingsView(viewModel: viewModel)
        )
        // NSHostingController 会先按 SwiftUI 根视图的最小 fitting size 调整窗口；
        // 在挂载之后恢复默认内容尺寸，避免首次打开只得到最窄的 800pt 窗口。
        window.setContentSize(NSSize(width: 900, height: 650))
        let frameName = "NewPiSettingsWindow"
        if !window.setFrameUsingName(frameName) {
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
