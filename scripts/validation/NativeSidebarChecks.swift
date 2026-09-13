import AppKit
import ApplicationServices

// 授权后对已运行的 Debug App 做窄范围验收；不启动会话、不遍历 Web 正文。
// inspect/check/layout 不写草稿；composer/navigation 只在空输入时临时输入固定文本并恢复，不发送。
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
                            ["inspect", "check", "composer-inspect", "composer", "navigation", "navigation-inspect", "layout", "attachment"].contains(CommandLine.arguments[2]) else {
                        throw Failure(message: "参数：指定 NewPi.app 路径 inspect|check|composer-inspect|composer|navigation-inspect|navigation|layout|attachment")
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
        if CommandLine.arguments[2] == "attachment" {
            try await checkAttachment(app: app, root: root, window: window)
            return
        }
        if CommandLine.arguments[2] == "layout" {
            var original = frame(window).size
            defer {
                if let size = AXValueCreate(.cgSize, &original) {
                    print("RESTORE windowSize=\(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size).rawValue)")
                }
            }
            for width: CGFloat in [1200, 900] {
                var requested = CGSize(width: width, height: original.height)
                guard let size = AXValueCreate(.cgSize, &requested) else { throw Failure(message: "无法构造尺寸") }
                try require(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size) == .success, "设置 \(width)pt 窗口")
                try await Task.sleep(for: .milliseconds(500))
                try require(abs(frame(window).width - width) < 1, "窗口实际达到指定宽度")
                let names = ["用量", "模型与思考级别", "发送消息", "更多操作"]
                for name in names {
                    guard let control = controls().first(where: { string($0, kAXDescriptionAttribute) == name }) else { throw Failure(message: "缺少\(name)") }
                    try require(frame(window).contains(frame(control)), "\(Int(width))pt：\(name)在窗口内")
                }
                guard let model = controls().first(where: { string($0, kAXDescriptionAttribute) == "模型与思考级别" }),
                      let send = controls().first(where: { string($0, kAXDescriptionAttribute) == "发送消息" }),
                      let editor = controls().first(where: { string($0, kAXRoleAttribute) == "AXTextArea" }) else { throw Failure(message: "缺少输入区") }
                try require(frame(model).maxX < frame(send).minX && frame(editor).width > 400 && abs(frame(editor).height - 78) < 1,
                            "输入区四行高度和模型/主按钮无碰撞")
            }
            return
        }
        if CommandLine.arguments[2] == "navigation-inspect" {
            guard let navigation = controls().first(where: { string($0, kAXDescriptionAttribute) == "工作区导航" }) else {
                throw Failure(message: "缺少导航区")
            }
            let buttons = descendants(navigation).filter { string($0, kAXRoleAttribute) == "AXButton" }
            for (index, button) in buttons.enumerated() {
                let texts = descendants(button).flatMap { [string($0, kAXValueAttribute), string($0, kAXDescriptionAttribute), string($0, kAXHelpAttribute)] }
                let roomCandidate = !texts.contains { $0.contains("条消息") }
                    && texts.contains { value in ["讨论", "投票", "执行", "评审", "完成"].contains { value.contains($0) } }
                print("NAV index=\(index) selected=\(attribute(button, kAXSelectedAttribute) as? Bool ?? false) session=\(texts.contains { $0.contains("条消息") }) roomCandidate=\(roomCandidate) frame=\(frame(button))")
            }
            return
        }
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
        if ["composer", "navigation"].contains(CommandLine.arguments[2]) {
            try await checkComposer(app: app, root: root, window: window, navigationCheck: CommandLine.arguments[2] == "navigation")
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

    @MainActor private static func checkAttachment(app: NSRunningApplication, root: AXUIElement, window: AXUIElement) async throws {
        func labels(_ element: AXUIElement) -> [String] {
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { string(element, $0) }
        }
        func buttons(_ element: AXUIElement) -> [AXUIElement] {
            descendants(element).filter { string($0, kAXRoleAttribute) == "AXButton" }
        }
        func removals() -> [AXUIElement] { buttons(window).filter { labels($0).contains("移除该图片") } }
        func picker() -> AXUIElement? {
            descendants(root).first { element in
                guard ["AXWindow", "AXSheet", "AXDialog"].contains(string(element, kAXRoleAttribute)), !CFEqual(element, window) else { return false }
                let names = buttons(element).flatMap(labels)
                return names.contains("Cancel") || names.contains("取消")
            }
        }
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<50 {
                if condition() { print("PASS: \(message)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure(message: message)
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) async throws {
            try require(app.isActive && picker() != nil, "键盘事件仅限目标App文件面板")
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw Failure(message: "无法创建事件") }
                event.flags = flags
                event.postToPid(app.processIdentifier)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let editors = descendants(window).filter { string($0, kAXRoleAttribute) == "AXTextArea" }
        guard editors.count == 1, let editor = editors.first,
              let send = buttons(window).first(where: { labels($0).contains("发送消息") }),
              let add = buttons(window).first(where: { labels($0).contains { $0.hasPrefix("添加图片") } }) else {
            throw Failure(message: "缺少唯一普通会话输入或附件按钮")
        }
        try require(string(editor, kAXValueAttribute).isEmpty && attribute(send, kAXEnabledAttribute) as? Bool == false
                    && removals().isEmpty && picker() == nil, "输入和附件为空，无现有文件面板")
        let directory = URL(fileURLWithPath: "/private/tmp/newpi-ui").appendingPathComponent("attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("NewPi-acceptance-only.png")
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let data = bitmap.bitmapData else { throw Failure(message: "生成图片失败") }
        for y in 0..<160 { for x in 0..<320 {
            let offset = y * bitmap.bytesPerRow + x * 4
            data[offset] = UInt8(x % 256); data[offset + 1] = UInt8(y); data[offset + 2] = 96; data[offset + 3] = 255
        } }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG编码失败") }
        try png.write(to: file)
        app.activate(options: [])
        try await wait("目标App已激活") { app.isActive }
        var selectedFixture = false
        do {
            // runModal 期间 AXPress 可能返回 cannotComplete；以实际面板出现作为后置断言。
            print("ATTACHMENT OPEN AXResult=\(AXUIElementPerformAction(add, kAXPressAction as CFString).rawValue)")
            try await wait("系统文件选择面板打开") { picker() != nil }
            try await key(5, flags: [.maskCommand, .maskShift]) // ⌘⇧G，绝不操作主输入框。
            var pathField: AXUIElement?
            try await wait("文件面板前往路径输入框获得焦点") {
                guard let focused = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
                let field = focused as! AXUIElement
                guard ["AXTextField", "AXComboBox"].contains(string(field, kAXRoleAttribute)),
                        picker() != nil, !CFEqual(field, editor) else { return false }
                pathField = field
                return true
            }
            guard let pathField else { throw Failure(message: "无路径输入框") }
            try require(AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, file.path as CFString) == .success, "选择测试PNG的完整路径")
            try await key(36) // Return 仅用于已确认的文件面板路径框。
            try await Task.sleep(for: .milliseconds(350))
            guard let panel = picker(), let open = buttons(panel).first(where: {
                labels($0).contains { ["Open", "打开", "Choose", "选择"].contains($0) }
                    && attribute($0, kAXEnabledAttribute) as? Bool == true
            }) else { throw Failure(message: "未找到可用的文件打开按钮") }
            selectedFixture = true
            try require(AXUIElementPerformAction(open, kAXPressAction as CFString) == .success, "文件面板确认选择（不发送消息）")
            try await wait("测试附件缩略图的移除按钮出现") { picker() == nil && removals().count == 1 }
            try require(attribute(send, kAXEnabledAttribute) as? Bool == true && string(editor, kAXValueAttribute).isEmpty,
                        "仅图片草稿使发送启用，文本保持为空")
            guard let remove = removals().first else { throw Failure(message: "缺少移除按钮") }
            try require(AXUIElementPerformAction(remove, kAXPressAction as CFString) == .success, "真实移除图片按钮接受点击")
            try await wait("附件清理完成，发送重新禁用") { removals().isEmpty && attribute(send, kAXEnabledAttribute) as? Bool == false }
            selectedFixture = false
            // 再打开并取消，验证取消路径不会创建草稿。
            print("ATTACHMENT REOPEN AXResult=\(AXUIElementPerformAction(add, kAXPressAction as CFString).rawValue)")
            try await wait("取消检查的文件面板可见") { picker() != nil }
            guard let panel = picker(), let cancel = buttons(panel).first(where: { labels($0).contains { ["Cancel", "取消"].contains($0) } }) else { throw Failure(message: "缺少取消按钮") }
            try require(AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success, "文件面板取消")
            try await wait("取消后无新增附件") { picker() == nil && removals().isEmpty && attribute(send, kAXEnabledAttribute) as? Bool == false }
        } catch {
            if let panel = picker(), let cancel = buttons(panel).first(where: { labels($0).contains { ["Cancel", "取消"].contains($0) } }) {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            }
            if selectedFixture, removals().count == 1, let remove = removals().first {
                _ = AXUIElementPerformAction(remove, kAXPressAction as CFString)
            }
            throw error
        }
        try require(string(editor, kAXValueAttribute).isEmpty, "结束后文本仍为空")
        print("PASS: 正式App测试PNG选择/移除/取消；未发送、未读剪贴板。不是拖放或发送后预览验收")
    }

    @MainActor private static func checkComposer(app: NSRunningApplication, root: AXUIElement, window: AXUIElement, navigationCheck: Bool = false) async throws {
        func controls() -> [AXUIElement] { descendants(window) }
        func named(_ name: String) -> AXUIElement? {
            controls().first { string($0, kAXDescriptionAttribute) == name }
        }
        let editors = controls().filter { string($0, kAXRoleAttribute) == "AXTextArea" }
        try require(editors.count == 1, "只有一个输入框，避免误操作保活的隐藏面板")
        guard var editor = editors.first, let model = named("模型与思考级别"), var send = named("发送消息") else {
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
        var returnToSession: AXUIElement?
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
            if let original = returnToSession {
                guard AXUIElementPerformAction(original, kAXPressAction as CFString) == .success else {
                    throw Failure(message: "无法返回原Session，保留其测试草稿，不清理其他输入")
                }
                try await wait("清理前已返回原Session") { attribute(original, kAXSelectedAttribute) as? Bool == true && named("模型与思考级别") != nil }
                guard let restored = controls().first(where: { string($0, kAXRoleAttribute) == "AXTextArea" }), let restoredSend = named("发送消息") else {
                    throw Failure(message: "返回后缺少输入框，保留测试草稿")
                }
                editor = restored
                send = restoredSend
                returnToSession = nil
            }
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
            if navigationCheck {
                guard let nav = named("工作区导航") else { throw Failure(message: "缺少导航区") }
                let buttons = descendants(nav).filter { string($0, kAXRoleAttribute) == "AXButton" }
                let selected = buttons.filter { attribute($0, kAXSelectedAttribute) as? Bool == true }
                try require(selected.count == 1, "原会话唯一选中，可安全返回")
                guard let original = selected.first else { throw Failure(message: "缺少原会话") }
                let rooms = buttons.filter { button in
                    let texts = descendants(button).flatMap { [string($0, kAXValueAttribute), string($0, kAXDescriptionAttribute), string($0, kAXHelpAttribute)] }
                    return frame(button).height > 40 && frame(nav).contains(frame(button))
                        && !texts.contains { $0.contains("条消息") }
                        && texts.contains { value in ["讨论", "投票", "执行", "评审", "完成"].contains { value.contains($0) } }
                }
                guard let target = rooms.first else { throw Failure(message: "没有可唯一定位类型的可见聊天室行，不猜坐标") }
                let originalEditor = editor
                returnToSession = original
                try require(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success, "选择真实聊天室条目（不发言）")
                try await wait("聊天室详情实际显示") { named("聊天室操作") != nil && named("模型与思考级别") == nil }
                try require(AXUIElementPerformAction(original, kAXPressAction as CFString) == .success, "选择原Session条目")
                try await wait("原Session重新显示") { attribute(original, kAXSelectedAttribute) as? Bool == true && named("模型与思考级别") != nil }
                let restoredEditors = controls().filter { string($0, kAXRoleAttribute) == "AXTextArea" }
                try require(restoredEditors.count == 1, "返回后只有原Session输入框")
                guard let restored = restoredEditors.first, let restoredSend = named("发送消息") else { throw Failure(message: "缺少恢复输入框") }
                editor = restored
                send = restoredSend
                returnToSession = nil
                try await wait("正式Session→聊天室→Session：非空草稿恢复") { string(editor, kAXValueAttribute) == marker }
                try require(!CFEqual(originalEditor, editor), "输入框确实重建，不是原实例隐藏再显示")
                try focusEditor()
                try await wait("重建后输入框获得焦点") { isEditorFocused() }
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
            // 跨类型导航会重建菜单，不能拿已卸载的 AX 对象校验当前模型。
            try require(named("模型与思考级别").map { string($0, kAXValueAttribute) } == modelBefore,
                        "当前模型与思考级别未改变")
        } catch {
            try await cleanup()
            throw error
        }
        try await cleanup()
        print("PASS: 正式 App 非空草稿、侧栏、菜单 Escape 与续写；未发送、未改模型、未访问剪贴板")
    }
}