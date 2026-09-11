import AppKit
import Foundation
import NewPiCore
import SwiftUI
import WebKit

// 独立原生探针：真实共享视图、生产输入框、Coordinator 与本地渲染资源。
// 只替换指标/日志落盘端及业务状态，不创建 AgentSession，不访问凭据或用户会话。
actor LLMMetricsRecorder {
    static let shared = LLMMetricsRecorder()
    func record(_ metric: UITranscriptDiffMetric) {}
    func record(_ metric: UIDomApplyMetric) {}
}

enum NewPiLogger {
    static func info(category: String, message: String, details: String = "") {}
    static func error(category: String, message: String, details: String? = nil) {
        print("Coordinator error: \(message) \(details ?? "")")
    }
}

@MainActor
private final class WorkbenchModel: ObservableObject {
    static let longModel = "workbench-local-fixture-with-a-very-long-model-name-2026-09-context-1000000"
    static let metrics = ["↑12.3k ↓4.5k", "↑2.1k ↓456", "85%", "上下文 9.2% / 1.0M", "24 tok/s"]
    static let initialDraft = "请继续检查布局；这条草稿应跨窗口宽度与浅深外观保留。"
    @Published var draft = WorkbenchModel.initialDraft
    @Published var running = false
    @Published var hasMetrics = true
    @Published var selectedModel = WorkbenchModel.longModel
    @Published var isRoom = false
    @Published var items: [NewPiTranscriptItem]
    let controller = TranscriptDocumentController()
    // 几何读数仅供断言，不参与视图布局与滚动，也不触发新一轮发布。
    var frames: [String: CGRect] = [:]
    var sends = 0
    var stops = 0
    var submitAttempts = 0

    init() {
        let turn = "workbench-fixture"
        let markdown = """
        ## 文档工作台验证

        已将会话整理为连续阅读的文档。下面是固定的展示数据，**没有调用模型或执行工具**。

        ```swift
        struct ReadingColumn {
            let maximumWidth = 800
            let preservesDraft = true
        }
        ```

        - 任务、思考与工具结果保留在同一份 transcript。
        - 原生输入区保持四行视口，长模型名在底栏截断。
        - 用量按需展开，浅色与深色共享组件语义色。

        """ + (1...12).map { index in
            """
            ### 验证记录 \(index)

            这是一段用于检查长文阅读与自然换行的固定内容。窗口缩窄时正文应留在阅读列内，输入框不能随状态切换重建。`draft` 属于当前输入区，运行期间 Return 不应停止任务。

            1. 查看本地渲染结果与代码高亮。
            2. 保留草稿并检查原生按钮边界。

            """
        }.joined(separator: "\n")
        items = [
            NewPiTranscriptItem(kind: .user, body: "检查文档工作台：长文、处理详情、模型底栏与输入草稿。"),
            NewPiTranscriptItem(kind: .detailGroup(collapsed: false), body: "", detailTurnID: turn),
            NewPiTranscriptItem(kind: .thinking(isStreaming: false),
                body: "先检查布局，再验证原生输入与按钮的状态边界。", detailTurnID: turn),
            NewPiTranscriptItem(kind: .tool(name: "read", state: .completed(isError: false)),
                body: "固定工具结果：阅读列规格为 800；没有读取真实项目文件。",
                toolCommand: "fixture/ReadingColumn.swift", detailTurnID: turn),
            NewPiTranscriptItem(kind: .assistant, body: markdown),
        ]
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // 这里只验证 UI 与内存业务边界的接线，不冒充 ViewModel.send / AgentSession 集成测试。
    func submit() {
        submitAttempts += 1
        guard !running, canSend else { return }
        sends += 1
        draft = ""
        running = true
    }

    func stop() {
        stops += 1
        running = false
    }
}

private struct WorkbenchRoot: View {
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            NewPiWorkbenchHeader(
                mode: model.isRoom ? "聊天室" : "会话",
                title: model.isRoom ? "界面设计评审" : "让 Markdown 收尾更稳定",
                directory: model.isRoom ? "~/personal/projects/design-lab · 独立工作目录" : "~/personal/projects/new-pi"
            ) {
                Menu { Text("合成数据，不导出文件") } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                Menu { Text("完整窗口探针") } label: {
                    Label("更多", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
            }
            .measure("header", model: model)

            if model.isRoom {
                NewPiWorkbenchRoleStrip(phaseTitle: "讨论", roles: [
                    .init(id: "architect", name: "架构师", systemImage: "building.2", isSpeaking: false),
                    .init(id: "developer", name: "程序员", systemImage: "terminal", isSpeaking: model.running),
                    .init(id: "reviewer", name: "评审员", systemImage: "checkmark.shield", isSpeaking: false),
                    .init(id: "long-name", name: "长角色名称与多角色横向滚动检查", systemImage: "person", isSpeaking: false),
                ])
                .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Divider() }
                .measure("roles", model: model)
            }

            NewPiTranscriptDocumentView(
                transcript: model.items, isStreaming: model.running,
                streamingBubbleComplete: true, storeKey: nil, controller: model.controller)

            VStack(spacing: 6) {
                NewPiAgentStatusBar(
                    presentation: NewPiAgentStatusPresentation(
                        systemImage: model.running ? "text.append" : "checkmark.circle",
                        label: model.running ? "正在处理固定任务…" : "已完成 · 可以继续提问",
                        isActive: model.running),
                    usageText: metric(0), lastTurnUsageText: metric(1), cacheHitRateText: metric(2),
                    contextText: metric(3), tokenRateText: metric(4))

                NewPiComposerSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        NewPiComposerTextView(
                            text: $model.draft, isDisabled: false,
                            placeholder: model.running ? "先写下一条消息，当前任务结束后发送…" : "继续提问，或告诉 NewPi 下一步做什么…",
                            onSubmit: model.submit)
                            .frame(height: NewPiComposerScrollView.fixedHeight)
                        HStack(spacing: 10) {
                            // 只展示附件入口；不打开用户文件、不读剪贴板。
                            Button {} label: {
                                Label("添加图片", systemImage: "plus")
                                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            NewPiModelPickerMenu(
                                groups: [NewPiProviderModelGroup(profileID: "fixture", profileName: "本地固定数据",
                                    systemImage: "cpu", hasAPIKey: false, models: [WorkbenchModel.longModel])],
                                activeProfileID: "fixture", activeModelID: model.selectedModel,
                                isDisabled: model.running,
                                onSelect: { _, name in model.selectedModel = name })
                                .measure("model", model: model)
                            Spacer(minLength: 8)
                            NewPiComposerPrimaryAction(isRunning: model.running, canSend: model.canSend,
                                onSend: model.submit, onStop: model.stop)
                                .measure("action", model: model)
                        }
                    }
                }
                .measure("surface", model: model)
            }
            .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
            .padding(.top, 6)
            .padding(.bottom, 16)
            .frame(maxWidth: NewPiWorkbenchStyle.maxReadingWidth)
            .measure("column", model: model)
            .frame(maxWidth: .infinity)
            .background(NewPiWorkbenchStyle.surface)
            .animation(nil, value: model.running)
        }
        .background(NewPiWorkbenchStyle.surface)
        .coordinateSpace(name: "workbench")
    }

    private func metric(_ index: Int) -> String? {
        model.hasMetrics ? WorkbenchModel.metrics[index] : nil
    }
}

/// 整窗检查使用与 root 相同的生产外壳和标签组件，列表数据固定且不访问真实存储。
private struct WorkbenchProbeRoot: View {
    @ObservedObject var model: WorkbenchModel
    let fullWindow: Bool

    var body: some View {
        if fullWindow {
            NewPiWorkbenchShell {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Text("n·").font(.system(size: 25, weight: .bold, design: .rounded))
                                    .foregroundStyle(NewPiWorkbenchStyle.accent)
                                Text("NewPi").font(.system(size: 13, weight: .semibold))
                                Spacer()
                            }.padding(.horizontal, 10)
                            Text("个人工作区").font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                            NewPiWorkbenchProjectCard(name: "new-pi", path: "/fixture/new-pi", action: {})
                            Button { model.isRoom = false } label: {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("新会话")
                                    Spacer()
                                    Text("⇧⌘N").foregroundStyle(.secondary).font(.system(size: 10))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(10)
                                .background(NewPiWorkbenchStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(NewPiWorkbenchStyle.line) }
                            }.buttonStyle(.plain).padding(.horizontal, 4)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("会话").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
                            row("让 Markdown 收尾更稳定", subtitle: "刚刚 · 2 个文件", room: false, selected: !model.isRoom)
                            row("检查长会话渲染", subtitle: "今天 · 固定任务", room: false, selected: false)
                            row("梳理项目结构", subtitle: "昨天", room: false, selected: false)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("聊天室").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
                            DisclosureGroup("design-lab（1）", isExpanded: .constant(true)) {
                                row("界面设计评审", subtitle: "独立目录 · design-lab", room: true, selected: model.isRoom)
                            }.font(.caption)
                        }
                    }
                    .padding(12)
                }
            } content: {
                WorkbenchRoot(model: model)
            }
        } else {
            WorkbenchRoot(model: model)
        }
    }

    private func row(_ title: String, subtitle: String, room: Bool, selected: Bool) -> some View {
        Button { model.isRoom = room } label: {
            NewPiWorkbenchSidebarEntry(title: title, subtitle: subtitle,
                systemImage: room ? "person.2" : "bubble.left", isSelected: selected)
                .padding(10)
                .background(selected ? NewPiWorkbenchStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

private extension View {
    @MainActor
    func measure(_ name: String, model: WorkbenchModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workbench")) } action: {
            model.frames[name] = $0
        }
    }
}

@main
@MainActor
struct WorkbenchUIChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // 缺少公开 AX 暴露或原生截图能力不等于验证通过；strict 在所有独立检查结束后失败。
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private static let strict = ProcessInfo.processInfo.environment["NEWPI_WORKBENCH_UI_STRICT"] == "1"
    private static var skipped: [String] = []
    private static var failed: [String] = []
    private static var screenshots: [String] = []
    private static var loggedAXTypes = Set<String>()

    static func main() {
        let previouslyActive = NSWorkspace.shared.frontmostApplication
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                previouslyActive?.activate(options: [])
                exit(0)
            } catch {
                print("FAIL: \(error)")
                previouslyActive?.activate(options: [])
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            NSApp.windows.forEach { $0.orderOut(nil) }
            previouslyActive?.activate(options: [])
            print("FAIL: workbench UI timeout (90s)")
            exit(1)
        }
        NSApp.run()
    }

    private static func run() async throws {
        let model = WorkbenchModel()
        let fullWindow = ProcessInfo.processInfo.environment["NEWPI_WORKBENCH_FULL_WINDOW"] == "1"
        let host = NSHostingController(rootView: WorkbenchProbeRoot(model: model, fullWindow: fullWindow))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.title = "NewPi · 文档工作台原生验证"
        window.appearance = NSAppearance(named: .aqua)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await eventually("真实 WebKit 文档加载（5 个固定条目）") {
            guard let web: WKWebView = find(in: host.view), !web.isLoading else { return false }
            return try await web.evaluateJavaScript("document.querySelectorAll('.ti').length === 5") as? Bool == true
        }
        guard let web: WKWebView = find(in: host.view),
              let editor: NewPiComposerInnerTextView = find(in: host.view) else {
            throw Failure("未找到真实 WKWebView / NewPiComposerInnerTextView")
        }
        try require(!web.configuration.websiteDataStore.isPersistent && model.controller.sessionID == nil,
            "nonPersistent WebKit；storeKey=nil，无会话/滚动数据落盘")
        await check("Markdown 与详情交互") { try await checkDocument(web, model: model) }

        if fullWindow {
            try await checkFullWindow(model, host: host.view, window: window, web: web, editor: editor)
            return
        }

        // 四种组合均尝试截图；AX / snapshot 不可验证时仍继续其它组合与键盘检查。
        for (width, dark, screenshot) in [(900, false, "workbench-light.png"),
                                          (900, true, "workbench-dark.png"),
                                          (620, true, "workbench-narrow-dark.png"),
                                          (620, false, "workbench-narrow.png")] {
            let scenario = "\(width)px \(dark ? "dark" : "light")"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: CGFloat(width), height: 820))
            host.view.layoutSubtreeIfNeeded()
            await check("\(scenario) 布局与草稿") {
                try await eventually("\(scenario) 原生/WebKit 外观与尺寸同步") {
                    let isDark = try await web.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
                    return isDark == dark && abs(host.view.bounds.width - CGFloat(width)) < 1
                        && abs((model.frames["column"]?.width ?? 0) - min(CGFloat(width), 800)) < 1
                }
                model.controller.jumpTo(model.items[0].id)
                try await settle(web)
                try require(find(in: host.view, as: NewPiComposerInnerTextView.self) === editor
                    && editor.string == WorkbenchModel.initialDraft && model.draft == WorkbenchModel.initialDraft,
                    "\(scenario): 同一个 NSTextView 保留非空草稿")
                try await checkLayout(model, host: host.view, window: window, web: web, width: CGFloat(width))
            }
            await check("\(scenario) AX 发送按钮边界") {
                let button = try findButton("发送消息", in: host.view)
                try require(button.frame.width >= 31 && button.frame.width <= 34
                    && button.frame.height >= 31 && button.frame.height <= 34
                    && window.convertToScreen(host.view.convert(host.view.bounds, to: nil)).contains(button.frame),
                    "真实发送按钮 accessibility 边界在窗口内 (\(button.frame))")
            }
            await check("\(scenario) screenshot") {
                try await snapshot(host: host.view, web: web, name: screenshot)
            }
            await check("\(scenario) AX 用量弹层（有值 / 无数据）") {
                try await checkUsage(model, host: host.view, window: window, web: web)
            }
        }
        await check("AX 输入主按钮（disabled / send / stop）") {
            try await checkInput(model, host: host.view, window: window, web: web, editor: editor)
        }
        await check("独立 NSTextView 键盘 / Binding / 流式边界（不依赖 AX）") {
            try await checkKeyboardInput(model, host: host.view, window: window, web: web, editor: editor)
        }
        print("SUMMARY: 900/620 × 浅/深；有效合成截图 \(screenshots.count)/4；SKIP=\(skipped.count)；FAIL=\(failed.count)；strict=\(strict)；无模型调用")
        for item in skipped { print("UNVERIFIED: \(item)") }
        for item in failed { print("FAILED: \(item)") }
        if !failed.isEmpty || (strict && !skipped.isEmpty) {
            throw Failure("探针完成但有失败或 strict 不允许的 SKIP（见 SUMMARY）；并非全部通过")
        }
        print(skipped.isEmpty ? "PASS: 所有已列运行时检查完成" : "PARTIAL: 可运行检查已结束；上述 SKIP 未验证，非全部通过")
    }

    private static func check(_ label: String, body: () async throws -> Void) async {
        do {
            try await body()
            print("PASS GROUP: \(label)")
        } catch let error as Unavailable {
            skipped.append("\(label)：\(error)")
            print("SKIP: \(label)：\(error)")
        } catch {
            failed.append("\(label)：\(error)")
            print("FAIL: \(label)：\(error)；继续独立检查")
        }
    }

    private static func checkFullWindow(_ model: WorkbenchModel, host: NSView, window: NSWindow,
                                        web: WKWebView, editor: NewPiComposerInnerTextView) async throws {
        for width in [1200, 900] {
            for dark in [false, true] {
                for room in [false, true] {
                    model.isRoom = room
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setContentSize(NSSize(width: CGFloat(width), height: 820))
                    let name = "shell-\(width)-\(dark ? "dark" : "light")-\(room ? "room" : "session")"
                    try await eventually(name + " 外观同步") {
                        try await web.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool == dark
                    }
                    try await settle(web)
                    let webRect = host.convert(web.bounds, from: web)
                    let detailWidth = web.bounds.width
                    try require(webRect.minX >= 225 && webRect.minX <= 251,
                        name + ": sidebar width=\(webRect.minX)，不再扩大为旧宽侧栏")
                    guard let header = model.frames["header"], let surface = model.frames["surface"],
                          let action = model.frames["action"] else { throw Failure("整窗组件缺少几何读数") }
                    try require(abs(header.height - 73) < 2 && abs(header.width - detailWidth) < 1,
                        name + ": 单一身份 header，标题目录不重复")
                    try require(abs(surface.width - (min(detailWidth, 800) - 48)) < 1 && surface.contains(action),
                        name + ": 输入区在 detail 内居中且主操作未挤出")
                    try require(find(in: host, as: NewPiComposerInnerTextView.self) === editor && editor.string == WorkbenchModel.initialDraft,
                        name + ": 模式/宽度/外观切换不重建输入或丢草稿")
                    if room {
                        guard let roles = model.frames["roles"] else { throw Failure("缺少角色栏") }
                        try require(abs(roles.width - detailWidth) < 1 && roles.height < 55,
                            name + ": 多角色保持单行滚动，不挤占身份栏")
                    }
                    try require(web.bounds.height > 450, name + ": 保留足够正文阅读高度")
                    model.controller.jumpTo(model.items.first(where: { $0.kind == .assistant })!.id)
                    try await settle(web)
                    try await snapshot(host: host, web: web, name: name + ".png")
                }
            }
        }
        try await checkKeyboardInput(model, host: host, window: window, web: web, editor: editor)
        try require(failed.isEmpty, "整窗基础 Markdown 检查无失败")
        print("PASS: 8 full-window scenarios with production shell/header/project/entry/roles; keyboard/draft preserved; buttons/popovers still require separate interaction validation")
        if !skipped.isEmpty {
            print("PARTIAL: full-window visual capture SKIP=\(skipped.count); glass sidebar has not been visually verified")
            if strict { throw Failure("strict 不允许不完整侧栏截图；布局/键盘通过不等于视觉验收完成") }
        }
    }

    private static func checkDocument(_ web: WKWebView, model: WorkbenchModel) async throws {
        model.controller.jumpTo(model.items[0].id)
        try await settle(web)
        let rendered = try await web.evaluateJavaScript("""
            document.querySelectorAll('.ti-user').length === 1 &&
            document.querySelectorAll('.ti-answer article h3').length === 12 &&
            document.querySelectorAll('.ti-answer pre code').length === 1 &&
            document.querySelectorAll('.ti-answer li').length >= 27 &&
            document.querySelectorAll('.ti-thinking, .ti-tool, .ti-detail').length === 3
            """) as? Bool
        try require(rendered == true, "生产 renderer 生成长 Markdown / code / list / thinking / tool / detail")
        // 点击既有 DOM 控件及读取结果，不插入 DOM、不覆写样式、不直接设置折叠状态。
        for selector in [".ti-thinking .card-hd", ".ti-tool .card-hd"] {
            let expanded = try await web.callAsyncJavaScript("""
                const button = document.querySelector(selector);
                button.click();
                const card = button.closest('.card');
                return card.classList.contains('expanded') &&
                    getComputedStyle(card.querySelector('.card-body')).display !== 'none';
                """, arguments: ["selector": selector], in: nil, contentWorld: .page) as? Bool
            try require(expanded == true, "真实 \(selector) 展开正文")
        }
        let collapsed = try await web.evaluateJavaScript("""
            document.querySelector('.detail-row').click();
            [...document.querySelectorAll('.detail-item')].every(el => getComputedStyle(el).display === 'none')
            """) as? Bool
        try require(collapsed == true, "真实处理详情按钮隐藏组内条目")
        let reopened = try await web.evaluateJavaScript("""
            document.querySelector('.detail-row').click();
            [...document.querySelectorAll('.detail-item')].every(el => getComputedStyle(el).display !== 'none')
            """) as? Bool
        try require(reopened == true, "真实处理详情按钮恢复组内条目")
        // 截图保留思考/工具摘要，为回答的标题、代码与列表留下视口空间。
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.card.expanded .card-hd').forEach(b => b.click())")
    }

    private static func checkLayout(_ model: WorkbenchModel, host: NSView, window: NSWindow,
                                    web: WKWebView, width: CGFloat) async throws {
        guard let column = model.frames["column"], let surface = model.frames["surface"],
              let picker = model.frames["model"], let action = model.frames["action"],
              let header = model.frames["header"] else { throw Failure("SwiftUI 几何读数缺失") }
        let expected = min(width, 800)
        try require(abs(column.width - expected) < 1 && abs(column.midX - width / 2) < 1,
            "\(Int(width))px: 原生 composer 阅读列=\(Int(column.width))，居中且最大 800")
        try require(abs(surface.width - (expected - 48)) < 1 && surface.width >= 572 && surface.height >= 130,
            "\(Int(width))px: 共享 composer 外壳 \(Int(surface.width))×\(Int(surface.height))，未收缩为窄条")
        try require(abs(action.width - 32) < 1 && abs(action.height - 32) < 1
            && surface.contains(action) && picker.maxX + 8 <= action.minX && picker.width <= 221,
            "\(Int(width))px: 长模型名不重叠/挤出 32×32 主按钮")
        try require(header.height >= 30 && web.bounds.height >= 450 && window.occlusionState.contains(.visible),
            "原生 header / WebKit 阅读面可见且未被 composer 挤出")
        let geometry = try await web.evaluateJavaScript("""
            (() => {
                            const transcript = document.querySelector('#transcript');
                            const r = transcript.getBoundingClientRect();
                            const style = getComputedStyle(transcript);
                            const viewport = document.documentElement.clientWidth;
                            return {width:r.width, center:r.x+r.width/2, viewport, windowWidth:innerWidth,
                                paddingLeft:style.paddingLeft, paddingRight:style.paddingRight,
                                overflow:document.documentElement.scrollWidth > viewport};
            })()
            """) as? [String: Any]
        guard let geometry, let reading = geometry["width"] as? Double,
                            let center = geometry["center"] as? Double, let viewport = geometry["viewport"] as? Double,
                            let windowWidth = geometry["windowWidth"] as? Double else {
            throw Failure("WebKit 阅读列几何返回无效")
        }
                // CSS 百分比宽度相对扣除常驻滚动条后的 layout viewport，不是包含滚动条的 innerWidth。
                // 不覆盖用户滚动条偏好；正文 padding 记录实际值，统一 24 的生产改动由主 agent 负责。
                print("CSS GEOMETRY: window=\(windowWidth) client=\(viewport) gutter=\(windowWidth - viewport) center=\(center) padding=\(geometry["paddingLeft"] ?? "?")/\(geometry["paddingRight"] ?? "?")")
        try require(abs(reading - min(viewport, 800)) < 1 && abs(center - viewport / 2) < 1
                        && abs(windowWidth - Double(web.bounds.width)) < 1 && geometry["overflow"] as? Bool == false,
                        "\(Int(width))px: 真实 CSS 阅读列=\(reading)，max 800、在 client viewport 内居中、无横向溢出")
    }

    private static func checkUsage(_ model: WorkbenchModel, host: NSView, window: NSWindow,
                                   web: WKWebView) async throws {
        defer {
            model.hasMetrics = true
            // 清理本探针的临时弹层，避免一次 AX 失败遮住后续截图或夺走键盘。
            for child in window.childWindows ?? [] where child.isVisible { child.cancelOperation(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        let titles = ["累计用量", "最近一轮", "缓存命中率", "上下文占用", "输出速率"]
        for populated in [true, false] {
            model.hasMetrics = populated
            try await settle(web)
            try press(try findButton("用量", in: host), label: "用量")
            try await eventually("真实用量 popover 可见", unavailable: true) { try usagePopover(excluding: window) != nil }
            guard let popover = try usagePopover(excluding: window), let content = popover.contentView else {
                throw Unavailable("按压后未从公开 AX 找到用量弹层窗口")
            }
            let nodes = try accessibilityNodes(content).filter {
                $0.frame.width > 0 && $0.frame.height > 0 && popover.frame.contains($0.frame)
            }
            for title in titles {
                try require(nodes.contains { $0.texts.contains(title) }, "用量 popover 可见指标：\(title)")
            }
            if populated {
                for value in WorkbenchModel.metrics {
                    try require(nodes.contains { $0.texts.contains(value) }, "用量 popover 显示传入值：\(value)")
                }
            } else {
                // 同一文字可能同时暴露 label/value，按真实 frame 去重，不把容器重复算成指标。
                let emptyFrames = Set(nodes.filter { $0.texts.contains("暂无数据") }.map { NSStringFromRect($0.frame) })
                try require(emptyFrames.count == 5, "用量 popover 五项暂无数据（实际 \(emptyFrames.count)）")
                try require(!nodes.contains { !$0.texts.isDisjoint(with: Set(WorkbenchModel.metrics)) },
                    "无数据时不残留上次指标")
            }
            try press(try findButton("用量", in: host), label: "用量（关闭）")
            try await eventually("用量 popover 已关闭", unavailable: true) { try usagePopover(excluding: window) == nil }
        }
        model.hasMetrics = true
        try await settle(web)
    }

    private static func checkInput(_ model: WorkbenchModel, host: NSView, window: NSWindow,
                                   web: WKWebView, editor: NewPiComposerInnerTextView) async throws {
        func preserved(_ expected: String, _ stage: String) throws {
            try require(find(in: host, as: NewPiComposerInnerTextView.self) === editor
                && editor.string == expected && model.draft == expected && editor.isEditable,
                "\(stage): 同一 NSTextView 与 Binding 保留草稿")
        }
        func type(_ text: String) throws {
            try require(window.makeFirstResponder(editor), "真实 NSTextView 成为 first responder")
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        for empty in ["", "  \n  "] {
            try type(empty)
            try await settle(web)
            let disabled = try findButton("发送消息", in: host)
            try require(!disabled.enabled && !model.canSend, "idle 空白草稿：canSend=false，真实发送按钮 disabled")
            _ = disabled.performPress()
            try await settle(web)
            try require(model.sends == 0 && model.stops == 0, "disabled 按钮按压不发送/停止")
        }
        try type("第一条固定消息")
        try await settle(web)
        let send = try findButton("发送消息", in: host)
        try require(send.enabled && model.canSend, "idle 非空草稿：canSend=true，真实发送按钮 enabled")
        try press(send, label: "发送消息")
        try await settle(web)
        try require(model.sends == 1 && model.stops == 0 && model.running && model.draft.isEmpty,
            "明确发送按钮按压：send=1 / stop=0；接受后清空草稿")
        try preserved("", "发送边界")
        try require(try findButton("停止生成", in: host).enabled && !model.canSend,
            "running 空草稿：canSend=false 但真实停止按钮 enabled")

        let draft = "下一条草稿：保留中文、code `value` 与模型长名。"
        try type(draft)
        try await settle(web)
        let attempts = model.submitAttempts
        try returnKey(window: window, editor: editor)
        try await settle(web)
        try require(model.submitAttempts == attempts + 1 && model.sends == 1 && model.stops == 0 && model.running,
            "running Return 到达生产输入框 onSubmit，但 send 不增加、stop=0、任务继续")
        try preserved(draft, "running Return")

        // 真实直连刷新与边界提交；模拟的是 UI 状态，不创建或调用 actual AgentSession。
        var latest = model.items
        let tailID = UUID()
        latest.append(NewPiTranscriptItem(id: tailID, kind: .assistant, body: "正在整理固定验证记录…"))
        model.controller.applyLive(items: latest, isStreaming: true, streamingBubbleComplete: false, tintHues: [:])
        defer { model.controller.endLiveApply() }
        try await eventually("直连 Markdown 内容到达真实 WebKit") {
            try await web.evaluateJavaScript("document.querySelectorAll('.ti-answer').length === 2") as? Bool == true
        }
        try preserved(draft, "流式直连更新")
        latest[latest.count - 1] = NewPiTranscriptItem(id: tailID, kind: .assistant, body: "固定任务完成。")
        model.controller.applyLive(items: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        model.items = latest
        model.running = false
        model.controller.endLiveApply()
        try await settle(web)
        try preserved(draft, "完成边界")
        try require(try findButton("发送消息", in: host).enabled, "完成后非空草稿恢复发送按钮")

        model.running = true
        try await settle(web)
        try preserved(draft, "再次运行边界")
        try press(try findButton("停止生成", in: host), label: "停止生成")
        try await settle(web)
        try require(model.stops == 1 && model.sends == 1 && !model.running,
            "明确停止按钮按压：stop 精确为 1，send 仍为 1")
        try preserved(draft, "停止边界")
        try returnKey(window: window, editor: editor)
        try await settle(web)
        try require(model.sends == 2 && model.stops == 1 && model.draft.isEmpty,
            "idle Return 正常提交：send=2 / stop=1，未误用停止按钮")
        try preserved("", "Return 发送完成")
    }

    // 独立于 AX 主按钮；真实 NSEvent → 生产 NSTextView → 内存 fixture 的 onSubmit。
    // 不把 fixture 状态切换声称为停止按钮交互，也不调用 model.submit()/stop() 代替输入。
    private static func checkKeyboardInput(_ model: WorkbenchModel, host: NSView, window: NSWindow,
                                          web: WKWebView, editor: NewPiComposerInnerTextView) async throws {
        model.running = false
        let sends = model.sends
        let stops = model.stops
        window.makeKeyAndOrderFront(nil)
        try await settle(web)
        func type(_ text: String) throws {
            try require(window.makeFirstResponder(editor), "键盘独立检查：真实 editor 成为 responder")
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func preserved(_ text: String, _ stage: String) throws {
            try require(find(in: host, as: NewPiComposerInnerTextView.self) === editor
                && editor.string == text && model.draft == text && editor.isEditable,
                "键盘独立检查 \(stage)：同一个 NSTextView / Binding 保留文本")
        }
        for empty in ["", "  \n  "] {
            try type(empty)
            try await settle(web)
            let attempts = model.submitAttempts
            try returnKey(window: window, editor: editor)
            try await settle(web)
            try require(model.submitAttempts == attempts + 1 && model.sends == sends
                && model.stops == stops && !model.running && !model.canSend,
                "空白 Return 真实到达 onSubmit，但不发送/停止（不代表按钮 disabled 已验证）")
            try preserved(empty, "空白 Return")
        }
        try type("键盘固定消息")
        try await settle(web)
        let attempts = model.submitAttempts
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        try returnKey(window: window, editor: editor, modifiers: .shift)
        try await settle(web)
        try preserved("键盘固定消息\n", "Shift+Return 换行")
        try require(model.submitAttempts == attempts && model.sends == sends && model.stops == stops,
            "Shift+Return 未触发提交或停止")
        try returnKey(window: window, editor: editor)
        try await settle(web)
        try require(model.sends == sends + 1 && model.stops == stops && model.running,
            "idle Return 真实提交一次且未停止")
        try preserved("", "接受提交后清空")

        let draft = "键盘草稿：中文与 `code` 在流式期间保留。"
        try type(draft)
        try await settle(web)
        let runningAttempts = model.submitAttempts
        try returnKey(window: window, editor: editor)
        try await settle(web)
        try require(model.submitAttempts == runningAttempts + 1 && model.sends == sends + 1
            && model.stops == stops && model.running, "running Return 到达 onSubmit，但不发送/停止")
        try preserved(draft, "running Return")

        var latest = model.items
        let tailID = UUID()
        latest.append(NewPiTranscriptItem(id: tailID, kind: .assistant, body: "键盘探针直连流式内容"))
        model.controller.applyLive(items: latest, isStreaming: true, streamingBubbleComplete: false, tintHues: [:])
        defer { model.controller.endLiveApply() }
        try await eventually("键盘检查的 live 内容到达真实 WebKit") {
            try await web.evaluateJavaScript("[...document.querySelectorAll('.ti-answer')].some(el => el.textContent.includes('键盘探针直连流式内容'))") as? Bool == true
        }
        try preserved(draft, "直连流式更新")
        latest[latest.count - 1] = NewPiTranscriptItem(id: tailID, kind: .assistant, body: "键盘探针完成边界")
        model.controller.applyLive(items: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        model.items = latest
        model.running = false
        model.controller.endLiveApply()
        try await settle(web)
        try preserved(draft, "fixture 完成边界（不是停止按钮）")
        try returnKey(window: window, editor: editor)
        try await settle(web)
        try require(model.sends == sends + 2 && model.stops == stops && model.running,
            "完成后的 idle Return 正常再次提交，stop 不变")
        try preserved("", "再次提交")
    }

    private static func returnKey(window: NSWindow, editor: NSTextView, modifiers: NSEvent.ModifierFlags = []) throws {
        try require(window.makeFirstResponder(editor), "Return 发送至真实 NSTextView responder")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                throw Failure("不能创建 Return 事件")
            }
            NSApp.sendEvent(event)
        }
    }

    // 仅使用 AppKit 的进程内接口；不调用 AXUIElement、CGEvent 或需要系统权限的 UI 脚本。
    // SDK 正式 API 名为 accessibilityPerformPress()，不是 performPress()。
    @MainActor
    private struct Accessible {
        let object: NSObject
        let texts: Set<String>
        let role: NSAccessibility.Role?
        let frame: NSRect
        let enabled: Bool
        let children: [Any]
        let performPress: () -> Bool

        init?(_ object: NSObject) {
            // SwiftUI 的节点可能只是 NSObject + NSAccessibility，不是 NSView / NSAccessibilityElement。
            // Objective-C NSAccessibility 在 Swift 导入为 NSAccessibilityProtocol；
            // NSAccessibility 本身是常量命名空间。此协议路径已完成一次独立脚本运行。
            // 实测部分 SwiftUI.AccessibilityNode 不声明此协议：记录真实类型并 SKIP，
            // 不强转协议，也不保留未经完整脚本验证的动态选择子路径。
            guard let accessibility = object as? any NSAccessibilityProtocol else { return nil }
            self.object = object
            texts = Set([accessibility.accessibilityLabel(), accessibility.accessibilityTitle(),
                accessibility.accessibilityValue() as? String].compactMap { $0 })
            role = accessibility.accessibilityRole()
            frame = accessibility.accessibilityFrame()
            enabled = accessibility.isAccessibilityEnabled()
            children = (accessibility.accessibilityChildren() ?? []) + ((object as? NSView)?.subviews ?? [])
            performPress = { accessibility.accessibilityPerformPress() }
        }
    }

    private static func accessibilityNodes(_ root: NSView) throws -> [Accessible] {
        var pending: [Any] = [root]
        var seen = Set<ObjectIdentifier>()
        var result: [Accessible] = []
        while let value = pending.popLast() {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            guard seen.count <= 2000 else { throw Unavailable("accessibility 树超过 2000 节点；停止遍历，不使用私有 API 兜底") }
            // WebKit 是远程 accessibility 树；原生检查不穿透它，正文由真实 DOM/WK 快照验证。
            if object is WKWebView { continue }
            let node = Accessible(object)
            let typeName = String(reflecting: type(of: object))
            if loggedAXTypes.insert(typeName).inserted {
                print("AX TYPE: \(typeName) NSView=\(object is NSView) NSAccessibilityElement=\(object is NSAccessibilityElement) NSAccessibilityProtocol=\(object is any NSAccessibilityProtocol) publicRoleGetter=\(object.responds(to: #selector(NSAccessibilityProtocol.accessibilityRole))) role=\(node?.role?.rawValue ?? "nil") children=\(node?.children.count ?? 0)")
            }
            guard let node else {
                // 即使容器不遵循完整协议，也继续它公开的原生 subviews。
                if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
                continue
            }
            result.append(node)
            pending.append(contentsOf: node.children)
        }
        return result
    }

    private static func findButton(_ label: String, in host: NSView) throws -> Accessible {
        let nodes = try accessibilityNodes(host)
        let candidates = nodes.filter { $0.role == .button && $0.texts.contains(label) && !$0.frame.isEmpty }
        if let native = candidates.first(where: { $0.object is NSButton }) { return native }
        if let element = candidates.first { return element }
        let exposed = nodes.filter { $0.role == .button }.map { "\(type(of: $0.object)):\($0.texts.sorted()) frame=\($0.frame)" }
        throw Unavailable("未暴露真实按钮「\(label)」；visibleButtons=\(exposed)；nodes=\(nodes.count)，真实类型见 AX TYPE 日志。不启用系统 AX 权限或静态断言兜底")
    }

    private static func press(_ button: Accessible, label: String) throws {
        try require(button.enabled, "\(label): 真实 AX enabled")
        guard button.performPress() else {
            throw Unavailable("\(label): \(type(of: button.object)).accessibilityPerformPress() 未接受按压")
        }
        print("PASS: \(label): \(type(of: button.object)).accessibilityPerformPress() 接受按压")
    }

    private static func usagePopover(excluding main: NSWindow) throws -> NSWindow? {
        let windows = NSApp.windows + (main.childWindows ?? [])
        for window in windows where window !== main && window.isVisible {
            guard let content = window.contentView else { continue }
            if try accessibilityNodes(content).contains(where: {
                $0.texts.contains("用量明细") && !$0.frame.isEmpty && window.frame.contains($0.frame)
            }) { return window }
        }
        return nil
    }

    private static func snapshot(host: NSView, web: WKWebView, name: String) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEWPI_UI_SNAPSHOTS"]
            ?? "/private/tmp/newpi-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        // 本轮失败不能留下同名旧图，让后续使用者误以为是本轮成功产物。
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try await settle(web)
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        config.afterScreenUpdates = true
        let webImage: NSImage
        do { webImage = try await web.takeSnapshot(configuration: config) }
        catch { throw Unavailable("WK takeSnapshot 失败：\(error)；未写入合成截图") }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Unavailable("NSHostingView 无法分配截图位图；未写入合成截图")
        }
        host.displayIfNeeded()
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // WK 远程图层未必进入 cacheDisplay：使用官方 WK 快照叠到相同窗口坐标，
        // 不用屏幕录制、DOM 重绘或替代 CSS，也不抓取用户其它窗口。
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let webTIFF = webImage.tiffRepresentation,
              let webBitmap = NSBitmapImageRep(data: webTIFF) else { throw Unavailable("WK 快照无法解码") }
                guard hasPixels(webBitmap) else {
                        throw Unavailable("WK snapshot 未检测到足够正文像素；未写入合成截图")
                }
                print("PASS: WK snapshot 含非空、非纯色的实际正文像素")
        bitmap.size = host.bounds.size
        let webRect = host.convert(web.bounds, from: web)
        // NSBitmapImageRep 像素从顶端计行，先排除 WebKit 区域检查原生 header/composer。
        let webPixelExclusion = NSRect(x: webRect.minX - host.bounds.minX,
            y: host.isFlipped ? webRect.minY - host.bounds.minY : host.bounds.maxY - webRect.maxY,
            width: webRect.width, height: webRect.height)
        guard hasPixels(bitmap, excluding: webPixelExclusion) else {
            throw Unavailable("NSView cacheDisplay 原生 header/composer 未检测到足够真实像素（已排除 WebKit）；不能验证原生合成截图，未写入 \(destination.path)")
        }
        print("PASS: NSView cacheDisplay 的原生 header/composer 区域含真实像素（排除 WebKit）")
        let target = NSRect(x: webRect.minX - host.bounds.minX,
            y: host.isFlipped ? host.bounds.maxY - webRect.maxY : webRect.minY - host.bounds.minY,
            width: webRect.width, height: webRect.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if ProcessInfo.processInfo.environment["NEWPI_WORKBENCH_FULL_WINDOW"] == "1",
           let split: NSSplitView = find(in: host), let sidebar = split.subviews.first {
            // Tahoe 玻璃外壳在根视图 cacheDisplay 中可能遮掉整列；尝试独立捕获真实侧栏子视图。
            var candidates: [NSView] = [sidebar]
            var captured = false
            while !candidates.isEmpty {
                let view = candidates.removeFirst()
                let frame = host.convert(view.bounds, from: view)
                if frame.width > 150 && frame.width < 260 && frame.height > 300,
                   let sideBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: sideBitmap)
                    sideBitmap.size = view.bounds.size
                    if hasPixels(sideBitmap) {
                        let image = NSImage(size: view.bounds.size)
                        image.addRepresentation(sideBitmap)
                        let rect = NSRect(x: frame.minX - host.bounds.minX,
                            y: host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY - host.bounds.minY,
                            width: frame.width, height: frame.height)
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        captured = true
                        print("SIDEBAR SNAPSHOT: captured actual \(type(of: view))")
                        break
                    }
                }
                candidates.append(contentsOf: view.subviews)
            }
            if !captured {
                skipped.append("\(name): glass sidebar pixels unavailable")
                print("UNVERIFIED: glass sidebar pixels unavailable in view snapshot; not a complete visual capture")
            }
        }
        webImage.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard hasPixels(bitmap), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure("原生/WebKit 合成截图为空")
        }
        try png.write(to: destination, options: .atomic)
        screenshots.append(destination.path)
        print("PASS: screenshot \(destination.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)，NSView + WK snapshot)")
    }

    private static func hasPixels(_ bitmap: NSBitmapImageRep, excluding rect: NSRect? = nil) -> Bool {
        guard bitmap.pixelsWide > 100, bitmap.pixelsHigh > 100 else { return false }
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 80)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 80)) {
                let point = NSPoint(x: CGFloat(x) * bitmap.size.width / CGFloat(bitmap.pixelsWide),
                    y: CGFloat(y) * bitmap.size.height / CGFloat(bitmap.pixelsHigh))
                if let rect, rect.contains(point) { continue }
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                if colors.count > 16 { return true }
            }
        }
        return false
    }

    private static func find<T: NSView>(in view: NSView, as type: T.Type = T.self) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found: T = find(in: child) { return found } }
        return nil
    }

    private static func eventually(_ label: String, unavailable: Bool = false, condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() { print("PASS: \(label)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if unavailable { throw Unavailable("\(label)：5s 内未从公开 AX 验证") }
        throw Failure("\(label)：5s 内未满足")
    }

    private static func settle(_ web: WKWebView) async throws {
        // 让 SwiftUI/AppKit 提交布局，再等待真实 WebKit 两帧；有界等待，不启动服务。
        try await Task.sleep(for: .milliseconds(180))
        _ = try await web.callAsyncJavaScript("""
            await new Promise((resolve, reject) => {
              const timeout = setTimeout(() => reject(new Error('WebKit frame timeout')), 2500);
              requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(timeout); resolve(); }));
            });
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
    }

    private static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label) }
        print("PASS: \(label)")
    }
}
