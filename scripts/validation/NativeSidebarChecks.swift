import AppKit
import ApplicationServices

// 授权后对已运行的 Debug App 做窄范围验收；不启动会话、不遍历 Web 正文。
// inspect/check 不写草稿；composer 模式只在空输入时临时输入固定文本并恢复，不发送。
private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

private func descendants(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func visit(_ element: AXUIElement, depth: Int) {
        guard depth < 30, result.count < 2000 else { return }
        result.append(element)
        // 系统菜单栏常驻暴露子菜单，不代表窗口弹出了菜单；正文也不属于本探针范围。
        guard !["AXWebArea", "AXMenuBar"].contains(string(element, kAXRoleAttribute)) else { return }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            visit(child, depth: depth + 1)
        }
    }
    visit(root, depth: 0)
    return result
}

private func frame(_ element: AXUIElement) -> CGRect {
    var point = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
    }
    if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
        AXValueGetValue(value as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: point, size: size)
}

private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
    print("PASS: \(message)")
}

@main
private struct NativeSidebarChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 3,
                            ["inspect", "check", "composer-inspect", "composer"].contains(CommandLine.arguments[2]) else {
                        throw Failure(message: "参数：指定 NewPi.app 路径 inspect|check|composer-inspect|composer")
        }
        try require(AXIsProcessTrusted(), "辅助功能已授权（本程序不请求权限）")
        let executable = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            .appendingPathComponent("Contents/MacOS/NewPi").path
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.path == executable }) else {
            throw Failure(message: "指定 App 未运行，不自动启动或关闭其他实例")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        guard let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw Failure(message: "无主窗口")
        }
        func controls() -> [AXUIElement] { descendants(window) }
        if CommandLine.arguments[2] == "composer-inspect" {
            for element in controls() where ["AXTextArea", "AXMenuButton", "AXButton"].contains(string(element, kAXRoleAttribute)) {
                let name = string(element, kAXDescriptionAttribute)
                guard string(element, kAXRoleAttribute) == "AXTextArea"
                    || ["模型与思考级别", "用量", "发送消息", "停止生成"].contains(name) else { continue }
                var focusSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusSettable)
                let enabled = (attribute(element, kAXEnabledAttribute) as? Bool).map { String($0) } ?? "unavailable"
                print("COMPOSER role=\(string(element, kAXRoleAttribute)) label=\(name) enabled=\(enabled) empty=\(string(element, kAXValueAttribute).isEmpty) focusSettable=\(focusSettable.boolValue)")
            }
            return
        }
        if CommandLine.arguments[2] == "composer" {
            try await checkComposer(app: app, root: root, window: window)
            return
        }
        func toolbarControls() -> [AXUIElement] {
            controls().filter { string($0, kAXRoleAttribute) == "AXToolbar" }.flatMap(descendants)
        }
        func systemToggles() -> [AXUIElement] {
            toolbarControls().filter { element in
                let role = string(element, kAXRoleAttribute)
                let identity = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .map { string(element, $0) }
                return ["AXButton", "AXCheckBox"].contains(role)
                    && identity.contains { $0.localizedCaseInsensitiveContains("sidebar") || $0.contains("侧栏") || $0.contains("边栏") }
            }
        }
        if CommandLine.arguments[2] == "inspect" {
            for element in toolbarControls() {
                print("TOOLBAR role=\(string(element, kAXRoleAttribute)) id=\(string(element, kAXIdentifierAttribute)) description=\(string(element, kAXDescriptionAttribute))")
            }
            return
        }
        try require(!controls().contains { string($0, kAXIdentifierAttribute) == "workbench.sidebar.toggle" }, "没有自定义侧栏按钮")
        try require(systemToggles().count == 1, "仅一个系统侧栏开关")
        guard let toggle = systemToggles().first,
              let editor = controls().first(where: { string($0, kAXRoleAttribute) == "AXTextArea" }),
              let navigation = controls().first(where: { string($0, kAXDescriptionAttribute) == "工作区导航" }) else {
            throw Failure(message: "缺少系统开关、输入框或可见侧栏，请先打开普通会话并展开侧栏")
        }
        try require(frame(navigation).width > 100 && frame(window).intersects(frame(navigation)), "初始侧栏可见")
        let draft = string(editor, kAXValueAttribute)
        let original = frame(editor)
        func press(_ control: AXUIElement) throws {
            try require(AXUIElementPerformAction(control, kAXPressAction as CFString) == .success, "系统开关接受 AXPress")
        }
        func waitForLayout(_ description: String, condition: () -> Bool) async throws {
            var stable = 0
            for _ in 0..<60 {
                stable = condition() ? stable + 1 : 0
                if stable >= 4 { print("PASS: \(description)"); return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure(message: description)
        }
        var needsRestore = false
        defer {
            if needsRestore, let control = systemToggles().first {
                print("CLEANUP AXPress=\(AXUIElementPerformAction(control, kAXPressAction as CFString).rawValue)")
            }
        }
        try press(toggle)
        needsRestore = true
        try await waitForLayout("侧栏收起后阅读布局已改变") { abs(frame(editor).midX - original.midX) > 30 }
        try require(systemToggles().count == 1, "侧栏收起后仍只有一个系统开关")
        guard let reopen = systemToggles().first else { throw Failure(message: "收起后无法定位系统开关") }
        try press(reopen)
        needsRestore = false
        try await waitForLayout("展开后恢复原输入区位置和宽度") {
            abs(frame(editor).minX - original.minX) < 1 && abs(frame(editor).width - original.width) < 1
        }
        try require(controls().contains { CFEqual($0, editor) }, "输入框 AX 身份不变")
        try require(string(editor, kAXValueAttribute) == draft, "现有输入内容不变（未写测试草稿）")
        print("PASS: 系统侧栏往返；过渡交由 macOS，本检查不测量动画帧率")
    }

    @MainActor private static func checkComposer(app: NSRunningApplication, root: AXUIElement, window: AXUIElement) async throws {
        func controls() -> [AXUIElement] { descendants(window) }
        func named(_ name: String) -> AXUIElement? {
            controls().first { string($0, kAXDescriptionAttribute) == name }
        }
        let editors = controls().filter { string($0, kAXRoleAttribute) == "AXTextArea" }
        try require(editors.count == 1, "只有一个输入框，避免误操作保活的隐藏面板")
        guard let editor = editors.first, let model = named("模型与思考级别"), let send = named("发送消息") else {
            throw Failure(message: "当前不是可测试的普通会话")
        }
        try require(string(editor, kAXValueAttribute).isEmpty && named("停止生成") == nil,
                    "输入为空且当前会话未运行；不覆盖已有草稿")
        try require(attribute(send, kAXEnabledAttribute) as? Bool == false, "初始发送禁用，无待发文本或附件")
          try require(attribute(model, kAXEnabledAttribute) as? Bool == true, "模型菜单可操作")
          guard let navigation = named("工作区导航"), frame(navigation).width > 100,
              frame(window).intersects(frame(navigation)) else { throw Failure(message: "请先展开侧栏") }
        try require(!descendants(root).contains { ["AXMenu", "AXSheet"].contains(string($0, kAXRoleAttribute)) }, "无已打开的菜单或表单")
        let modelBefore = string(model, kAXValueAttribute)
        let marker = "NewPi 界面验收草稿（不发送）"
        var expected = marker
        var ownedTexts: Set<String> = [marker]
        func wait(_ message: String, condition: () -> Bool) async throws {
            for _ in 0..<40 {
                if condition() { print("PASS: \(message)"); return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure(message: message)
        }
        func isEditorFocused() -> Bool {
            attribute(root, kAXFocusedUIElementAttribute).map { CFEqual($0, editor) } ?? false
        }
        func key(_ code: CGKeyCode, text: String? = nil, flags: CGEventFlags = []) async throws {
            try require(app.isActive, "键盘事件仅发给已激活的目标 App")
            if code != 53 {
                try require(isEditorFocused(), "文本编辑事件的目标仍是原输入框")
            }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                    throw Failure(message: "不能创建测试键盘事件")
                }
                event.flags = flags
                if let text {
                    let utf16 = Array(text.utf16)
                    utf16.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
                }
                event.postToPid(app.processIdentifier)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        func focusEditor() throws {
            try require(AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                        "真实输入框接受焦点")
        }
        func openMenuPresent() -> Bool { descendants(root).contains { string($0, kAXRoleAttribute) == "AXMenu" } }
        func usagePresent() -> Bool {
            descendants(root).contains { string($0, kAXValueAttribute) == "用量明细" || string($0, kAXDescriptionAttribute) == "用量明细" }
        }
        func cleanup() async throws {
            if openMenuPresent() || usagePresent() { try await key(53) }
            let current = string(editor, kAXValueAttribute)
            if current.isEmpty { return }
            guard ownedTexts.contains(current), app.isActive else {
                throw Failure(message: "输入发生外部变化或 App 不在前台；停止清理以免覆盖用户内容")
            }
            try focusEditor()
            try await wait("清理前输入框获得焦点") { isEditorFocused() }
            try await key(0, flags: .maskCommand) // ⌘A，只选择当前输入框内容。
            try await key(51) // Delete，不触发提交。
            try await wait("临时草稿已清空且发送重新禁用") {
                string(editor, kAXValueAttribute).isEmpty && attribute(send, kAXEnabledAttribute) as? Bool == false
            }
        }
        app.activate(options: [])
        try await wait("正式 App 已激活") { app.isActive }
        try focusEditor()
        try await wait("输入框获得实际键盘焦点") { isEditorFocused() }
        do {
            try await key(0, text: marker)
            try await wait("真实键盘输入已同步，发送按钮启用") {
                string(editor, kAXValueAttribute) == marker && attribute(send, kAXEnabledAttribute) as? Bool == true
            }
            let beforeFrame = frame(editor)
            func sidebar() -> AXUIElement? {
                controls().filter { string($0, kAXRoleAttribute) == "AXToolbar" }.flatMap(descendants).first {
                    let label = string($0, kAXDescriptionAttribute)
                    return string($0, kAXRoleAttribute) == "AXButton"
                        && (label.localizedCaseInsensitiveContains("sidebar") || label.contains("侧栏") || label.contains("边栏"))
                }
            }
            guard let toggle = sidebar() else { throw Failure(message: "无法定位系统侧栏开关") }
            try require(AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success, "带非空草稿收起侧栏")
            var restoreSidebar = true
            do {
                try await wait("侧栏收起布局生效") { abs(frame(editor).midX - beforeFrame.midX) > 30 }
                guard let reopen = sidebar() else { throw Failure(message: "无法重新展开侧栏") }
                try require(AXUIElementPerformAction(reopen, kAXPressAction as CFString) == .success, "带非空草稿展开侧栏")
                restoreSidebar = false
                try await wait("侧栏恢复原输入区布局") { abs(frame(editor).minX - beforeFrame.minX) < 1 }
            } catch {
                if restoreSidebar, let reopen = sidebar() { _ = AXUIElementPerformAction(reopen, kAXPressAction as CFString) }
                throw error
            }
            try require(string(editor, kAXValueAttribute) == expected && controls().contains { CFEqual($0, editor) },
                        "正式 App：侧栏往返保留非空草稿与输入框 AX 身份")
            for name in ["模型与思考级别", "用量"] {
                try focusEditor()
                guard let button = named(name) else { throw Failure(message: "缺少菜单入口") }
                AXUIElementSetMessagingTimeout(button, 2)
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                print("MENU OPEN AXResult=\(result.rawValue) name=\(name)")
                try await wait("\(name) 实际打开") { name == "用量" ? usagePresent() : openMenuPresent() }
                try await key(53) // Escape，绝不选择模型或思考档位。
                try await wait("\(name) Escape 关闭") { !openMenuPresent() && !usagePresent() }
                try await wait("\(name) 关闭后恢复输入框焦点") { isEditorFocused() }
                expected += " ·继续"
                ownedTexts.insert(expected)
                try await key(0, text: " ·继续")
                try await wait("\(name) 关闭后可继续输入且原草稿保留") { string(editor, kAXValueAttribute) == expected }
            }
            try require(string(model, kAXValueAttribute) == modelBefore, "模型与思考级别未改变")
        } catch {
            try await cleanup()
            throw error
        }
        try await cleanup()
        print("PASS: 正式 App 非空草稿、侧栏、菜单 Escape 与续写；未发送、未改模型、未访问剪贴板")
    }
}