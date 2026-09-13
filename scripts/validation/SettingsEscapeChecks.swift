import AppKit
import SwiftUI

// 由 check-settings-escape.sh 合并生产窗口类、windowWillClose 和五个 toolbar Cancel 定义。
// 仅内存 fixture：不初始化 NewPiViewModel，不读取 UserDefaults/凭据/provider/MCP，不截图。
// 所有 ESC 均为 NSEvent，经 NSApplication 或 NSWindow 分发，不直接调用 cancelOperation。

@MainActor final class SettingsLifetimeFixture: NSWindowController {
    static var shared: SettingsLifetimeFixture?

    static func show() -> SettingsLifetimeFixture {
        if shared == nil { shared = SettingsLifetimeFixture() }
        let controller = shared!
        controller.window!.makeKeyAndOrderFront(nil)
        return controller
    }

    private init() {
        let window = NewPiSettingsWindow(
            contentRect: NSRect(x: 120, y: 120, width: 600, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Settings ESC · 独立合成验证"
        window.delegate = self
        // 刻意不设置 frameAutosaveName；与生产共享的仅是窗口类和关闭 delegate 方法。
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor private final class CloseVeto: NSObject, NSWindowDelegate {
    var requests = 0
    var closes = 0
    var allow = false
    func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return allow }
    func windowWillClose(_ notification: Notification) { closes += 1 }
}

enum SettingsCancelKind: CaseIterable {
    case addProvider, editProvider, templates, vendor, model
}

@MainActor private final class SheetLedger: ObservableObject {
    @Published var shown = false
    var saves = 0
    var persisted = "原值"
    var observedDraft = "原值"
}

private struct CancelDraftSheet: View {
    let kind: SettingsCancelKind
    @ObservedObject var ledger: SheetLedger
    @Environment(\.dismiss) private var dismiss
    @State private var draft = "原值"

    var body: some View {
        NavigationStack {
            Form {
                TextField("合成草稿", text: $draft)
                    .accessibilityIdentifier("settings.escape.draft")
            }
            .formStyle(.grouped)
            .navigationTitle("独立取消测试")
            .toolbar {
                // 这里注入生产实际 Button + dismiss + keyboardShortcut，不手抄取消动作。
                kind.cancellation(dismiss: dismiss)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save（仅测试计数）") {
                        ledger.saves += 1
                        ledger.persisted = draft
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 440, height: 280)
        .onChange(of: draft) { _, value in ledger.observedDraft = value }
    }
}

private struct SheetRoot: View {
    let kind: SettingsCancelKind
    @ObservedObject var ledger: SheetLedger
    @ObservedObject var nested: SheetLedger

    var body: some View {
        Text("父 Settings：ESC 不能穿透 sheet")
            .frame(width: 600, height: 440)
            .sheet(isPresented: $ledger.shown) {
                CancelDraftSheet(kind: kind, ledger: ledger)
                    .sheet(isPresented: $nested.shown) {
                        CancelDraftSheet(kind: .model, ledger: nested)
                    }
            }
    }
}

@MainActor private final class ButtonLedger: ObservableObject {
    var focused = false
    var presses = 0
}

private struct HostingButtonFixture: View {
    @ObservedObject var ledger: ButtonLedger
    @FocusState private var focused: Bool
    var body: some View {
        Button("SwiftUI 按钮（ESC 不应触发 action）") { ledger.presses += 1 }
            .focusable()
            .focused($focused)
            .frame(width: 600, height: 440)
            .onChange(of: focused) { _, value in ledger.focused = value }
            .onAppear { focused = true }
    }
}

private struct HostingTextFieldFixture: View {
    @State var text: String
    var body: some View {
        TextField("独立主设置文本框", text: $text)
            .frame(width: 350)
            .frame(width: 600, height: 440)
    }
}

@main @MainActor struct SettingsEscapeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static var passes = 0

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        Task { @MainActor in
            do {
                try await run()
                print("SUMMARY: PASS=\(passes) FAIL=0")
                print("LIMIT: 菜单 tracking / 真实输入法候选窗未自动验证；请手动确认首个 ESC 只取消本层，下一次再关闭 Settings。")
                print("LIMIT: 组件没有构造真实 Settings ViewModel；不声称整页集成、持久化或选项回滚经过验证。")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                print("SUMMARY: PASS=\(passes) FAIL=1")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("FAIL: Settings ESC 验证超时"); exit(1)
        }
        NSApp.run()
    }

    private static func run() async throws {
        let first = SettingsLifetimeFixture.show()
        guard let window = first.window else { throw Failure(description: "未创建测试窗口") }
        NSApp.activate(ignoringOtherApps: true)
        let activationAccepted = NSRunningApplication.current.activate(options: [])
        // 独立命令行探针激活需跨进程完成；不能以一次 180ms 延迟误判无图形会话。
        let focusDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(NSApp.isActive && window.isKeyWindow), ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        print("FOCUS: accepted=\(activationAccepted) active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible)")
        guard NSApp.isActive, window.isKeyWindow else {
            print("UNVERIFIED: 独立探针无法取得图形会话焦点；没有访问用户 App")
            exit(2)
        }
        try require(window.makeFirstResponder(window), "空白窗口为 first responder")
        try await escape(window)
        try await eventually("空白焦点 ESC 经关闭 delegate 清空 shared") {
            !window.isVisible && SettingsLifetimeFixture.shared == nil
        }
        let reopened = SettingsLifetimeFixture.show()
        try require(reopened !== first && reopened.window !== window, "关闭后重开创建新 controller/window")
        guard let reopenedWindow = reopened.window else { throw Failure(description: "重开失败") }
        try require(reopenedWindow.makeFirstResponder(reopenedWindow), "重开窗口获得焦点")
        try await escape(reopenedWindow)
        try require(SettingsLifetimeFixture.shared == nil, "重开窗口 ESC 同样释放 shared")

        // performClose 必须尊重 delegate veto，而非直接 close/orderOut。
        let vetoController = SettingsLifetimeFixture.show()
        let vetoWindow = vetoController.window!
        let veto = CloseVeto()
        vetoWindow.delegate = veto
        try require(vetoWindow.makeFirstResponder(vetoWindow), "veto 测试焦点就绪")
        try await escape(vetoWindow)
        try require(veto.requests == 1 && veto.closes == 0 && vetoWindow.isVisible, "ESC 尊重 windowShouldClose 否决")
        veto.allow = true
        try await escape(vetoWindow)
        try require(veto.requests == 2 && veto.closes == 1 && !vetoWindow.isVisible, "允许关闭后 delegate 收到 windowWillClose 一次")
        SettingsLifetimeFixture.shared = nil // 本用例临时替换了生产 delegate，恢复 fixture。

        for initial in ["", "已编辑文本"] {
            let controller = SettingsLifetimeFixture.show()
            let target = controller.window!
            let field = NSTextField(frame: NSRect(x: 24, y: 160, width: 350, height: 30))
            field.stringValue = initial
            target.contentView!.addSubview(field)
            try require(target.makeFirstResponder(field), "NSTextField 获取编辑焦点")
            try require((target.firstResponder as? NSTextView)?.isFieldEditor == true, "真实 field editor 而非模拟 responder")
            try await escape(target)
            try await eventually("NSTextField（\(initial.isEmpty ? "空" : "非空")）ESC 关闭且清理 delegate") {
                !target.isVisible && SettingsLifetimeFixture.shared == nil
            }
        }

        let textController = SettingsLifetimeFixture.show()
        let textWindow = textController.window!
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 420, height: 220))
        editor.isRichText = false
        editor.string = "已有正文"
        textWindow.contentView!.addSubview(editor)
        try require(textWindow.makeFirstResponder(editor), "NSTextView 获得焦点")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("组合输入", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(editor.hasMarkedText(), "真实 NSTextInputClient 已设置 marked text")
        try await escape(textWindow)
        try require(textWindow.isVisible && SettingsLifetimeFixture.shared === textController,
                    "marked text 的首个 ESC 不关闭父窗口")
        try require(!editor.hasMarkedText(), "首个 ESC 结束原生文本客户端组合，而非窗口吞掉")
        try require(editor.string == "已有正文", "ESC 取消组合文字而不提交，保留已有正文")
        try await escape(textWindow)
        try await eventually("组合结束后的下一个 ESC 正常关闭") { !textWindow.isVisible }

        for initial in ["", "已编辑文本"] {
            let controller = SettingsLifetimeFixture.show()
            let target = controller.window!
            target.contentViewController = NSHostingController(rootView: HostingTextFieldFixture(text: initial))
            try await eventually("主窗口 SwiftUI 文本框已创建") {
                target.contentView.map { views($0).contains { ($0 as? NSTextField)?.isEditable == true } } ?? false
            }
            let field = views(target.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
            try require(target.makeFirstResponder(field), "主窗口 SwiftUI 文本框获得焦点")
            try require((target.firstResponder as? NSTextView)?.isFieldEditor == true, "主窗口 SwiftUI 使用真实 field editor")
            if !initial.isEmpty, let fieldEditor = target.firstResponder as? NSTextView {
                fieldEditor.setSelectedRange(NSRange(location: (fieldEditor.string as NSString).length, length: 0))
                fieldEditor.setMarkedText("组合输入", selectedRange: NSRange(location: 4, length: 0),
                                          replacementRange: NSRange(location: NSNotFound, length: 0))
                try require(fieldEditor.hasMarkedText(), "SwiftUI field editor 已设置组合文字")
                try await escape(target)
                try require(target.isVisible && SettingsLifetimeFixture.shared === controller,
                            "SwiftUI field editor 首个组合 ESC 不关闭 Settings")
                try require(!fieldEditor.hasMarkedText() && fieldEditor.string == initial,
                            "SwiftUI field editor 取消组合不提交、不丢已有文字")
            }
            try await escape(target)
            try await eventually("SwiftUI TextField（\(initial.isEmpty ? "空" : "非空")）ESC 关闭且清理 delegate") {
                !target.isVisible && SettingsLifetimeFixture.shared == nil
            }
        }

        let buttonController = SettingsLifetimeFixture.show()
        let buttonWindow = buttonController.window!
        let buttonLedger = ButtonLedger()
        let hosting = NSHostingController(rootView: HostingButtonFixture(ledger: buttonLedger))
        buttonWindow.contentViewController = hosting
        try await eventually("SwiftUI 按钮实际获得键盘焦点") {
            guard buttonLedger.focused, let responder = buttonWindow.firstResponder as? NSView else { return false }
            return responder === hosting.view || responder.isDescendant(of: hosting.view)
        }
        print("FOCUS: SwiftUI button responder=\(String(describing: buttonWindow.firstResponder))")
        try await escape(buttonWindow)
        try await eventually("NSHostingView 按钮焦点 ESC 关闭") { !buttonWindow.isVisible }
        try require(buttonLedger.presses == 0 && SettingsLifetimeFixture.shared == nil, "ESC 不执行按钮 action；正常 delegate 清理")

        let modifiersController = SettingsLifetimeFixture.show()
        let modifiersWindow = modifiersController.window!
        try require(modifiersWindow.makeFirstResponder(modifiersWindow), "修饰键测试焦点就绪")
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            try await key(modifiersWindow, code: 53, text: "\u{1b}", modifiers: flags)
            try require(modifiersWindow.isVisible, "ESC 兜底不抢带修饰键事件：\(flags.rawValue)")
        }
        try await escape(modifiersWindow)

        // 普通 NSWindow 不受影响，证明不是全局 Escape handler。
        let other = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 280, height: 180),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        try require(other.makeFirstResponder(other), "无关合成窗口获得焦点")
        try await escape(other)
        try require(other.isVisible, "其他 NSWindow 不被 Settings ESC 关闭")
        other.close()

        // 单独检查错误路由到父窗口的按键，不与 SwiftUI dismiss 动画混用。
        let guardedController = SettingsLifetimeFixture.show()
        let guardedParent = guardedController.window!
        let nativeSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        nativeSheet.isReleasedWhenClosed = false
        try require(guardedParent.makeFirstResponder(guardedParent), "父 sheet 防护测试焦点就绪")
        guardedParent.beginSheet(nativeSheet, completionHandler: { _ in })
        try await eventually("原生防护测试 sheet 已挂载") { guardedParent.attachedSheet === nativeSheet }
        guardedParent.sendEvent(try makeKey(guardedParent, type: .keyDown, code: 53, text: "\u{1b}", modifiers: []))
        try require(guardedParent.isVisible && guardedParent.attachedSheet === nativeSheet
                    && SettingsLifetimeFixture.shared === guardedController, "发送到父窗口的 ESC 不穿透 attachedSheet")
        guardedParent.endSheet(nativeSheet)
        nativeSheet.orderOut(nil)
        try await eventually("原生防护测试 sheet 已移除") { guardedParent.attachedSheet == nil }
        try await escape(guardedParent)
        try require(SettingsLifetimeFixture.shared == nil, "移除 sheet 后父窗口恢复正常关闭")

        for kind in SettingsCancelKind.allCases {
            try await checkSheet(kind)
        }
    }

    private static func checkSheet(_ kind: SettingsCancelKind) async throws {
        let controller = SettingsLifetimeFixture.show()
        let parent = controller.window!
        let ledger = SheetLedger()
        let nested = SheetLedger()
        parent.contentViewController = NSHostingController(rootView: SheetRoot(kind: kind, ledger: ledger, nested: nested))
        try await pause()
        ledger.shown = true
        try await eventually("\(kind) 真实 SwiftUI sheet 打开") { parent.attachedSheet?.isVisible == true }
        guard let sheet = parent.attachedSheet else { throw Failure(description: "无 attachedSheet") }
        try await editDraft(in: sheet, ledger: ledger)

        if kind == .vendor {
            nested.shown = true
            try await eventually("模板编辑内嵌模型 sheet 打开") { sheet.attachedSheet?.isVisible == true }
            guard let child = sheet.attachedSheet else { throw Failure(description: "无嵌套 sheet") }
            try await editDraft(in: child, ledger: nested)
            try await escape(child)
            try await eventually("第一个 ESC 仅取消内嵌模型") { !nested.shown && sheet.attachedSheet == nil }
            try require(ledger.shown && parent.isVisible && sheet.isVisible && ledger.saves == 0
                        && nested.saves == 0 && nested.persisted == "原值", "嵌套取消不保存任何草稿、不关闭外层")
        }

        // 正常用户路径：投递到当前 sheet；只有实际 Cancel 定义调用 dismiss。
        try await escape(sheet)
        try await eventually("\(kind) ESC 取消本层 sheet") { !ledger.shown && parent.attachedSheet == nil }
        try require(ledger.saves == 0 && ledger.persisted == "原值" && ledger.observedDraft != "原值",
                    "\(kind) 已修改草稿未触发 Save")
        try require(parent.isVisible && SettingsLifetimeFixture.shared === controller, "sheet 取消后父 Settings 仍打开")
        parent.makeKeyAndOrderFront(nil)
        try require(parent.makeFirstResponder(parent), "sheet 退出后父窗口焦点就绪")
        try await escape(parent)
        try await eventually("下一次 ESC 关闭父窗口并清空 shared") { !parent.isVisible && SettingsLifetimeFixture.shared == nil }
    }

    private static func editDraft(in sheet: NSWindow, ledger: SheetLedger) async throws {
        try await eventually("SwiftUI sheet 已创建实际 NSTextField") {
            sheet.contentView.map { views($0).contains { ($0 as? NSTextField)?.isEditable == true } } ?? false
        }
        guard let root = sheet.contentView,
              let field = views(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else {
            throw Failure(description: "sheet 缺少真实文本框")
        }
        sheet.makeKey()
        try require(sheet.makeFirstResponder(field), "sheet 文本框获得编辑焦点")
        try require((sheet.firstResponder as? NSTextView)?.isFieldEditor == true, "sheet 使用真实 field editor")
        try await key(sheet, code: 7, text: "x", modifiers: [])
        try await eventually("实际字符事件已修改 sheet 本地草稿") { ledger.observedDraft != "原值" }
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    private static func escape(_ window: NSWindow) async throws {
        try await key(window, code: 53, text: "\u{1b}", modifiers: [])
    }

    private static func key(_ window: NSWindow, code: UInt16, text: String,
                            modifiers: NSEvent.ModifierFlags) async throws {
        window.makeKey()
        try await eventually("事件目标为 key window") { window.isKeyWindow }
        print("KEY BEFORE: code=\(code) modifiers=\(modifiers.rawValue) responder=\(String(describing: window.firstResponder.map { type(of: $0) })) marked=\((window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true) sheet=\(window.attachedSheet != nil)")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.postEvent(try makeKey(window, type: type, code: code, text: text, modifiers: modifiers), atStart: false)
        }
        try await pause()
        print("KEY AFTER: code=\(code) visible=\(window.isVisible) responder=\(String(describing: window.firstResponder.map { type(of: $0) })) marked=\((window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true) sheet=\(window.attachedSheet != nil)")
    }

    private static func makeKey(_ window: NSWindow, type: NSEvent.EventType, code: UInt16,
                                text: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
            throw Failure(description: "无法构造真实 NSEvent")
        }
        return event
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(description: message) }
        passes += 1
        print("PASS: \(message)")
    }

    private static func pause() async throws { try await Task.sleep(for: .milliseconds(180)) }

    private static func eventually(_ message: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { try require(true, message); return }
            try await Task.sleep(for: .milliseconds(30))
        }
        print("TIMEOUT: \(message) active=\(NSApp.isActive) responder=\(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))")
        throw Failure(description: message)
    }
}