import AppKit
import Combine
import NewPiCore
import SwiftUI

// 只替换外部状态与回调；真实视图、草稿、输入框及接线由脚本提取。
// 不创建 AgentSession，不访问用户存储、凭据、剪贴板，不执行任何工具。
@MainActor enum ActionFrames {
    static var values: [String: CGRect] = [:]
    static weak var coordinateView: NSView?
}

// 原生坐标锚点不拦截事件；SwiftUI 命名空间中的几何只能通过同空间锚点转换。
private struct ActionCoordinateView: NSViewRepresentable {
    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        ActionFrames.coordinateView = view
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {}
}

@MainActor final class SuggestionRuntimeFixture {
    let composerDraft = NewPiComposerDraft()
    var transcript: [String] = []
}

@MainActor final class SuggestionVMFixture: ObservableObject {
    @Published var projectURL: URL? = URL(fileURLWithPath: "/fixture/not-read")
    @Published var isSwitchingSession = false
    var sessionSwitchGeneration = 0
    var activeRuntime: SuggestionRuntimeFixture?
    var starts = 0
    var afterStart: (() -> Void)?
    func startNewSession() async {
        starts += 1
        sessionSwitchGeneration += 1
        await Task.yield()
        activeRuntime = SuggestionRuntimeFixture()
        afterStart?()
    }
}

@MainActor final class ApprovalRuntimeFixture: ObservableObject {
    @Published var pendingToolApproval: ToolApprovalRequest?
}

@MainActor final class ApprovalVMFixture: ObservableObject {
    let runtime: ApprovalRuntimeFixture
    var active = true
    var decisions: [ApprovalDecision] = []
    var pendingToolApproval: ToolApprovalRequest? { runtime.pendingToolApproval }
    init(_ runtime: ApprovalRuntimeFixture) { self.runtime = runtime }
    func isActiveRuntime(_ candidate: ApprovalRuntimeFixture) -> Bool { active && runtime === candidate }
    // 故意不移除卡片，验证组件 responded 锁，而不是靠父级消失掩盖双击。
    func approvePendingTool(scope: ApprovalScope) { decisions.append(.init(approved: true, scope: scope)) }
    func denyPendingTool() { decisions.append(.deny) }
}

@MainActor final class RoomApprovalManagerFixture: ObservableObject {
    struct Pending: Identifiable {
        let request: ToolApprovalRequest
        let roleName = "测试角色 · 很长的名称"
        var id: String { request.id }
    }
    @Published var pendingApprovals: [Pending] = []
    var decisions: [ApprovalDecision] = []
    func approve(id: String, scope: ApprovalScope) { decisions.append(.init(approved: true, scope: scope)) }
    func reject(id: String) { decisions.append(.deny) }
}

struct RoomRuntimeFixture {
    let chatroom = ChatRoom(name: "固定聊天室 · 超长名称仅用于布局测试",
        projectPath: "/fixture/" + String(repeating: "long-directory/", count: 12))
}

// 兼容组件的独立测试容器，不是正式 SessionPanel/RoomDetail 的审批布局。
// 原有请求/运行实例守卫保留；正式 WK 路由由 TranscriptActionsBridgeChecks 验证。
private struct SessionApprovalFixture: View {
    @ObservedObject var runtime: ApprovalRuntimeFixture
    @ObservedObject var viewModel: ApprovalVMFixture
    var body: some View {
        if let request = runtime.pendingToolApproval, viewModel.isActiveRuntime(runtime) {
            NewPiApprovalContent(request: request, isInline: true) { decision in
                guard viewModel.isActiveRuntime(runtime), runtime.pendingToolApproval?.id == request.id,
                      viewModel.pendingToolApproval?.id == request.id else { return }
                if decision.approved { viewModel.approvePendingTool(scope: decision.scope) }
                else { viewModel.denyPendingTool() }
            }
            .id(request.id)
            .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
            .padding(.vertical, 6)
            .frame(maxWidth: NewPiWorkbenchStyle.maxReadingWidth)
        }
    }
}

private struct RoomApprovalFixture: View {
    @ObservedObject var approvalManager: RoomApprovalManagerFixture
    let runtime: RoomRuntimeFixture
    var body: some View {
        if let approval = approvalManager.pendingApprovals.first {
            NewPiApprovalContent(request: approval.request,
                chatroom: .init(name: runtime.chatroom.name,
                    role: approval.roleName.isEmpty ? "未知角色" : approval.roleName,
                    directory: runtime.chatroom.projectPath), isInline: true) { decision in
                guard approvalManager.pendingApprovals.first?.id == approval.id else { return }
                if decision.approved { approvalManager.approve(id: approval.id, scope: decision.scope) }
                else { approvalManager.reject(id: approval.id) }
            }
            .id(approval.id)
            .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
            .padding(.vertical, 6)
            .frame(maxWidth: NewPiWorkbenchStyle.maxReadingWidth)
        }
    }
}

@MainActor final class ActionModel: ObservableObject {
    let draft = NewPiComposerDraft()
    let suggestionVM = SuggestionVMFixture()
    let runtime = ApprovalRuntimeFixture()
    let roomManager = RoomApprovalManagerFixture()
    lazy var approvalVM = ApprovalVMFixture(runtime)
    @Published var mode = 0 // 0 已有会话建议，1 初始建议，2 Session 审批，3 Room 审批。
    var submissions = 0
}

private struct ActionRoot: View {
    @ObservedObject var model: ActionModel
    @ObservedObject var draft: NewPiComposerDraft
    var body: some View {
        VStack(spacing: 0) {
            if model.mode == 0 {
                SessionSuggestionFixture(draft: draft, viewModel: model.suggestionVM)
            } else if model.mode == 1 {
                InitialSuggestionFixture(viewModel: model.suggestionVM)
            } else {
                Spacer(minLength: 0)
                if model.mode == 2 {
                    SessionApprovalFixture(runtime: model.runtime, viewModel: model.approvalVM)
                } else {
                    RoomApprovalFixture(approvalManager: model.roomManager, runtime: RoomRuntimeFixture())
                }
            }
            NewPiComposerTextView(text: $draft.text, onSubmit: { model.submissions += 1 })
                .frame(height: NewPiComposerScrollView.fixedHeight)
                .padding(24)
        }
        .background(NewPiWorkbenchStyle.surface)
        .coordinateSpace(name: "actions")
        .background(ActionCoordinateView())
    }
}

@main @MainActor struct WorkbenchActionsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Unavailable: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static var failures = 0
    static var skips = 0

    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        passed += 1
        print("PASS: \(label)")
    }
    static func group(_ name: String, _ body: () async throws -> Void) async {
        print("CASE: \(name)")
        do { try await body() }
        catch let error as Unavailable { skips += 1; print("SKIP: \(name): \(error)") }
        catch { failures += 1; print("FAIL: \(name): \(error)") }
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }
    static func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }

    static func main() {
        let previous = NSWorkspace.shared.frontmostApplication
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        Task { @MainActor in
            await group("fillSuggestedDraft 独立守卫") {
                try await checkSuggestionGuards(DraftImageAttachment(data: Data([1, 2, 3]),
                    displayName: "memory-only.png", mediaType: "image/png"))
            }
            await group("独立原生窗口") { try await run() }
            print("LIMIT: 审批仅兼容原生组件，不是正式 WK 正文接线；未启动完整用户 App；发送/会话创建/审批后端为内存 fake；不验证持久授权、模型、VoiceOver、像素对比或完整工作台布局。")
            print("SUMMARY: PASS=\(passed) FAIL=\(failures) SKIP=\(skips)")
            previous?.activate(options: [])
            exit(failures > 0 ? 1 : (skips > 0 ? 2 : 0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            NSApp.windows.forEach { $0.orderOut(nil) }
            previous?.activate(options: [])
            print("FAIL: 原生交互超时 120s")
            exit(1)
        }
        NSApp.run()
    }

    static func frame(_ key: String, host: NSView) throws -> CGRect {
        guard let value = ActionFrames.values[key] else { throw Unavailable(description: "缺少真实按钮几何：\(key)") }
        try require(value.width > 12 && value.height > 12 && host.bounds.insetBy(dx: -1, dy: -1).contains(value),
            "\(key) 实测可达边界 \(value)，视口 \(host.bounds.size)")
        return value
    }

    // 事件只排入本进程指定 NSWindow；不使用全局鼠标、AX 授权或直接业务回调。
    static func click(_ key: String, host: NSView, window: NSWindow, twice: Bool = false) async throws {
        if !window.isKeyWindow || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            try await settle()
        }
        let rect = try frame(key, host: host)
          guard let anchor = ActionFrames.coordinateView else { throw Unavailable(description: "缺少原生坐标锚点") }
          let point = anchor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard window.isKeyWindow, let root = window.contentView,
              root.hitTest(root.superview?.convert(point, from: nil) ?? point) != nil else {
            throw Unavailable(description: "窗口未获焦点或鼠标无命中，不能验证 \(key)，active=\(NSApp.isActive) key=\(window.isKeyWindow) point=\(point)")
        }
          let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                print("MOUSE: \(key) local=\(rect) window=\(point) flipped=\(host.isFlipped) hit=\(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        for count in 1...(twice ? 2 : 1) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw Unavailable(description: "无法生成鼠标事件")
                }
                // 两事件都先排队，避免 mouseDown 的原生 tracking loop 等不到 mouseUp。
                NSApp.postEvent(event, atStart: false)
            }
        }
        try await settle()
    }

    static func run() async throws {
        guard !NSScreen.screens.isEmpty else { throw Unavailable(description: "无图形桌面") }
        let model = ActionModel()
        let host = NSHostingView(rootView: ActionRoot(model: model, draft: model.draft))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 620, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NewPi · 安全组件交互测试（无模型）"
        window.contentView = host
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await settle()
        let activated = NSRunningApplication.current.activate(options: [])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        for _ in 0..<40 {
            if window.isKeyWindow { break }
            try await settle()
        }
        print("FOCUS: accepted=\(activated) active=\(NSApp.isActive) launched=\(NSRunningApplication.current.isFinishedLaunching) key=\(window.isKeyWindow) visible=\(window.isVisible)")
        guard window.isKeyWindow else { throw Unavailable(description: "独立窗口未获焦点") }
        try require(host.window === window && window.isVisible, "实际 NSHostingView/AppKit 窗口已挂载")
        func editor() throws -> NewPiComposerInnerTextView {
            guard let result = descendants(host).compactMap({ $0 as? NewPiComposerInnerTextView }).first else {
                throw Failure(description: "生产 NSTextView 未挂载")
            }
            return result
        }
        func type(_ text: String) async throws {
            let input = try editor()
            try require(window.makeFirstResponder(input), "生产 NSTextView 成为 first responder")
            input.setSelectedRange(NSRange(location: 0, length: (input.string as NSString).length))
            input.insertText(text, replacementRange: input.selectedRange())
            try await settle()
            try require(input.string == text && model.draft.text == text, "真实编辑同步到生产草稿")
        }
        let suggestions = NewPiChatEmptyStateView.suggestions
        try require(suggestions.count == 3, "恰好三条生产建议")
        let image = DraftImageAttachment(data: Data([1, 2, 3]), displayName: "memory-only.png", mediaType: "image/png")
        for width in [620, 360] {
            for dark in [false, true] {
                let name = "\(width)pt/\(dark ? "dark" : "light")"
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 720))
                model.mode = 0
                try await settle()
                await group("建议点击 \(name)") {
                    try require(abs(host.bounds.width - CGFloat(width)) < 1
                        && host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua),
                        "窗口实际宽度/外观匹配 \(name)")
                    for suggestion in suggestions {
                        try await type("")
                        let submissions = model.submissions
                        try await click(suggestion.title, host: host, window: window)
                        try require(model.draft.text == suggestion.prompt && (try editor()).string == suggestion.prompt,
                            "真实点击 \(suggestion.title) → 正确提示词与 NSTextView")
                        try require(model.submissions == submissions, "建议点击不触发 onSubmit")
                    }
                }
            }
        }
        await group("文本/空白/附件保护") {
            model.mode = 0
            for text in ["已有草稿", " ", "\n\t "] {
                try await type(text)
                for suggestion in suggestions {
                    try await click(suggestion.title, host: host, window: window)
                    try require(model.draft.text == text && (try editor()).string == text, "点击不覆盖已有文本（含纯空白）")
                    try require(!model.draft.fillSuggestion(suggestion.prompt), "生产 draft 守卫拒绝覆盖")
                }
            }
            try await type("")
            model.draft.attachments = [image]
            try await settle()
            for suggestion in suggestions {
                try await click(suggestion.title, host: host, window: window)
                try require(model.draft.text.isEmpty && model.draft.attachments == [image], "附件草稿不可被建议覆盖")
                try require(!model.draft.fillSuggestion(suggestion.prompt), "附件保护不只依赖 disabled UI")
            }
            model.draft.attachments = []
            try require(!model.draft.fillSuggestion(""), "空提示词不填稿")
            try require(model.submissions == 0, "全部建议/保护测试无提交")
        }
        await group("初始建议点击 → 提取的 fillSuggestedDraft") {
            model.mode = 1
            for suggestion in suggestions {
                model.suggestionVM.activeRuntime = nil
                let starts = model.suggestionVM.starts
                try await settle()
                try await click(suggestion.title, host: host, window: window)
                try require(model.suggestionVM.starts == starts + 1
                    && model.suggestionVM.activeRuntime?.composerDraft.text == suggestion.prompt,
                    "真实初始按钮触发异步创建 fake 并正确填稿：\(suggestion.title)")
            }
            try require(model.submissions == 0, "初始建议无提交")
        }
        for width in [620, 360] {
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: width, height: 720))
                for room in [false, true] {
                    model.mode = room ? 3 : 2
                    for risk in [ToolDangerLevel.low, .medium, .high] {
                        let name = "\(width)/\(dark ? "dark" : "light")/\(room ? "room" : "session")/\(risk)"
                        await group("审批兼容组件（非正文接线） \(name)") {
                            try await checkApproval(model, host: host, window: window, risk: risk, room: room)
                        }
                    }
                }
            }
        }
    }

    static func checkSuggestionGuards(_ image: DraftImageAttachment) async throws {
        for blocked in ["no-project", "switching"] {
            let vm = SuggestionVMFixture()
            if blocked == "no-project" { vm.projectURL = nil } else { vm.isSwitchingSession = true }
            await vm.fillSuggestedDraft("建议")
            try require(vm.starts == 0 && vm.activeRuntime == nil, "\(blocked) 不创建/填稿")
        }
        for text in ["", "已有草稿", " \n"] {
            for attachment in [false, true] {
                let vm = SuggestionVMFixture()
                let runtime = SuggestionRuntimeFixture()
                vm.activeRuntime = runtime
                runtime.composerDraft.text = text
                runtime.composerDraft.attachments = attachment ? [image] : []
                await vm.fillSuggestedDraft("建议")
                try require(vm.starts == 0 && runtime.composerDraft.text == (text.isEmpty && !attachment ? "建议" : text)
                    && runtime.composerDraft.attachments == (attachment ? [image] : []), "已有 runtime 精确保护文本与附件")
            }
        }
        for change in ["project", "generation", "transcript", "missing", "typed", "attachment"] {
            let vm = SuggestionVMFixture()
            vm.afterStart = { [unowned vm] in
                switch change {
                case "project": vm.projectURL = URL(fileURLWithPath: "/fixture/other")
                case "generation": vm.sessionSwitchGeneration += 1
                case "transcript": vm.activeRuntime?.transcript = ["不读取真实历史"]
                case "missing": vm.activeRuntime = nil
                case "typed": vm.activeRuntime?.composerDraft.text = "创建期间输入"
                default: vm.activeRuntime?.composerDraft.attachments = [image]
                }
            }
            await vm.fillSuggestedDraft("过期建议")
            try require(vm.starts == 1 && vm.activeRuntime?.composerDraft.text != "过期建议", "异步创建后 \(change) 不回填过期建议")
        }
    }

    // SwiftUI 菜单在 performClick 时才构造，不能把尚未弹出的占位 NSMenu 当实际内容。
    @MainActor final class MenuCapture: NSObject {
        var menu: NSMenu?
        @objc func beganTracking(_ notification: Notification) { menu = notification.object as? NSMenu }
    }
    static func openedMenu(_ provider: NSPopUpButton) throws -> NSMenu {
        let capture = MenuCapture()
        NotificationCenter.default.addObserver(capture, selector: #selector(MenuCapture.beganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        // performClick 可能同步进入 tracking loop；定时器加入 tracking 模式，确定性关闭本测试菜单。
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                capture.menu?.cancelTracking()
                provider.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); NotificationCenter.default.removeObserver(capture) }
        provider.performClick(nil)
        guard let menu = capture.menu, !menu.items.isEmpty else {
            throw Unavailable(description: "performClick 后未捕获实际 NSMenu 跟踪内容，不能验证 scope")
        }
        print("PROVIDER: NSPopUpButton.performClick 实际打开菜单，NSMenu didBeginTracking 已捕获")
        return menu
    }

    static func checkApproval(_ model: ActionModel, host: NSView, window: NSWindow,
                              risk: ToolDangerLevel, room: Bool) async throws {
        func decisions() -> [ApprovalDecision] { room ? model.roomManager.decisions : model.approvalVM.decisions }
        func request() async throws {
            ActionFrames.values = [:]
            let value = ToolApprovalRequest(id: UUID().uuidString, toolName: "bash", arguments: .object([:]),
                summary: "仅显示的命令（绝不执行）\n" + String(repeating: "long-argument ", count: 50),
                dangerLevel: risk, dangerReason: String(repeating: "合成风险提示。", count: 20))
            if room { model.roomManager.pendingApprovals = [.init(request: value)] }
            else { model.runtime.pendingToolApproval = value }
            try await settle()
        }
        func menuProvider() throws -> NSPopUpButton? {
            let candidates = descendants(host).compactMap { $0 as? NSPopUpButton }.filter { $0.menu != nil }
            guard candidates.count <= 1 else { throw Unavailable(description: "多个原生菜单 provider，无法唯一定位") }
            return candidates.first
        }
        try await request()
        print("NATIVE BUTTONS: \(descendants(host).compactMap { view -> String? in guard let b = view as? NSButton else { return nil }; return "\(b.title):\(host.convert(b.bounds, from: b))" })")
        _ = try frame("once", host: host)
        _ = try frame("deny", host: host)
        guard let editor = descendants(host).compactMap({ $0 as? NewPiComposerInnerTextView }).first else {
            throw Failure(description: "审批下方缺少实际 composer")
        }
        let editorFrame = host.convert(editor.visibleRect, from: editor)
        try require(editorFrame.height > 30 && host.bounds.contains(editorFrame)
            && (ActionFrames.values["once"]?.maxY ?? .infinity) < editorFrame.minY,
            "测试容器中的兼容审批组件与实际 NSTextView 均可达（非正式正文布局）")
        try require(window.makeFirstResponder(editor), "审批存在时真实草稿获取焦点")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("审批期间的草稿", replacementRange: editor.selectedRange())
        try await settle()
        let prior = decisions().count
        let submissions = model.submissions
        for (code, characters) in [(UInt16(36), "\r"), (UInt16(76), "\r"), (UInt16(53), "\u{1b}")] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                    throw Unavailable(description: "无法创建键盘事件")
                }
                NSApp.sendEvent(event)
            }
        }
        try await settle()
        try require(decisions().count == prior && model.submissions == submissions + 2
            && model.draft.text == "审批期间的草稿" && editor.string == model.draft.text,
            "Return/Enter 到真实 composer，Escape 不拒绝；审批零响应且草稿保留")
        if risk == .high {
            try require(ActionFrames.values["remember"] == nil && (try menuProvider()) == nil, "high 无 remember 菜单/provider")
        } else {
            _ = try frame("remember", host: host)
        }
        try await click("once", host: host, window: window, twice: true)
        try require(decisions().count == prior + 1 && decisions().last == .allowOnce, "真实双击允许一次：scope=once，responded 只回调一次")
        try await click("deny", host: host, window: window)
        try require(decisions().count == prior + 1, "responded 后拒绝不能再次回调")
        // 不替换根 hosting view；只换生产 request id，应重置 @State responded。
        try await request()
        try await click("deny", host: host, window: window, twice: true)
        try require(decisions().count == prior + 2 && decisions().last == .deny, "第二 request id 重置锁；真实双击拒绝仅一次")
        guard risk != .high else { return }
        for scope in (room ? [ApprovalScope.session] : [.session, .forever]) {
            try await request()
            guard let provider = try menuProvider() else {
                throw Unavailable(description: "SwiftUI Menu 未暴露 NSPopUpButton/NSMenu provider；scope 选择未验证")
            }
            let menu = try openedMenu(provider)
            let titles = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty }.map(\.title)
            print("MENU: pullsDown=\(provider.pullsDown) items=\(menu.items.map { "\($0.title)[hidden=\($0.isHidden),action=\($0.action != nil)]" })")
            let session = room ? "本聊天室内允许 bash" : "本对话中不再询问 bash"
            let expected = room ? [session] : [session, "一直允许 bash"]
            try require(titles == expected, "真实 NSMenu 项精确匹配 \(expected)，实际 \(titles)")
            let title = scope == .session ? session : "一直允许 bash"
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                throw Failure(description: "缺少菜单项 \(title)")
            }
            let item = menu.items[index]
            try require(provider.isEnabled && item.isEnabled && item.action != nil && item.target != nil,
                "NSMenuItem 有真实可用 target/action：\(title)")
            let count = decisions().count
            // 公开 AppKit provider 触发真实 SwiftUI 菜单动作；不调用 onDecision 或 respond。
            menu.performActionForItem(at: index)
            menu.performActionForItem(at: index)
            try await settle()
            try require(decisions().count == count + 1 && decisions().last == .init(approved: true, scope: scope),
                "NSMenu.performActionForItem → \(scope) 精确一次（菜单双触发 latch）")
        }
    }
}