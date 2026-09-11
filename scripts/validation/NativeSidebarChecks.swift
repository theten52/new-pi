import AppKit
import ApplicationServices

// 授权后对已运行的 Debug App 做窄范围验收；不启动会话、不写草稿、不遍历 Web 正文。
// swiftc -parse-as-library 本文件 -o 临时可执行文件；参数为 App 路径和 inspect/check。
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
        guard string(element, kAXRoleAttribute) != "AXWebArea" else { return }
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
              ["inspect", "check"].contains(CommandLine.arguments[2]) else {
            throw Failure(message: "参数：指定 NewPi.app 路径 inspect|check")
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
}