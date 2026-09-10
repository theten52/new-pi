import AppKit
import NewPiCore
import SwiftUI

/// 真实共用审批组件，无模型/工具调用。由外部 Accessibility 检查按钮和菜单。
@main
struct ApprovalUIProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let mode = CommandLine.arguments[1]
        let request = ToolApprovalRequest(id: "ui-probe", toolName: "bash", arguments: .object([:]),
            summary: "swift test --scratch-path /tmp/newpi-tests\n" + String(repeating: "long command argument ", count: 15),
            dangerLevel: mode == "high" ? .high : .medium,
            dangerReason: mode == "high" ? "测试高风险提示：每次都需要确认" : "执行测试命令")
        let room: NewPiApprovalContent.ChatRoomContext? = mode == "session" ? nil : .init(
            name: "聊天室授权测试：包含较长名称的独立工作目录", role: "测试员 / 模型 B",
            directory: "/Users/example/projects/independent-chatroom-with-a-long-directory-name/src/integration-tests")
        let view = NewPiApprovalContent(request: request, chatroom: room) { decision in
            let expected: ApprovalScope = mode == "session" ? .forever : (mode == "high" ? .once : .session)
            precondition(decision.approved && decision.scope == expected)
            print("PASS UI \(mode): \(decision.scope)")
            exit(0)
        }
        let window = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 520, height: 570),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Approval UI Probe"
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["NEWPI_UI_DARK"] == "1" ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 520, height: 570))
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        print("PID=\(getpid()) WINDOW=\(window.windowNumber)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("FAIL: UI timeout"); exit(1) }
        withExtendedLifetime(window) { NSApp.run() }
    }
}
