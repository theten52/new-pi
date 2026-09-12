import AppKit
import SwiftUI
import ScreenCaptureKit

// 仅创建内存 fixture 和组件窗口。没有 AgentSession、用户存储、真实 App 或网络。
@MainActor private final class UsageFixture: ObservableObject {
    @Published var data = NewPiUsageDialogData(
        usageText: "↑28,601 ↓7,809", lastTurnUsageText: "↑3,207 ↓918",
        cacheHitRateText: "73%", contextText: "上下文 18% / 128k", tokenRateText: "31 tok/s",
        lastTurnInputTokens: 3207, lastTurnOutputTokens: 918)
    var sends = 0
    var stops = 0
    var switches = 0
    var ticks = 0
    var draft = "仅供合成测试的草稿，不应因用量窗口改变。"
}

private struct UsageBarFixture: View {
    @ObservedObject var model: UsageFixture
    var body: some View {
        NewPiAgentStatusBar(
            presentation: .init(systemImage: "text.append", label: "正在生成 · 合成测试", isActive: true),
            usageText: model.data.usageText, lastTurnUsageText: model.data.lastTurnUsageText,
            cacheHitRateText: model.data.cacheHitRateText, contextText: model.data.contextText,
            tokenRateText: model.data.tokenRateText, lastTurnInputTokens: model.data.lastTurnInputTokens,
            lastTurnOutputTokens: model.data.lastTurnOutputTokens)
    }
}

@MainActor private final class UsageFixtureContent: NSView, NSTextViewDelegate {
    let model: UsageFixture
    let editor = NSTextView()
    let status: NSHostingView<UsageBarFixture>
    let prose = NSTextField(wrappingLabelWithString: "用量窗口 · 独立组件验证\n\n这是本地合成的正文，不来自任何用户会话。\n\n对话框应在整个内容区居中，正文和输入区不移动。\n\n后台生成计数在用量窗口打开期间继续推进。")
    let send = NSButton(title: "发送（测试计数）", target: nil, action: nil)
    let stop = NSButton(title: "停止（测试计数）", target: nil, action: nil)
    let switchSession = NSButton(title: "切会话（测试计数）", target: nil, action: nil)
    override var isFlipped: Bool { true }

    init(model: UsageFixture) {
        self.model = model
        status = NSHostingView(rootView: UsageBarFixture(model: model))
        super.init(frame: .zero)
        status.sizingOptions = []
        prose.font = .systemFont(ofSize: 18)
        editor.string = model.draft
        editor.font = .systemFont(ofSize: 15)
        editor.isRichText = false
        editor.delegate = self
        editor.setAccessibilityIdentifier("usage.fixture.editor")
        for view in [prose, editor, status, send, stop, switchSession] { addSubview(view) }
        send.target = self; send.action = #selector(didSend)
        stop.target = self; stop.action = #selector(didStop)
        switchSession.target = self; switchSession.action = #selector(didSwitch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func didSend() { model.sends += 1 }
    @objc private func didStop() { model.stops += 1 }
    @objc private func didSwitch() { model.switches += 1 }
    func textDidChange(_ notification: Notification) { model.draft = editor.string }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(NewPiWorkbenchStyle.surface).setFill(); bounds.fill()
    }
    override func layout() {
        super.layout()
        prose.frame = NSRect(x: 28, y: 28, width: bounds.width - 56, height: max(40, bounds.height - 280))
        status.frame = NSRect(x: 24, y: bounds.height - 218, width: bounds.width - 48, height: 36)
        editor.frame = NSRect(x: 28, y: bounds.height - 170, width: bounds.width - 56, height: 98)
        send.frame = NSRect(x: 24, y: bounds.height - 50, width: 150, height: 30)
        stop.frame = NSRect(x: 184, y: bounds.height - 50, width: 150, height: 30)
        switchSession.frame = NSRect(x: 344, y: bounds.height - 50, width: 170, height: 30)
    }
}

@main @MainActor struct UsageDialogChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Unavailable: Error, CustomStringConvertible { let description: String }
    private static var unavailable: [String] = []
    private static var passes = 0
    private static let output = URL(fileURLWithPath: "/private/tmp/newpi-ui", isDirectory: true)

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        Task { @MainActor in
            do {
                try await run()
                print("SUMMARY: PASS=\(passes) FAIL=0 SKIP=\(unavailable.count)")
                if !unavailable.isEmpty {
                    unavailable.forEach { print("SKIP: \($0)") }
                    exit(2)
                }
                if ProcessInfo.processInfo.environment["NEWPI_USAGE_OPENER_ONLY"] == "1" {
                    print("PASS: usage opener only; full dialog interaction checks not run")
                } else {
                    print("PASS: usage dialog native mouse/keyboard/IME/AX/layout/dynamic data; synthetic windows only")
                }
                exit(0)
            } catch {
                print("FAIL: \(error)")
                print("SUMMARY: PASS=\(passes) FAIL=1 SKIP=\(unavailable.count)")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("FAIL: usage dialog checks timeout"); exit(1)
        }
        NSApp.run()
    }

    private static func run() async throws {
        // 图标小改动只验证按钮，不激活窗口、不申请录屏或运行整套交互截图。
        if ProcessInfo.processInfo.environment["NEWPI_USAGE_OPENER_ONLY"] == "1" {
            let host = NSHostingView(rootView: UsageBarFixture(model: UsageFixture()))
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 36)
            let window = makeWindow(content: host)
            defer { window.close() }
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                try await pause()
                guard let button = find(NewPiUsageOpener.self, in: host), let cell = button.cell else {
                    throw Failure(description: "缺少生产用量按钮")
                }
                try require(button.image != nil && button.imagePosition == .imageLeading, "用量前显示柱状图标")
                try require(button.title == "用量" && button.accessibilityLabel() == "用量", "文字和辅助功能名称不重复图标")
                let imageRect = cell.imageRect(forBounds: button.bounds)
                let titleRect = cell.titleRect(forBounds: button.bounds)
                try require(imageRect.width > 0 && imageRect.height > 0 && button.bounds.contains(imageRect), "图标布局非空且未裁切")
                try require(titleRect.width >= ("用量" as NSString).size(withAttributes: [.font: button.font!]).width
                    && button.bounds.contains(titleRect) && imageRect.maxX <= titleRect.minX, "图标在文字前且标签完整")
                try require(button.presentation.panel == nil, "检查图标不打开弹窗")
            }
            print("PASS: usage opener light/dark layout; no activation, screen capture or global events")
            return
        }
        let zero = NewPiUsageDialogData(lastTurnInputTokens: 0, lastTurnOutputTokens: 0)
        try require(zero.metrics[0].1 == "0" && zero.metrics[1].1 == "0", "明确的零 token 不是未知数据")
        let unknown = NewPiUsageDialogData(usageText: "累计值不能借给本轮", lastTurnInputTokens: -1)
        try require(unknown.metrics[0].1 == "暂无数据" && unknown.metrics[1].1 == "暂无数据",
            "未知/非法 token 不借用累计值，也不伪造原型数字")
        let model = UsageFixture()
        let content = UsageFixtureContent(model: model)
        let window = makeWindow(content: content)
        let decoyContent = UsageFixtureContent(model: UsageFixture())
        let decoy = makeWindow(content: decoyContent)
        decoy.setContentSize(NSSize(width: 260, height: 160))
        defer { window.close(); decoy.close() }
        window.makeKeyAndOrderFront(nil)
        // 独立 CLI 不一定继承终端的前台资格；只激活本探针，不操作任何用户 App。
        let activationAccepted = NSRunningApplication.current.activate(options: [])
        NSApp.activate()
        try await pause()
        window.makeKeyAndOrderFront(nil)
        print("FOCUS: fixture accepted=\(activationAccepted) launched=\(NSRunningApplication.current.isFinishedLaunching) active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) canKey=\(window.canBecomeKey)")
        try await eventually("探针窗口获得焦点") { NSApp.isActive && window.isKeyWindow }
        try await eventually("真实 SwiftUI 状态栏加载原生按钮") { find(NewPiUsageOpener.self, in: content) != nil }
        guard let opener = find(NewPiUsageOpener.self, in: content) else { throw Failure(description: "缺少真实用量按钮") }
        let initial = model.data
        // 独立的异步生成替身：只递增计数，证明未进入阻塞的 App 模态循环/停止回调。
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                if !Task.isCancelled { model.ticks += 1 }
            }
        }
        defer { ticker.cancel() }

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["usage-dialog-new.png", "usage-dialog-900-dark.png", "usage-dialog-620-light.png", "usage-dialog-620-dark.png"] {
            let path = output.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        for width in [900, 620] {
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(NSSize(width: CGFloat(width), height: 760))
                content.layoutSubtreeIfNeeded()
                try await pause()
                for closing in ["close", "backdrop", "escape"] {
                    model.data = initial
                    try await pause()
                    window.makeKeyAndOrderFront(nil)
                    try require(window.makeFirstResponder(content.editor), "打开前原 textview 获取焦点")
                    content.editor.setSelectedRange(NSRange(location: (content.editor.string as NSString).length, length: 0))
                    print("SCENARIO: width=\(width) dark=\(dark) closing=\(closing)")
                    logFrames("before marked", content: content, window: window)
                    // 真实 NSTextInputClient 组合态，不是手工写一个 Boolean 的输入法替身。
                    content.editor.setMarkedText("组合输入", selectedRange: NSRange(location: 4, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
                    let marked = content.editor.markedRange()
                    let selection = content.editor.selectedRange()
                    let text = content.editor.string
                    let draft = model.draft
                    logFrames("after marked immediate", content: content, window: window)
                    try await pause()
                    // NSTextView 默认纵向自适应，组合文本会延后触发 sizeToFit。
                    // 先完成输入自身布局再取打开基线；绝不放宽 overlay 的逐 frame 相等断言。
                    try await eventually("marked text 自身布局已稳定且未打开面板") {
                        !content.needsLayout && !content.editor.needsLayout && opener.presentation.panel == nil
                    }
                    logFrames("after marked idle WITHOUT panel", content: content, window: window)
                    let frames = [content.prose.frame, content.editor.frame, content.status.frame]
                    let originalSubviews = content.subviews
                    let originalNotifications = (content.postsFrameChangedNotifications, content.postsBoundsChangedNotifications)
                    try require(content.editor.hasMarkedText(), "测试前存在真实 marked text")
                    // 另一窗口为 key 时仍只能绑定按钮实际所属窗口，不使用全局 keyWindow。
                    if closing == "close" { decoy.makeKeyAndOrderFront(nil) }
                    try await click(opener)
                    try await eventually("真实鼠标打开用量对话框") { opener.presentation.panel?.isVisible == true }
                    guard let panel = opener.presentation.panel,
                          let backdrop = panel.contentView as? NewPiUsageBackdrop else { throw Failure(description: "无面板内容") }
                    try require(panel.parent === window && (decoy.childWindows ?? []).isEmpty,
                        "面板归属按钮实际窗口；另一个 key window 无子面板")
                    try require((window.childWindows ?? []).filter { $0 is NewPiUsagePanel }.count == 1,
                        "单个 window-local 对话框")
                    try require(panel.firstResponder === backdrop.closeButton && window.firstResponder === content.editor,
                        "对话框焦点在关闭，父 textview 保留 responder")
                    try geometry(backdrop, panel: panel, window: window)
                    logFrames("after panel", content: content, window: window)
                    print("FRAMES baseline: \(frames)")
                    try require([content.prose.frame, content.editor.frame, content.status.frame] == frames,
                        "模态层不挤压正文、输入框或状态栏")
                    try axIsolation(window: window, panel: panel, content: content)
                    try require(allFields(in: backdrop).contains { $0.stringValue == initial.usageText }, "传入累计数据原样展示")
                    let cards = allViews(in: backdrop).compactMap { $0 as? NewPiUsageMetricCard }
                    try require(cards.count == 4 && cards[0].frame.minY == cards[1].frame.minY
                        && cards[0].frame.maxX < cards[1].frame.minX, "四张真实指标卡片为两列")
                    try require(cards[0].valueField.stringValue == 3207.formatted(.number.grouping(.automatic))
                        && cards[1].valueField.stringValue == "918", "输入/输出来自明确最近一轮字段，不冒充累计")

                    if closing == "close" {
                        let name = width == 900 && !dark ? "usage-dialog-new.png"
                            : "usage-dialog-\(width)-\(dark ? "dark" : "light").png"
                        do { try await capture(panel, name: name) }
                        catch let error as Unavailable { unavailable.append(error.description) }
                    }
                    let ticks = model.ticks
                    try await key(0, text: "a", window: panel)
                    try await key(45, text: "n", modifiers: [.command], window: panel)
                    try await key(48, text: "\t", window: panel)
                    try await key(48, text: "\t", modifiers: [.shift], window: panel)
                    // 明确投递到父窗口：不能击穿底层业务按钮。
                    try await click(content.send)
                    try await click(content.stop)
                    try await click(content.switchSession)
                    try require(model.ticks > ticks && model.sends == 0 && model.stops == 0 && model.switches == 0,
                        "后台计数推进；底层鼠标/快捷键不发送、不停止、不切会话")
                    try require(panel.firstResponder === backdrop.closeButton, "Tab / Shift-Tab 焦点不逃逸")

                    model.data.lastTurnOutputTokens = 1201
                    model.data.tokenRateText = "42 tok/s"
                    try await eventually("打开期间真实输入快照动态更新") {
                        allFields(in: backdrop).contains { $0.stringValue == "42 tok/s" }
                    }
                    try require(opener.presentation.panel === panel, "数据更新不重建面板或焦点")
                    try require(cards[1].valueField.stringValue == 1201.formatted(.number.grouping(.automatic)),
                        "动态输出 token 同步更新卡片")
                    model.data = NewPiUsageDialogData(usageText: " \n", contextText: "")
                    try await eventually("七项 unavailable 均展示暂无数据，不残留旧值") {
                        allFields(in: backdrop).filter { $0.stringValue == "暂无数据" }.count == 7
                    }
                    try require(!allFields(in: backdrop).contains { $0.stringValue == initial.usageText }, "empty 不残留累计")
                    try require([content.prose.frame, content.editor.frame, content.status.frame] == frames,
                        "动态数据与空值更新仍不改变父内容 frame")
                    try preserved(content, text: text, draft: draft, marked: marked, selection: selection)
                    switch closing {
                    case "close": try await click(backdrop.closeButton)
                    case "backdrop": try await click(backdrop, point: NSPoint(x: 8, y: 8))
                    default: try await key(53, text: "\u{1b}", window: panel)
                    }
                    try await eventually("\(closing) 关闭且恢复原输入焦点") {
                        opener.presentation.panel == nil && window.isKeyWindow && window.firstResponder === content.editor
                    }
                    try preserved(content, text: text, draft: draft, marked: marked, selection: selection)
                    try require(!content.isAccessibilityHidden() && !(window.accessibilityChildren() ?? []).contains {
                        ($0 as? NSWindow) === panel
                    }, "关闭恢复底层 AX")
                    try require([content.prose.frame, content.editor.frame, content.status.frame] == frames,
                        "三种关闭路径均不改变父内容 frame")
                    try require(content.subviews == originalSubviews
                        && content.postsFrameChangedNotifications == originalNotifications.0
                        && content.postsBoundsChangedNotifications == originalNotifications.1,
                        "关闭仅移除自有父遮罩，并恢复原 subviews 和几何通知设置")
                    content.editor.unmarkText() // 仅测试清理；生产代码不得调用。
                }
            }
        }

        // 窄小窗口在同一面板内滚动；高对比外观由系统 API 设置，不改用户偏好。
        model.data = initial
        window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        window.setContentSize(NSSize(width: 620, height: 340))
        try await pause()
        window.makeFirstResponder(opener)
        try await click(opener)
        try await eventually("小窗对话框打开") { opener.presentation.panel != nil }
        if let panel = opener.presentation.panel, let backdrop = panel.contentView as? NewPiUsageBackdrop {
            try geometry(backdrop, panel: panel, window: window)
            let scroller = backdrop.scrollView
            try require((scroller.documentView?.bounds.height ?? 0) > scroller.contentView.bounds.height,
                "小窗正文可滚动，关闭标题不随正文滚走")
            try await key(121, text: "", window: panel)
            try require(scroller.contentView.bounds.minY > 0, "真实 PageDown 滚动对话框正文")
            window.setContentSize(NSSize(width: 900, height: 680))
            try await pause()
            try geometry(backdrop, panel: panel, window: window)
            try require(opener.presentation.panel === panel && panel.animationBehavior == .none,
                "窗口缩放不重建面板；无动画满足 reduced motion")
            let origin = content.bounds.origin
            content.setBoundsOrigin(NSPoint(x: origin.x + 3, y: origin.y + 5))
            try geometry(backdrop, panel: panel, window: window)
            content.setBoundsOrigin(origin)
            try geometry(backdrop, panel: panel, window: window)
            let otherSubview = NSView(frame: .zero)
            content.addSubview(otherSubview)
            try await click(backdrop.closeButton)
            try require(otherSubview.superview === content, "dismiss 不移除打开期间业务方新增的 subview")
            otherSubview.removeFromSuperview()
            try require(window.firstResponder === opener, "原焦点为 opener 时恢复 opener")
        }
        // 重复鼠标点击、另一真实按钮的 AXPress 均不得让同一父窗口出现第二个面板。
        try await click(opener)
        try await eventually("重复打开测试的真实按钮路径") { opener.presentation.panel != nil }
        weak var firstPanel = opener.presentation.panel
        try await click(opener)
        let secondOpener = NewPiUsageOpener(frame: NSRect(x: 700, y: 630, width: 44, height: 24))
        content.addSubview(secondOpener)
        _ = secondOpener.accessibilityPerformPress()
        try require(opener.presentation.panel === firstPanel && secondOpener.presentation.panel == nil
            && (window.childWindows ?? []).filter { $0 is NewPiUsagePanel }.count == 1,
            "重复鼠标及同窗另一按钮 AXPress 仍只有原面板")
        secondOpener.removeFromSuperview()

        decoy.setContentSize(NSSize(width: 620, height: 680))
        decoy.makeKeyAndOrderFront(nil)
        try await pause()
        try await click(decoyContent.send)
        try require(decoyContent.model.sends == 1 && opener.presentation.panel === firstPanel,
            "其他 key window 的真实按钮不被本窗 modal monitor 拦截")
        guard let decoyOpener = find(NewPiUsageOpener.self, in: decoyContent) else {
            throw Failure(description: "第二窗口缺少真实用量按钮")
        }
        try await click(decoyOpener)
        try await eventually("第二窗口可独立打开自己的面板") { decoyOpener.presentation.panel != nil }
        try require(decoyOpener.presentation.panel?.parent === decoy && opener.presentation.panel === firstPanel,
            "两窗口各一个面板且互不覆盖")
        if let other = decoyOpener.presentation.panel {
            try await key(53, text: "\u{1b}", window: other)
        }
        try require(decoyOpener.presentation.panel == nil && opener.presentation.panel === firstPanel,
            "其他窗口 Escape 只关闭自己的用量")
        if let close = (firstPanel?.contentView as? NewPiUsageBackdrop)?.closeButton { try await click(close) }
        try require(opener.presentation.panel == nil, "原窗口仍能通过真实关闭按钮关闭")

        window.makeKeyAndOrderFront(nil)
        try await click(opener)
        try await eventually("最小化前真实按钮打开") { opener.presentation.panel != nil }
        weak var minimizedPanel = opener.presentation.panel
        window.miniaturize(nil)
        try await eventually("父窗口最小化后子面板释放并恢复 AX") {
            window.isMiniaturized && minimizedPanel == nil && opener.presentation.parent == nil
                && !content.isAccessibilityHidden()
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        try await pause()
        try await click(content.send)
        try require(model.sends == 1, "最小化清理后 monitor 不再吞父窗口事件")
        model.sends = 0 // 此处显式的测试按钮点击不是模态击穿。

        // 关闭父窗口清理 monitor/AX/子面板；没有静态 callback 留住旧 window。
        try await click(opener)
        try await eventually("生命周期测试打开") { opener.presentation.panel != nil }
        weak var releasedPanel = opener.presentation.panel
        window.close()
        try await eventually("父窗口关闭后子面板释放") { releasedPanel == nil && opener.presentation.parent == nil }

        let hidden = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        let hiddenRoot = UsageFixtureContent(model: UsageFixture())
        hidden.contentView = hiddenRoot
        hiddenRoot.layoutSubtreeIfNeeded()
        try await pause()
        if let hiddenOpener = find(NewPiUsageOpener.self, in: hiddenRoot) {
            // 隐藏容器无法真实鼠标命中；这里单独验证旧 AX 引用也不能创建窗口。
            _ = hiddenOpener.accessibilityPerformPress()
            try require(hiddenOpener.presentation.panel == nil && (hidden.childWindows ?? []).isEmpty,
                "keepalive hidden panel 不新建用量窗口")
        } else { throw Failure(description: "隐藏 fixture 未创建真实按钮，不能跳过验证") }
        hidden.close()
        try require(model.sends == 0 && model.stops == 0 && model.switches == 0, "整轮无业务副作用")
        print("LIMIT: 合成 NSTextView marked text 已测；真实输入法候选窗/生产 WKWebView/VoiceOver 人工朗读仍需主 agent 验收。")
    }

    private static func logFrames(_ stage: String, content: UsageFixtureContent, window: NSWindow) {
        print("FRAMES \(stage): parent=\(window.frame) content=\(content.frame) prose=\(content.prose.frame) editor=\(content.editor.frame) status=\(content.status.frame) needsLayout=\(content.needsLayout)/\(content.editor.needsLayout) verticalResizable=\(content.editor.isVerticallyResizable)")
    }

    private static func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "NewPi Usage · 合成组件验证"
        window.contentView = content
        return window
    }

    private static func geometry(_ backdrop: NewPiUsageBackdrop, panel: NSPanel, window: NSWindow) throws {
        backdrop.layoutSubtreeIfNeeded()
        let expected = window.convertToScreen(window.contentLayoutRect)
        guard let content = window.contentView else { throw Failure(description: "无父 contentView") }
        let overlays = Array(content.subviews.suffix(2))
        let overlayRect = content.convert(window.contentLayoutRect, from: nil)
        try require(overlays.count == 2 && (overlays[0] as? NSVisualEffectView)?.blendingMode == .withinWindow
            && overlays.allSatisfy { $0.frame == overlayRect && $0.isAccessibilityHidden() }
            && !overlays[1].isOpaque,
            "父 content 顶层 withinWindow blur/tint 随几何同步且 AX 隐藏、tint 非 opaque")
        try require(!panel.isOpaque && panel.backgroundColor.alphaComponent == 0 && !backdrop.isOpaque
            && !backdrop.dialog.isOpaque && backdrop.subviews.count == 1
            && backdrop.subviews[0] === backdrop.dialog,
            "子 panel 完全透明，仅持有卡片；无额外 blur 或均匀 tint")
        try require(abs(panel.frame.midX - expected.midX) < 1 && abs(panel.frame.midY - expected.midY) < 1
            && abs(panel.frame.width - expected.width) < 1 && abs(panel.frame.height - expected.height) < 1,
            "遮罩覆盖实际主窗口内容区")
        let rect = backdrop.dialog.frame
        try require(abs(rect.midX - backdrop.bounds.midX) < 1 && abs(rect.midY - backdrop.bounds.midY) < 1
            && abs(rect.width - min(600, backdrop.bounds.width - 40)) < 1
            && rect.height <= backdrop.bounds.height * 0.8 + 1, "居中、最大600宽、两侧20、最大80%高")
        try require(backdrop.dialog.bounds.contains(backdrop.closeButton.frame), "右上关闭始终在卡片内")
    }

    private static func preserved(_ content: UsageFixtureContent, text: String, draft: String,
                                  marked: NSRange, selection: NSRange) throws {
        try require(content.editor.string == text && content.model.draft == draft
            && content.editor.hasMarkedText() && content.editor.markedRange() == marked
            && content.editor.selectedRange() == selection, "同一 textview/draft/marked text/选区完整保留")
    }

    private static func axIsolation(window: NSWindow, panel: NSPanel, content: UsageFixtureContent) throws {
        let children = window.accessibilityChildren() ?? []
        try require(panel.isAccessibilityModal() && content.isAccessibilityHidden() && children.count == 1
            && (children[0] as? NSWindow) === panel, "父 AX 导航只暴露 modal dialog，底层内容隐藏")
        var queue: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        var foundClose = false
        while let node = queue.popLast(), seen.count < 2000 {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            try require(node !== content.editor && node !== content.send && node !== content.switchSession,
                "AX 树不含底层编辑器/业务按钮")
            if let button = node as? NSButton, button.accessibilityIdentifier() == "newpi.usage.close" { foundClose = true }
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            if node.responds(to: selector), let children = node.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: children)
            }
        }
        try require(foundClose, "公开 AX 树可以导航到真实关闭按钮")
    }

    private static func click(_ view: NSView, point: NSPoint? = nil) async throws {
        guard let window = view.window else { throw Failure(description: "鼠标目标无窗口") }
        let point = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(point, to: nil)
        guard view.bounds.contains(point) else { throw Failure(description: "鼠标超出真实控件") }
        // 两个事件先排队，让 NSButton tracking loop 正常拿到 mouseUp；不调用 performClick/action。
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw Failure(description: "无法创建鼠标事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await pause()
    }

    private static func key(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = [],
                            window: NSWindow) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw Failure(description: "无法创建键盘事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await pause()
    }

    private static func capture(_ panel: NSPanel, name: String) async throws {
        // 只捕获本探针自己的合成父子窗口；不申请权限、不抓桌面或用户 App。
        do {
            let bitmap: NSBitmapImageRep
            let destination = output.appendingPathComponent(name)
            if !CGPreflightScreenCaptureAccess()
                || ProcessInfo.processInfo.environment["NEWPI_USAGE_SYSTEM_CAPTURE"] == "1" {
                // CLI 的 preflight 不代表启动它的 VS Code 没有既有授权。
                // 固定 -l 为本进程父窗口 ID，验证系统导出包含其 child；绝不抓区域或全屏。
                guard panel.isVisible, let parent = panel.parent, parent.isVisible,
                      NSApp.windows.contains(where: { $0 === panel }),
                      NSApp.windows.contains(where: { $0 === parent }) else {
                    throw Unavailable(description: "截图目标不是本探针可见父子窗口")
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(parent.windowNumber), destination.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let captured = NSBitmapImageRep(data: try Data(contentsOf: destination)) else {
                    throw Unavailable(description: "系统 screencapture 无既有授权或失败：\(name)")
                }
                bitmap = captured
                print("CAPTURE: 系统 screencapture 仅 test parent ID=\(parent.windowNumber), child=\(panel.windowNumber)；需确认 child 卡片入图")
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let parent = panel.parent,
                      let target = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }),
                      let parentTarget = content.windows.first(where: { $0.windowID == CGWindowID(parent.windowNumber) }),
                      target.owningApplication?.processID == getpid(), parentTarget.owningApplication?.processID == getpid(),
                      let display = content.displays.first(where: { $0.frame.contains(parentTarget.frame) }) else {
                    throw Unavailable(description: "无法定位本进程合成父子窗口及所在显示器")
                }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(parentTarget.frame.width * 2)
                configuration.height = Int(parentTarget.frame.height * 2)
                configuration.sourceRect = parentTarget.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                configuration.ignoreShadowsDisplay = true
                configuration.showsCursor = false
                // 精确白名单只含本探针父子两窗；排除桌面、Dock、decoy 和所有用户窗口。
                // 父窗口负责正文模糊，子窗口负责卡片；缺任一层均不能作为交付截图。
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, including: [parentTarget, target]), configuration: configuration)
                bitmap = NSBitmapImageRep(cgImage: image)
                print("CAPTURE: 仅本进程父子窗口白名单 ID=\(parent.windowNumber),\(panel.windowNumber)")
            }
            var colors = Set<String>()
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                    }
                }
            }
            guard colors.count > 32, let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Unavailable(description: "截图没有足够真实像素：\(name)")
            }
            try png.write(to: destination, options: .atomic)
            print("SCREENSHOT: \(destination.path) · 真实合成面板，需人工确认模糊/圆角/视觉")
            // 父窗口孤立截图也可能有 blur，必须同时证明 child 的清晰标题进入最终像素。
            guard let parent = panel.parent, let backdrop = panel.contentView as? NewPiUsageBackdrop else {
                throw Unavailable(description: "截图期间父子窗口已失效")
            }
            let card = panel.convertToScreen(backdrop.dialog.convert(backdrop.dialog.bounds, to: nil))
            let scaleX = CGFloat(bitmap.pixelsWide) / parent.frame.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / parent.frame.height
            let titleRect = NSRect(x: (card.minX - parent.frame.minX + 18) * scaleX,
                y: (parent.frame.maxY - card.maxY + 18) * scaleY,
                width: 110 * scaleX, height: 28 * scaleY)
            var minimum: CGFloat = 1
            var maximum: CGFloat = 0
            for y in max(0, Int(titleRect.minY))..<min(bitmap.pixelsHigh, Int(titleRect.maxY)) {
                for x in max(0, Int(titleRect.minX))..<min(bitmap.pixelsWide, Int(titleRect.maxX)) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        minimum = min(minimum, luminance)
                        maximum = max(maximum, luminance)
                    }
                }
            }
            print("CHILD PIXELS: \(name) titleContrast=\(maximum - minimum)")
            guard maximum - minimum > 0.25 else {
                throw Unavailable(description: "\(name) 未捕获子 panel 的清晰标题，不能把只有父层的截图当作完整视觉验收")
            }
            try require(true, "截图同时含父层和子 panel 清晰标题")
            // 采样顶部正文带，避开标题栏和居中卡片；均匀灰底不能证实背景模糊。
            var backdropColors = Set<String>()
            for y in stride(from: bitmap.pixelsHigh * 7 / 100, to: bitmap.pixelsHigh * 20 / 100, by: 3) {
                for x in stride(from: bitmap.pixelsWide * 8 / 100, to: bitmap.pixelsWide * 85 / 100, by: 3) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        backdropColors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                    }
                }
            }
            print("BACKDROP PIXELS: \(name) colors=\(backdropColors.count) reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                throw Unavailable(description: "系统减少透明度已开启，无法验收真实背景模糊：\(name)")
            }
            try require(backdropColors.count > 3, "\(name) 卡片外正文带必须为非均匀背景，禁止纯色遮罩冒充 blur")
        } catch let error as Failure { throw error }
        catch let error as Unavailable { throw error }
        catch { throw Unavailable(description: "合成窗口截图不可用：\(error)") }
    }

    private static func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }
    private static func allFields(in view: NSView) -> [NSTextField] { allViews(in: view).compactMap { $0 as? NSTextField } }
    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? { allViews(in: view).compactMap { $0 as? T }.first }
    private static func pause() async throws { try await Task.sleep(for: .milliseconds(160)) }
    private static func eventually(_ label: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if condition() { passes += 1; print("PASS: \(label)"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(description: label)
    }
    private static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        passes += 1
        print("PASS: \(label)")
    }
}