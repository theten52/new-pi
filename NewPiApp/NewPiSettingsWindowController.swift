import AppKit
import SwiftUI

/// 只接住本窗口 responder chain 中尚未消费的取消动作；不抢文本输入、菜单或 sheet 的 ESC。
@MainActor
final class NewPiSettingsWindow: NSWindow {
    private var handlingMarkedEscape = false

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === self,
              let client = firstResponder as? NSTextInputClient, client.hasMarkedText() else {
            super.sendEvent(event)
            return
        }
        // 记录分发前的组合态：输入法即使先结束组合再转发 cancel，也不能关闭本窗口。
        handlingMarkedEscape = true
        defer { handlingMarkedEscape = false }
        super.sendEvent(event)
        // 原生输入法优先；直接 marked text 等未被输入上下文处理的情形才补取消。
        // 删除组合区而非 unmarkText，避免把 ESC 误作提交；保留已有正文。
        if client.hasMarkedText() {
            let range = client.markedRange()
            client.insertText("", replacementRange: range)
            (client as? NSView)?.inputContext?.discardMarkedText()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // AppKit 也可能把带修饰键的 ESC 解释成取消，不能只在 keyDown 兜底中过滤。
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53,
           !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            return
        }
        // 子层由系统处理取消，不能把同一次 ESC 继续用于关闭父 Settings。
        guard !handlingMarkedEscape, attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === self,
              (firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        // 走正常 close lifecycle（含 delegate），而不是 orderOut 或直接释放 controller。
        // 主设置即时保存；关闭窗口不意味着回滚已经应用的选项。
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        // 空白区域及 NSHostingView 的按钮可能把未处理按键直接交给 window，
        // 而 NSWindow 默认不会把它解释成 cancelOperation。仅为裸 ESC 补这一层。
        // 不重写 performKeyEquivalent：field editor / 输入法 / SwiftUI sheet 优先处理。
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            cancelOperation(self)
        } else {
            super.keyDown(with: event)
        }
    }
}

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
        let window = NewPiSettingsWindow(
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
