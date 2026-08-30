import AppKit
import Foundation
import NewPiCore
import SwiftUI
import UniformTypeIdentifiers

/// 工具执行状态（typed item 模型的结构化字段，替代原先从 body 文案解析 "Running …"）。
enum NewPiToolState: Equatable, Sendable {
    case running
    case completed(isError: Bool)
}

/// 转录条目类型（BACKLOG-TYPED-TRANSCRIPT）。
/// 类型是数据，显示文案是类型的派生——取代原先「把类型编码进 title/body 字符串、
/// UI 反向解析文案」的 stringly-typed 写法（改文案会静默破坏类型识别、
/// 结构化字段（工具名/状态/耗时）无处存放、thinking 无法入转录）。
enum NewPiTranscriptItemKind: Equatable, Sendable {
    case user
    case assistant
    case summary
    case system
    case error
    /// 思考过程（reasoning/thinking delta）。isStreaming=true 表示仍在流入。
    case thinking(isStreaming: Bool)
    case tool(name: String, state: NewPiToolState)
    /// 处理详情组的 disclosure 行（BACKLOG-DETAIL-GROUP）。collapsed 为自动逻辑的目标状态，
    /// JS 侧在未手动覆盖时采纳。
    case detailGroup(collapsed: Bool)
}

struct NewPiTranscriptItem: Identifiable, Sendable {
    let id: UUID
    let kind: NewPiTranscriptItemKind
    let body: String
    /// 工具条目的调用摘要（bash 命令本体 / 文件路径 / 紧凑 JSON），展开卡里与结果分开展示；
    /// 非工具条目为 nil。
    let toolCommand: String?
    let messageIndex: Int?
    let sessionEntryID: String?
    /// 处理详情组的 turn 归属（BACKLOG-DETAIL-GROUP）。非 nil 表示该条目属于某个详情组
    /// （thinking / tool / 中间 assistant）。最终答复与 marker 的语义见方案文档：
    /// marker 用 detailTurnID 标识它管理的组；组内条目用它归属到组；最终答复置 nil 移出组。
    let detailTurnID: String?
    /// 用户消息附带的图片附件（BACKLOG-IMAGE-INPUT）；仅 user 条目非空。
    let attachments: [MessageAttachment]

    init(
        id: UUID = UUID(),
        kind: NewPiTranscriptItemKind,
        body: String,
        toolCommand: String? = nil,
        messageIndex: Int? = nil,
        sessionEntryID: String? = nil,
        detailTurnID: String? = nil,
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.kind = kind
        self.body = body
        self.toolCommand = toolCommand
        self.messageIndex = messageIndex
        self.sessionEntryID = sessionEntryID
        self.detailTurnID = detailTurnID
        self.attachments = attachments
    }

    /// 显示用标题：从 kind 派生（保持既有显示/导出/日志文案不变）。
    /// 只用于展示，不要再拿它做类型判断——类型判断一律用 kind。
    var title: String {
        switch kind {
        case .user: "You"
        case .assistant: "NewPi"
        case .summary: "Summary"
        case .system: "System"
        case .error: "Error"
        case .thinking: "Thinking"
        case .tool(_, .running): "Tool"
        case .tool(let name, .completed): "Tool \(name)"
        case .detailGroup: "处理详情"
        }
    }

    var isUser: Bool { kind == .user }
    /// assistant/summary：走 markdown 渲染的正文类条目。
    var isAssistantMarkdown: Bool { kind == .assistant || kind == .summary }
    /// 流式中的 thinking 条目（用于高度表：流式期不入行高缓存，避免中间态高度污染缓存）。
    var isStreamingThinking: Bool {
        if case .thinking(true) = kind { return true }
        return false
    }

    var canFork: Bool {
        messageIndex != nil && (kind == .user || kind == .assistant || kind == .summary)
    }
}

struct NewPiProviderListItem: Identifiable, Equatable {
    let profile: ProviderProfile
    var hasAPIKey: Bool

    var id: String { profile.id }
}

/// 单个 Session 的独立运行态。
///
/// 每个 Session 拥有自己的一份转录、流式状态、进行中的审批、以及一个**常驻**的
/// 事件循环 task。即便 UI 切到别的 session，该 task 仍在后台读取本 session 的事件，
/// 持续更新它自己的转录与状态，从而做到会话隔离、互不阻塞。只有正在显示的那个
/// runtime 会被映射到 ViewModel 的 @Published 属性上。
@MainActor
final class SessionRuntime: ObservableObject {
    let session: AgentSession
    let fileURL: URL
    let sessionID: UUID
    /// 以下字段设为 @Published：每个会话的面板视图独立观察自己的 runtime，
    /// 后台会话的事件循环持续更新它，切回时视图无需重建即可显示最新状态。
    @Published var transcript: [NewPiTranscriptItem] = []
    @Published var isStreaming = false
    @Published var agentActivity: NewPiAgentActivity = .idle
    @Published var pendingToolApproval: ToolApprovalRequest?
    @Published var branchPointCount = 0
    @Published var isForkedBranch = false
    /// 本会话累计 token 用量（逐 assistant 消息累加；冷恢复时从历史消息重建）。
    @Published var totalUsage = UsageStats()
    /// 最近一次 assistant 回复的 token 用量（本轮）。
    @Published var lastTurnUsage = UsageStats()
    /// 本轮正文是否已完整落定（messageEnd(assistant) 收到）。
    /// 用于让流式气泡提前切换到完成态渲染（去 ✦ 光标、上 hljs 高亮），
    /// 不必等 agentEnd（它排在流式积压与收尾事件之后，实测会晚数秒）。
    @Published var streamingBubbleComplete = false
    /// 最终答复的正文已落定（messageEnd 且该消息无工具调用）：状态栏可提前翻回 ready，
    /// 不等排在收尾事件之后的 agentEnd（实测晚 2-6s，BACKLOG-STATUS-READY-LAG）。
    /// 保守原则：仅影响状态展示；isStreaming（Stop 按钮 / composer 禁用 / 钉底判定）不变。
    @Published var finalAnswerComplete = false
    /// 进行/已完成工具调用的命令摘要（toolCallID → 摘要）：start 时提取，end 时回填入条目，
    /// 覆盖「end 找不到 running 条目」的兜底分支。
    var toolCommands: [String: String] = [:]
    /// 处理详情分组（BACKLOG-DETAIL-GROUP）的 turn 状态。
    /// detailTurnID：当前 turn id（nil = 不在 turn 中）；detailGroupMarkerID：当前 turn 的
    /// disclosure 行条目 id（nil = 尚未创建 marker）；detailMarkerIDs：turnID → marker 条目 id，
    /// 跨 rebuild 复用，防止 fork/agentEnd 重建时 marker UUID 变化导致 DOM 闪烁。
    var detailTurnID: String?
    var detailGroupMarkerID: UUID?
    var detailMarkerIDs: [String: UUID] = [:]
    /// live turn 的用户消息条目 id → 当时的 live turnID（"live-..."）。
    /// 从单槽改为映射表：每轮 send 都登记一条，历史轮次在后续 agentEnd 的 rebuildTranscript
    /// 里也能通过 preservedID 查回原来的 live turnID，保证 turnID 跨多轮稳定（不翻成
    /// "turn-<entryID>"），detailMarkerIDs 与 JS 端 groupState/manualOverride（以 turnID 为
    /// key）始终命中，手动展开过的旧组不会被后续轮的 rebuild 重新收起。
    var detailLiveTurnIDByUser: [UUID: String] = [:]
    var liveMessageCount = 0
    var eventTask: Task<Void, Never>?
    /// 最近一次成为活跃会话的时间，用于缓存淘汰（LRU）。
    var lastUsedAt = Date()
    /// 流式文本增量合并缓冲：textDelta 先累积到这里，按节流间隔一次性合并进 transcript，
    /// 避免每个 delta 都触发 O(n) 字符串拼接与全量 UI 重渲染（见流式渲染优化）。
    var pendingStreamingDelta = ""
    /// 流式思考增量缓冲：与 pendingStreamingDelta 同管线同节流，flush 时先入 thinking 条目。
    var pendingThinkingDelta = ""
    var streamingFlushTask: Task<Void, Never>?

    init(session: AgentSession, fileURL: URL, sessionID: UUID) {
        self.session = session
        self.fileURL = fileURL
        self.sessionID = sessionID
    }
}

/// 后台构建一个全新 Session 的结果（在 `Task.detached` 中生成，主线程组装）。
private struct BuiltSessionPayload: Sendable {
    let session: AgentSession
    let header: SessionHeader
    let fileURL: URL
    let transcriptItems: [NewPiTranscriptItem]
    let branchPointCount: Int
    let isForkedBranch: Bool
    let liveMessageCount: Int
    /// 从历史消息重建的累计 / 最近一轮 token 用量（新建会话为零值）。
    let totalUsage: UsageStats
    let lastTurnUsage: UsageStats
}

/// 从历史消息累计 token 用量（纯函数，供后台线程调用）。
private func accumulateUsage(
    from messages: [AgentMessage]
) -> (total: UsageStats, lastTurn: UsageStats) {
    var total = UsageStats()
    var lastTurn = UsageStats()
    for message in messages {
        guard case let .assistant(assistant) = message else { continue }
        total.add(assistant.usage)
        lastTurn = assistant.usage
    }
    return (total, lastTurn)
}

/// 确定性的 turn id 规则（BACKLOG-DETAIL-GROUP A.4）：历史重建用
/// `"turn-<user消息entryID ?? index>"`，保证 rebuild 后 JS 端 manualOverride（以 turnID 为 key）能命中。
private func detailTurnID(userMessageIndex index: Int, entryID: String?) -> String {
    return "turn-\(entryID ?? String(index))"
}

/// 判定某条 assistant 消息是否「自身归属进组」（中间过程）：只有有工具调用才算。
/// 这是决定 assistant 条目 detailTurnID 的唯一依据：开了 thinking 但无 toolCalls 的
/// 最终答复仍是组外条目（review 意见2：reasoningContent 非空只意味着补一条 thinking
/// 组内条目，不代表 assistant 正文进组，否则最终答复会被折叠隐藏）。
private func assistantBelongsToGroup(_ assistant: AssistantMessage) -> Bool {
    return !assistant.toolCalls.isEmpty
}

/// 判定某条 assistant 消息是否为「组内条目」（用于预计算 turn 是否有组内条目，
/// 决定是否插入 marker）：有工具调用，或有思考内容。与 assistantBelongsToGroup 不同，
/// 这里只看「该 turn 是否产生中间过程」，thinking 也算，否则 marker 会缺失。
private func isDetailGroupItem(_ assistant: AssistantMessage) -> Bool {
    return !assistant.toolCalls.isEmpty || !assistant.reasoningContent.isEmpty
}

/// 由消息列表构建转录条目（纯函数，供后台线程调用；新建 session 的转录为空，
/// 无需保留既有条目的 id）。
private func makeTranscriptItems(
    from messages: [AgentMessage],
    entryIDs: [String]
) -> [NewPiTranscriptItem] {
    var items: [NewPiTranscriptItem] = []
    items.reserveCapacity(messages.count)
    // 上一条 assistant 消息的工具调用表：toolResult 只有结果没有参数，
    // 用 toolCallID 回查拿命令摘要（恢复会话后工具卡仍能展示命令）。
    var lastToolCalls: [String: ToolCallContent] = [:]
    // 处理详情分组（BACKLOG-DETAIL-GROUP）：当前 turn id；turn 内已产出过组内条目的标记。
    var currentTurnID: String? = nil
    var turnHasGroupItems = false

    // 首次遍历：预计算每个 user 消息之后（到下一个 user 前）该 turn 是否有组内条目，
    // 用于决定是否在 user 之后插入 marker。
    // 组内条目 = reasoningContent 非空的 assistant / toolCalls 非空的 assistant / toolResult。
    var turnHasGroupItemsByUserIndex: [Int: Bool] = [:]
    var lastUserIndex: Int? = nil
    for (index, message) in messages.enumerated() {
        if case .user = message {
            lastUserIndex = index
            turnHasGroupItemsByUserIndex[index] = false
        } else if let ui = lastUserIndex {
            let isGroup = makeTranscriptItems_isGroupMessage(message)
            if isGroup {
                turnHasGroupItemsByUserIndex[ui] = true
            }
        }
    }

    for (index, message) in messages.enumerated() {
        let entryID = index < entryIDs.count ? entryIDs[index] : nil
        switch message {
        case let .user(user):
            currentTurnID = detailTurnID(userMessageIndex: index, entryID: entryID)
            turnHasGroupItems = turnHasGroupItemsByUserIndex[index] ?? false
            items.append(NewPiTranscriptItem(
                kind: .user,
                body: user.content,
                messageIndex: index,
                sessionEntryID: entryID,
                attachments: user.attachments
            ))
            // marker 在 user 之后、组内条目之前插入（恢复默认收起）；无组内条目的 turn 不插。
            if turnHasGroupItems {
                items.append(NewPiTranscriptItem(kind: .detailGroup(collapsed: true), body: "", detailTurnID: currentTurnID))
            }
        case let .assistant(assistant):
            lastToolCalls = Dictionary(uniqueKeysWithValues: assistant.toolCalls.map { ($0.id, $0) })
            // 思考过程入转录（BACKLOG-TYPED-TRANSCRIPT）：reasoningContent 非空时
            // 在正文前补一条 thinking 条目。不带 messageIndex——它跟随正文条目进退，
            // 不参与 fork 锚点，也避免与正文条目争抢 id 保留表的同一 messageIndex。
            if !assistant.reasoningContent.isEmpty {
                items.append(NewPiTranscriptItem(
                    kind: .thinking(isStreaming: false),
                    body: assistant.reasoningContent,
                    detailTurnID: currentTurnID
                ))
            }
            // 组内 / 组外判定：有 toolCalls → 中间 assistant（组内）；否则最终答复（组外）。
            // 注意用 assistantBelongsToGroup（只认 toolCalls），开了 thinking 的最终答复
            // 不能打上 detailTurnID（否则会被折叠隐藏，review 意见2）。
            let assistantIsGroup = assistantBelongsToGroup(assistant)
            items.append(NewPiTranscriptItem(
                kind: .assistant,
                body: assistant.text,
                messageIndex: index,
                sessionEntryID: entryID,
                detailTurnID: assistantIsGroup ? currentTurnID : nil
            ))
        case let .toolResult(result):
            let command = lastToolCalls[result.toolCallID]
                .flatMap { newPiToolCommandSummary(name: $0.name, arguments: $0.arguments) }
            items.append(NewPiTranscriptItem(
                kind: .tool(name: result.toolName, state: .completed(isError: result.isError)),
                body: result.content,
                toolCommand: command,
                messageIndex: index,
                sessionEntryID: entryID,
                detailTurnID: currentTurnID
            ))
        case let .compactionSummary(summary):
            items.append(NewPiTranscriptItem(kind: .summary, body: summary, messageIndex: index, sessionEntryID: entryID))
        }
    }
    return items
}

/// 判定某条消息是否属于「组内条目」（用于预计算 turn 是否有组内条目）。
private func makeTranscriptItems_isGroupMessage(_ message: AgentMessage) -> Bool {
    switch message {
    case .assistant(let assistant):
        return isDetailGroupItem(assistant)
    case .toolResult:
        return true
    case .user, .compactionSummary:
        return false
    }
}

/// 工具调用参数 → 展示用命令摘要：bash 给命令本体，文件类工具给路径，
/// 其余给紧凑单行 JSON（截断防超长）。返回 nil 表示无可展示参数。
private func newPiToolCommandSummary(name: String, arguments: JSONValue) -> String? {
    guard let object = arguments.objectValue, !object.isEmpty else { return nil }
    switch name {
    case "bash", "shell":
        if let command = object["command"]?.stringValue, !command.isEmpty {
            return command
        }
    case "read", "write", "edit", "str_replace":
        if let path = object["path"]?.stringValue ?? object["file_path"]?.stringValue, !path.isEmpty {
            return path
        }
    default:
        break
    }
    guard let data = try? JSONEncoder().encode(arguments),
          var compact = String(data: data, encoding: .utf8) else { return nil }
    if compact.count > 300 {
        compact = String(compact.prefix(300)) + "…"
    }
    return compact
}

enum NewPiAgentActivity: Equatable {
    case idle
    case thinking
    case runningTool(String)
    case writing
}

@MainActor
final class NewPiViewModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var transcript: [NewPiTranscriptItem] = []
    @Published var isStreaming = false
    @Published var agentActivity: NewPiAgentActivity = .idle
    @Published var pendingToolApproval: ToolApprovalRequest?
    /// 见 SessionRuntime.finalAnswerComplete（状态栏提前翻 ready）。
    @Published var finalAnswerComplete = false
    @Published var providerConfig = ProviderConfigStore.bootstrapDefaultConfig()
    @Published var providerListItems: [NewPiProviderListItem] = []
    @Published var savedSessions: [SessionSummary] = []
    @Published var activeSessionID: UUID?
    @Published var activeProviderName = "Anthropic"
    @Published var activeProviderID: String?
    @Published var activeProviderModel = ""
    @Published var activeProviderReady = false
    @Published var branchPointCount = 0
    @Published var isForkedBranch = false
    /// 正在切换 session（后台构建中），UI 据此显示加载指示。
    @Published var isSwitchingSession = false
    /// 会话切换序号：同项目内连续切换时，只有「最后发起的那次」才算数（GLM review 意见2 竞态防护）。
    /// 防止"冷 A 慢构建 → 热 B 先切 → A 就绪后覆盖 B"把用户拽回未选择的会话。复用分支同样取号。
    private var sessionSwitchGeneration = 0

    private var runtimes: [String: SessionRuntime] = [:]
    private var activeRuntime: SessionRuntime? {
        didSet { reflectActive() }
    }
    private var session: AgentSession? { activeRuntime?.session }
    private var currentSessionFileURL: URL? { activeRuntime?.fileURL }
    private let providerConfigStore = ProviderConfigStore()
    private let providerCredentialResolver = ProviderCredentialResolver.makeDefault()
    @Published var useKeychainForCredentials = ProviderCredentialPreferences.load().useKeychain
    private let jsonlStore = JSONLSessionStore()
    private let sessionExporter = SessionExporter()
    private var cachedMCPTools: [MCPAgentTool]?
    private var mcpToolsLoadTask: Task<[MCPAgentTool], Never>?

    var agentStatusPresentation: NewPiAgentStatusPresentation {
        if pendingToolApproval != nil {
            return NewPiAgentStatusPresentation(
                systemImage: "hand.raised.circle",
                label: "NewPi is waiting for approval…",
                isActive: true
            )
        }
        if isStreaming && !finalAnswerComplete {
            switch agentActivity {
            case .idle:
                return NewPiAgentStatusPresentation(
                    systemImage: "sparkles",
                    label: "NewPi is working…",
                    isActive: true
                )
            case .thinking:
                return NewPiAgentStatusPresentation(
                    systemImage: "brain.head.profile",
                    label: "NewPi is thinking…",
                    isActive: true
                )
            case .writing:
                return NewPiAgentStatusPresentation(
                    systemImage: "text.append",
                    label: "NewPi is writing…",
                    isActive: true
                )
            case let .runningTool(name):
                return NewPiAgentStatusPresentation(
                    systemImage: NewPiAgentStatusPresentation.toolIcon(for: name),
                    label: "NewPi is running \(name)…",
                    isActive: true
                )
            }
        }
        if projectURL == nil {
            return NewPiAgentStatusPresentation(
                systemImage: "folder",
                label: "NewPi is ready — open a project",
                isActive: false
            )
        }
        return NewPiAgentStatusPresentation(
            systemImage: "checkmark.circle",
            label: "NewPi is ready",
            isActive: false
        )
    }

    var chatNavigationTitle: String {
        isForkedBranch ? "Chat (branch)" : "Chat"
    }

    /// 当前活跃 provider 的完整 profile（供能力检查、落盘等使用）。
    var activeProfile: ProviderProfile? {
        guard let id = activeProviderID else { return nil }
        return providerConfig.profiles.first(where: { $0.id == id })
    }

    /// 当前活跃 provider 的 preset（供上下文窗口目录表兜底使用）。
    private var activeProfilePreset: ProviderPreset? {
        activeProfile?.preset
    }

    /// 状态栏「上下文占用」文本：`上下文 9.2% / 1.0M`。
    ///
    /// - 分子：最近一轮请求的真实输入 token（未命中缓存 + 命中缓存 + 写缓存，
    ///   即 `UsageStats.totalInputTokens`），代表当前上下文实际占用的输入量。
    /// - 分母：当前模型的上下文窗口大小（来自 `ContextWindowCatalog` 内置目录表）。
    ///
    /// 无输入数据（尚未产生任何请求）或查不到窗口大小时返回 nil（不显示）。
    func contextUsageText(for usage: UsageStats) -> String? {
        let input = usage.totalInputTokens
        guard input > 0, let preset = activeProfilePreset else { return nil }
        let window = ContextWindowCatalog.windowTokens(for: activeProviderModel, preset: preset)
        guard window > 0 else { return nil }

        let percent = Double(input) / Double(window) * 100
        // 极低占用（<0.05%）显示 0.0 会误导，仍给一位小数；上限钳制到 999% 避免越界。
        let clamped = min(percent, 999.9)
        let percentText = String(format: "%.1f%%", clamped)
        let windowText = Self.compactTokenCount(window)
        return "上下文 \(percentText) / \(windowText)"
    }

    /// 紧凑 token 计数：≥1M 显示 `x.xM`，≥10k 显示 `xk`，≥1k 显示 `x.xk`，否则原值。
    private static func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    init() {
        Task {
            await reloadProviders()
            await restoreLastProjectIfNeeded()
        }
    }

    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if let lastProject = NewPiLastProjectStore.load() {
            panel.directoryURL = lastProject
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await openProject(at: url)
        }
    }

    func restoreLastProjectIfNeeded() async {
        guard projectURL == nil, let url = NewPiLastProjectStore.load() else { return }
        await openProject(at: url)
    }

    func openProject(at url: URL) async {
        let newURL = url.standardizedFileURL
        // 切换到不同项目：先停掉并清理上个项目的后台 sessions（避免其继续运行/泄漏）。
        // 注意必须排除「启动时 nil → 首个项目」：否则每次冷启动都清空高度缓存，
        // 让「启动自动恢复上次会话」退化为全量 cache-miss（预热 9-13s、滚动条频繁跳动）。
        if let current = projectURL, newURL != current {
            await stopAllLiveSessions()
        }
        projectURL = newURL
        NewPiLastProjectStore.save(url)
        NewPiLogStore.shared.setProjectDirectory(projectURL)
        NewPiLogger.info(
            category: "app",
            message: "Project opened",
            details: """
            path=\(url.path)
            projectLog=\(NewPiFileLogSink.shared.projectLogURL(for: url).path)
            """
        )
        await cleanupEmptySessions()
        await refreshSessionList()
        // 不自动创建新会话：改为恢复该项目上次离开时的会话（启动恢复与手动切项目共用）；
        // 找不到（已删除/归档）则保持无活跃会话，由用户手动选择或新建。
        await restoreLastSessionIfPossible()
        // 预热 MCP 工具（后台，不阻塞打开流程），让用户首次切换 session 时无需当场等待。
        Task { await self.loadMCPTools() }
    }

    /// 打开项目后恢复上次离开时的活跃会话。
    /// 会话文件已删除/归档（不在会话列表中）时不恢复，静默回退到「无活跃会话」。
    private func restoreLastSessionIfPossible() async {
        guard let projectURL,
              let lastSessionURL = NewPiLastSessionStore.load(for: projectURL),
              FileManager.default.fileExists(atPath: lastSessionURL.path),
              let summary = savedSessions.first(where: {
                  $0.fileURL.standardizedFileURL == lastSessionURL
              })
        else { return }
        await resumeSession(summary)
    }

    /// 记录当前活跃会话，供下次打开 App / 项目时自动恢复。
    private func rememberActiveSession(fileURL: URL) {
        guard let projectURL else { return }
        NewPiLastSessionStore.save(sessionFileURL: fileURL, for: projectURL)
    }

    /// 停止并清空所有后台的 AgentSession（在切换项目等场景下调用）。
    private func stopAllLiveSessions() async {
        for runtime in runtimes.values {
            runtime.eventTask?.cancel()
            await runtime.session.shutdown()
        }
        runtimes.removeAll()
        activeRuntime = nil
    }

    /// runtime 缓存上限（不含当前活跃）：超出后按最久未使用淘汰。
    /// 会话面板视图需要保活，内存随保活数增长；上限 5，配合共享进程池控制开销。
    /// 被淘汰的会话切回时走冷重建（配合高度缓存）+ 快照兜底。
    private static let maxCachedRuntimes = 5

    /// 当前保活的所有会话 runtime（含活跃），按最近使用排序。供聊天面板保活渲染。
    var keptAliveRuntimes: [SessionRuntime] {
        Array(runtimes.values).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// 判断某个 runtime 是否为当前活跃会话（用于面板的显示/交互翻转）。
    func isActiveRuntime(_ runtime: SessionRuntime) -> Bool {
        runtime === activeRuntime
    }

    private func evictIdleRuntimesIfNeeded() {
        while runtimes.count > Self.maxCachedRuntimes {
            guard let victim = runtimes.values
                // 不淘汰仍在流式、或有待处理工具审批的会话，避免中断后台输出。
                .filter({ $0 !== activeRuntime && !$0.isStreaming && $0.pendingToolApproval == nil })
                .min(by: { $0.lastUsedAt < $1.lastUsedAt })
            else { return }
            NewPiLogger.info(
                category: "app",
                message: "Evicting idle session runtime",
                details: "sessionFile=\(victim.fileURL.path)"
            )
            victim.eventTask?.cancel()
            runtimes.removeValue(forKey: victim.fileURL.path)
            let session = victim.session
            Task { await session.shutdown() }
        }
    }

    func reloadProviders() async {
        do {
            useKeychainForCredentials = ProviderCredentialPreferences.load().useKeychain
            providerConfig = try providerConfigStore.load()
            await refreshProviderList()
            if projectURL != nil {
                await cleanupEmptySessions()
                await refreshSessionList()
                // 不自动新建会话（BACKLOG-SESSION-MANUAL-CREATE）。
            }
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func refreshSessionList() async {
        guard let projectURL else {
            savedSessions = []
            return
        }
        let projectPath = projectURL
        let summaries = await Task.detached(priority: .userInitiated) {
            (try? SessionManager.listSessions(for: projectPath)) ?? []
        }.value
        // 竞态防护：detached 遍历期间用户可能已切换项目，
        // 旧项目的结果不得写回 UI。
        guard self.projectURL == projectPath else { return }
        savedSessions = summaries
    }

    func setUseKeychainForCredentials(_ enabled: Bool) {
        useKeychainForCredentials = enabled
        ProviderCredentialPreferences(useKeychain: enabled).save()
    }

    func refreshProviderList() async {
        var items: [NewPiProviderListItem] = []
        for profile in providerConfig.profiles {
            let hasKey = await providerCredentialResolver.hasAPIKey(for: profile)
            items.append(NewPiProviderListItem(profile: profile, hasAPIKey: hasKey))
        }
        providerListItems = items

        // 有活跃会话时显示该会话自己选择的 provider（会话内切换记进 header，逐会话记忆）；
        // 无活跃会话时显示默认 provider（新建会话将使用它）。
        if let session = activeRuntime?.session,
           let header = await session.attachedSessionHeader,
           let sessionProfile = try? resolveProfile(for: header) {
            await setActiveProviderState(sessionProfile)
        } else if let defaultProfile = try? providerConfig.defaultProfile() {
            activeProviderID = defaultProfile.id
            activeProviderName = defaultProfile.name
            activeProviderModel = defaultProfile.modelID
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: defaultProfile)
        }
    }

    func switchProvider(profileID: String) async {
        guard let profile = providerConfig.profiles.first(where: { $0.id == profileID }) else { return }
        await switchModel(profileID: profileID, modelID: profile.modelID)
    }

    /// 会话内切换模型（BACKLOG-STATUSBAR-MODEL-PICKER）：选择粒度是「具体模型」，
    /// provider 仅作为分组。同时把该模型持久化为 provider 的默认模型（记住上次选择）。
    func switchModel(profileID: String, modelID: String) async {
        guard !isStreaming else { return }
        guard let projectURL else { return }
        guard var profile = providerConfig.profiles.first(where: { $0.id == profileID }) else { return }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        // 目标与当前一致：无副作用，直接返回。
        if activeProviderID == profileID, activeProviderModel == trimmedModel { return }

        do {
            profile.modelID = trimmedModel
            profile.addModel(trimmedModel)
            // 记住该 provider 最近选用的模型；无活跃会话时选择即「之后新会话用什么」，
            // 同步设为默认 provider（否则状态栏会回落显示旧默认）。
            try providerConfigStore.upsertProfile(profile, in: &providerConfig, setAsDefault: session == nil)

            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            let mcpTools = await loadMCPTools()
            let newConfig = AgentLoopConfig(
                model: profile.modelConfig,
                llm: llm,
                tools: AgentSessionFactory.codingTools(
                    workingDirectory: projectURL,
                    llm: llm,
                    model: profile.modelConfig,
                    additionalTools: mcpTools
                ),
                toolPolicy: .codingAgentDefault
            )
            await session?.updateConfig(newConfig)

            NewPiLogger.info(
                category: "app",
                message: "Model switched",
                details: """
                provider=\(profile.name)
                model=\(profile.modelID)
                mcpTools=\(mcpTools.count)
                """
            )

            if let session,
               var header = await session.attachedSessionHeader {
                header.providerProfileID = profile.id
                header.modelID = profile.modelID
                // 立即落盘：切换后未发消息就退出 App，也要记住该会话的模型选择。
                await session.updateSessionHeader(header)
            }

            await refreshProviderList()
            await setActiveProviderState(profile)
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    /// 状态栏模型菜单的分组数据源（按 provider 分组，组内为该 provider 的模型列表）。
    var providerModelGroups: [NewPiProviderModelGroup] {
        providerListItems.map { item in
            let definition = ProviderPresetCatalog.definition(for: item.profile.preset)
            return NewPiProviderModelGroup(
                profileID: item.profile.id,
                profileName: item.profile.name,
                systemImage: definition.systemImage,
                hasAPIKey: item.hasAPIKey || !definition.credentialRequired,
                models: item.profile.models
            )
        }
    }

    func setDefaultProvider(profileID: String) async {
        providerConfig.defaultProfileID = profileID
        do {
            try providerConfigStore.save(providerConfig)
            await refreshProviderList()
            // 新默认 provider 只影响之后新建的会话；已有会话保持自己选择的
            // provider 不变（会话内切换走侧边栏 Picker，随 session header 持久化）。
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func saveProfile(_ profile: ProviderProfile, apiKeyDraft: String) async {
        do {
            let isNew = !providerConfig.profiles.contains(where: { $0.id == profile.id })
            let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            // 留空表示保留已保存的 key（UI 文案 "Leave blank to keep the existing key."）；
            // 空值传到 resolver 会被解释为删除凭据。
            if !trimmedKey.isEmpty {
                try await providerCredentialResolver.saveAPIKey(trimmedKey, for: profile)
            }

            var setAsDefault = isNew
            if !setAsDefault,
               !trimmedKey.isEmpty,
               let defaultProfile = try? providerConfig.defaultProfile(),
               defaultProfile.id != profile.id,
               !(await providerCredentialResolver.hasAPIKey(for: defaultProfile)) {
                setAsDefault = true
            }

            try providerConfigStore.upsertProfile(
                profile,
                in: &providerConfig,
                setAsDefault: setAsDefault
            )
            await refreshProviderList()
            // 不自动新建会话、不改已有会话的 provider：新默认只作用于新建会话。
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func deleteProfile(id: String) async {
        do {
            try providerConfigStore.deleteProfile(id: id, from: &providerConfig)
            await refreshProviderList()
            // 不自动新建会话、不改已有会话的 provider：新默认只作用于新建会话。
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func resetSession() async {
        // 手动入口语义保留：reset 由用户显式触发，等价于手动 New Session。
        await startNewSession()
    }

    /// 新会话的唯一创建入口（侧边栏 New Session 按钮 / ⇧⌘N）。
    /// 打开项目、切换/保存/删除 provider、归档会话等场景一律不再自动调用。
    func startNewSession() async {
        await beginSession(restoredContext: nil, fileURL: nil)
    }

    func resumeSession(_ summary: SessionSummary) async {
        guard summary.fileURL != currentSessionFileURL else { return }

        do {
            let fileURL = summary.fileURL
            let context = try await Task.detached(priority: .userInitiated) {
                try JSONLSessionStore().load(from: fileURL)
            }.value
            await beginSession(restoredContext: context, fileURL: fileURL)
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func archiveSession(_ summary: SessionSummary) async {
        do {
            let wasCurrent = summary.fileURL == currentSessionFileURL
            // 归档的是当前会话：结束后自动切到同项目的下一个会话——
            // 优先它在列表中的下一条；归档的是末条则回退到最新一条。
            // （同项目无更多会话时保持空态；暂不支持自动跨项目切换。）
            var nextSummary: SessionSummary?
            if wasCurrent {
                if let index = savedSessions.firstIndex(where: { $0.id == summary.id }) {
                    let below = savedSessions.index(after: index)
                    if below < savedSessions.endIndex {
                        nextSummary = savedSessions[below]
                    }
                }
                if nextSummary == nil {
                    nextSummary = savedSessions.first(where: { $0.id != summary.id })
                }
                // 先关闭当前会话（shutdown 会把 pending 内容落盘，header.archived 仍为 false），
                // 再打归档标记。否则 setArchived 之后 shutdown 的 persistIfNeeded 会用内存中
                // 缓存的 header（archived=false）重新保存，把归档标记覆盖掉——
                // 表现为「归档的会话不会立即从列表消失」（ARCHIVE-IMMEDIATE-REFRESH）。
                await closeActiveSession()
            }
            try await Task.detached(priority: .userInitiated) {
                try SessionManager.setArchived(true, for: summary.fileURL)
            }.value
            await refreshSessionList()
            if let nextSummary {
                await resumeSession(nextSummary)
            }
            NewPiLogger.info(
                category: "app",
                message: "Session archived",
                details: summary.fileURL.lastPathComponent
            )
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    /// 结束当前活跃会话：停掉事件循环、移除 runtime、清空活跃状态。
    /// 之后用户需手动点击 New Session 或从历史列表恢复会话。
    private func closeActiveSession() async {
        guard let runtime = activeRuntime else { return }
        runtime.eventTask?.cancel()
        runtimes.removeValue(forKey: runtime.fileURL.path)
        activeRuntime = nil
        activeSessionID = nil
        // 会话已结束（如被归档）：清掉「最后活跃会话」记录，避免下次启动恢复一个已归档会话。
        if let projectURL {
            NewPiLastSessionStore.clear(for: projectURL)
        }
        await runtime.session.shutdown()
    }

    func renameSession(_ summary: SessionSummary, to newLabel: String) async {
        // 空串/纯空白视为「重置为默认显示名」（label 存 nil，显示层回落显示创建时间）。
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel: String? = trimmed.isEmpty ? nil : trimmed

        do {
            if summary.fileURL == currentSessionFileURL,
               let session = activeRuntime?.session {
                // 活动会话：必须同时更新 AgentSession 内存态并落盘，否则下一次
                // persistIfNeeded() 会用内存里的旧 header 覆盖掉新 label（重命名丢失根因）。
                await session.setSessionLabel(finalLabel)
            } else {
                // 非活动会话：无运行中的内存态，直接写磁盘即可。
                try await Task.detached(priority: .userInitiated) {
                    try SessionManager.updateLabel(finalLabel ?? "", for: summary.fileURL)
                }.value
            }
            await refreshSessionList()
            NewPiLogger.info(
                category: "app",
                message: "Session renamed",
                details: "\(summary.fileURL.lastPathComponent) → \(finalLabel ?? "<default>")"
            )
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
        }
    }

    func forkFromMessage(index: Int) async {
        guard !isStreaming, let runtime = activeRuntime else { return }
        let session = runtime.session
        do {
            try await session.fork(atMessageIndex: index)
            let messages = await session.context.messages
            rebuildTranscript(from: messages, entryIDs: await session.branchEntryIDs(), on: runtime)
            runtime.branchPointCount = await session.branchPointCount()
            runtime.isForkedBranch = runtime.branchPointCount > 0
            reflectActive()
            appendTranscript(
                kind: .system,
                body: "Forked conversation from message \(index + 1). New replies continue on this branch.",
                on: runtime
            )
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription, on: runtime)
        }
    }

    func exportCurrentSession(format: SessionExportFormat) async -> String? {
        if let session {
            let header = await session.attachedSessionHeader
            let messages = await session.context.messages
            if let header {
                switch format {
                case .markdown:
                    return sessionExporter.exportMarkdown(
                        context: SessionContext(header: header),
                        messages: messages,
                        leafID: await session.activeBranchLeafID
                    )
                case .text:
                    return sessionExporter.exportText(messages: messages)
                case .json:
                    if let fileURL = currentSessionFileURL,
                       let context = try? jsonlStore.load(from: fileURL),
                       let data = try? sessionExporter.exportJSON(context: context) {
                        return String(data: data, encoding: .utf8)
                    }
                    return nil
                }
            }
        }

        if !transcript.isEmpty {
            let items = transcript.map { (title: $0.title, body: $0.body) }
            switch format {
            case .markdown:
                return sessionExporter.exportTranscriptMarkdown(items: items)
            case .text:
                return items.map { "\($0.title): \($0.body)" }.joined(separator: "\n\n")
            case .json:
                return nil
            }
        }

        return nil
    }

    func exportSessionToFile(format: SessionExportFormat) async {
        guard let content = await exportCurrentSession(format: format) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportFilename(format: format)
        panel.allowedContentTypes = exportContentTypes(for: format)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func defaultExportFilename(format: SessionExportFormat) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        switch format {
        case .markdown:
            return "new-pi-session-\(stamp).md"
        case .json:
            return "new-pi-session-\(stamp).json"
        case .text:
            return "new-pi-session-\(stamp).txt"
        }
    }

    private func exportContentTypes(for format: SessionExportFormat) -> [UTType] {
        switch format {
        case .markdown:
            return [.plainText]
        case .json:
            return [.json]
        case .text:
            return [.plainText]
        }
    }

    private func beginSession(restoredContext: SessionContext?, fileURL: URL?) async {
        guard let projectURL else { return }
        isSwitchingSession = true
        defer { isSwitchingSession = false }

        // 切换序号（GLM review 意见2）：每次发起取号，冷恢复 await 后校验，防同项目连点竞态。
        let generation = sessionSwitchGeneration + 1
        sessionSwitchGeneration = generation

        let profile: ProviderProfile
        do {
            profile = try resolveProfile(for: restoredContext?.header)
        } catch {
            appendTranscript(kind: .error, body: error.localizedDescription)
            activeProviderReady = false
            return
        }

        // 复用已有的 runtime：不重建 agent / 不读文件 / 不加载 MCP，直接轻量切换并反映当前状态。
        if let fileURL, let existing = runtimes[fileURL.path] {
            NewPiLogger.info(category: "app", message: "Resumed live agent session", details: fileURL.path)
            if let header = await existing.session.attachedSessionHeader {
                activeSessionID = header.id
                // 显示该会话自己选择的 provider（而不是默认 provider）：
                // 会话内的 provider 切换记进了 header，切回时要原样反映。
                let sessionProfile = (try? resolveProfile(for: header)) ?? profile
                existing.lastUsedAt = Date()
                activeRuntime = existing
                rememberActiveSession(fileURL: fileURL)
                await setActiveProviderState(sessionProfile)
                return
            }
            existing.lastUsedAt = Date()
            activeRuntime = existing
            rememberActiveSession(fileURL: fileURL)
            await setActiveProviderState(profile)
            return
        }

        let restoredMessages = restoredContext.map { SessionManager.messages(from: $0) } ?? []
        let restoredHeader = restoredContext?.header

        // 新建 runtime：把重活（构建 agent / 读写 session 文件 / 重建 transcript）放到
        // 后台线程，主线程只做最终状态切换，避免切换卡顿、对话加载慢。
        do {
            let mcpTools = await loadMCPTools()
            let resolver = providerCredentialResolver

            let payload = try await Task.detached(priority: .userInitiated) { () throws -> BuiltSessionPayload in
                let llm = try LLMProviderFactory.make(profile: profile, credentialResolver: resolver)
                let session: AgentSession
                let header: SessionHeader
                let sessionFileURL: URL
                if let fileURL {
                    let built = AgentSessionFactory.codingSession(
                        workingDirectory: projectURL,
                        llm: llm,
                        model: profile.modelConfig,
                        restoredMessages: restoredMessages,
                        additionalTools: mcpTools
                    )
                    let h = restoredHeader ?? SessionHeader(workingDirectory: projectURL)
                    await built.attachPersistence(fileURL: fileURL, header: h)
                    session = built
                    header = h
                    sessionFileURL = fileURL
                } else {
                    let created = try SessionManager.createSession(
                        workingDirectory: projectURL,
                        providerProfileID: profile.id,
                        modelID: profile.modelID
                    )
                    let built = AgentSessionFactory.codingSession(
                        workingDirectory: projectURL,
                        llm: llm,
                        model: profile.modelConfig,
                        additionalTools: mcpTools
                    )
                    await built.attachPersistence(fileURL: created.fileURL, header: created.context.header)
                    session = built
                    header = created.context.header
                    sessionFileURL = created.fileURL
                }

                let messages = await session.context.messages
                let entryIDs = await session.branchEntryIDs()
                let branchPointCount = await session.branchPointCount()
                let usage = accumulateUsage(from: messages)
                return BuiltSessionPayload(
                    session: session,
                    header: header,
                    fileURL: sessionFileURL,
                    transcriptItems: makeTranscriptItems(from: messages, entryIDs: entryIDs),
                    branchPointCount: branchPointCount,
                    isForkedBranch: branchPointCount > 0,
                    liveMessageCount: messages.count,
                    totalUsage: usage.total,
                    lastTurnUsage: usage.lastTurn
                )
            }.value

            // 竞态防护：构建期间（MCP 启动可能耗时数秒）用户可能已切换项目，
            // 此时旧项目的 runtime 不得注册为活跃会话，直接丢弃。
            guard self.projectURL == projectURL else {
                NewPiLogger.info(
                    category: "app",
                    message: "Discarding session built for previous project",
                    details: "sessionFile=\(payload.fileURL.path)"
                )
                await payload.session.shutdown()
                return
            }

            let runtime = SessionRuntime(session: payload.session, fileURL: payload.fileURL, sessionID: payload.header.id)
            runtimes[payload.fileURL.path] = runtime
            evictIdleRuntimesIfNeeded()
            startRuntimeEventLoop(runtime)
            NewPiLogger.info(
                category: "app",
                message: "Beginning agent session",
                details: """
                project=\(projectURL.path)
                restored=\(restoredContext != nil)
                sessionFile=\(payload.fileURL.path)
                """
            )

            // 先填好 runtime 状态，再切 activeRuntime（didSet 反射时携带完整数据）。
            runtime.transcript = payload.transcriptItems
            runtime.branchPointCount = payload.branchPointCount
            runtime.isForkedBranch = payload.isForkedBranch
            runtime.liveMessageCount = payload.liveMessageCount
            runtime.totalUsage = payload.totalUsage
            runtime.lastTurnUsage = payload.lastTurnUsage
            runtime.lastUsedAt = Date()

            // 竞态防护（下层 :744 只防跨项目换项目；这里再防同项目内「冷 A 慢构建 → 热 B 先切 → A 覆盖 B」——
            // GLM review 意见2，现状已有问题）：只有「最后发起」的那次才允许激活。
            guard self.projectURL == projectURL,
                  self.runtimes[payload.fileURL.path] === runtime,
                  generation == self.sessionSwitchGeneration else {
                return
            }

            activeRuntime = runtime
            activeSessionID = payload.header.id
            rememberActiveSession(fileURL: payload.fileURL)

            await setActiveProviderState(profile)

            if restoredContext == nil {
                // 后台刷新侧边列表，避免遍历会话文件拖慢切换完成。
                Task { await self.refreshSessionList() }
            }
            NewPiLogger.info(
                category: "app",
                message: "Agent session ready",
                details: """
                provider=\(profile.name) model=\(profile.modelID)
                mcpTools=\(mcpTools.count)
                restoredMessages=\(restoredMessages.count)
                sessionFile=\(payload.fileURL.path)
                """
            )
        } catch {
            NewPiLogger.error(
                category: "app",
                message: "Failed to begin session",
                details: error.localizedDescription
            )
            appendTranscript(kind: .error, body: error.localizedDescription)
            activeProviderReady = false
        }
    }

    /// 把当前 provider 状态同步到 @Published（供两个分支复用）。
    private func setActiveProviderState(_ profile: ProviderProfile) async {
        activeProviderID = profile.id
        activeProviderName = profile.name
        activeProviderModel = profile.modelID
        activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)
    }

    func send(_ text: String) {
        send(text, draftAttachments: [])
    }

    /// 发送用户消息，可携带图片附件（BACKLOG-IMAGE-INPUT）。
    ///
    /// 发送前做能力拦截：当前模型不支持图片时给出明确提示且不发送；
    /// 附件先落盘到会话附件目录（`SessionAttachments`），再组装成 `UserMessage`。
    func send(_ text: String, draftAttachments: [DraftImageAttachment]) {
        guard let runtime = activeRuntime else {
            appendTranscript(
                kind: .system,
                body: projectURL == nil
                    ? "Open a project first."
                    : "Start a new session first (⇧⌘N)."
            )
            return
        }

        // 能力拦截：有图片但当前模型不支持 → 提示且不发送。
        if !draftAttachments.isEmpty {
            guard let profile = activeProfile, profile.supportsImages(modelID: activeProviderModel) else {
                let modelName = activeProviderModel.isEmpty ? "当前模型" : activeProviderModel
                appendTranscript(
                    kind: .error,
                    body: "当前模型 \(modelName) 不支持图片输入。请在设置中为该模型开启「支持图片识别」，或切换到支持图片的模型。"
                )
                return
            }
        }

        // 附件落盘：解码/缩放/压缩已在采集层完成，这里做体积校验 + 写入 + 组装路径引用。
        var attachments: [MessageAttachment] = []
        if !draftAttachments.isEmpty {
            do {
                let dir = try SessionAttachments.directory(for: runtime.sessionID)
                for draft in draftAttachments {
                    if let tooLarge = ImageAttachmentProcessor.validate(draft) {
                        appendTranscript(kind: .error, body: tooLarge)
                        return
                    }
                    let ext = Self.fileExtension(for: draft.mediaType)
                    let fileName = "\(draft.id.uuidString).\(ext)"
                    try draft.data.write(to: dir.appendingPathComponent(fileName))
                    let relativePath = "\(runtime.sessionID.uuidString)/\(fileName)"
                    attachments.append(
                        MessageAttachment(
                            mediaType: draft.mediaType,
                            path: relativePath,
                            displayName: draft.displayName,
                            note: draft.note
                        )
                    )
                }
            } catch {
                appendTranscript(kind: .error, body: "无法保存图片附件：\(error.localizedDescription)")
                return
            }
        }

        // 新 turn 开始（BACKLOG-DETAIL-GROUP）：重置当前 turn 状态，marker 留待首条组内条目懒创建。
        let liveTurnID = "live-\(UUID().uuidString)"
        runtime.detailTurnID = liveTurnID
        runtime.detailGroupMarkerID = nil
        // 记录这条 user 条目的 messageIndex（= 已同步消息数，rebuild 时该 user 在 messages 里的
        // 位置与此一致），使 rebuild 的 preservedTranscriptID 能通过 messageIndex 命中稳定 id；
        // 同时把 user 条目 id → live turnID 登记进映射表（review「🟡 turnID 稳定性」修复），
        // rebuild 时据此复用 live turnID，历史轮次也能保持 turnID 稳定，避免手动展开状态丢失。
        let userItemID = appendTranscript(
            kind: .user,
            body: text,
            messageIndex: runtime.liveMessageCount,
            attachments: attachments,
            on: runtime
        )
        runtime.detailLiveTurnIDByUser[userItemID] = liveTurnID
        runtime.isStreaming = true
        runtime.agentActivity = .thinking
        reflectActive()
        NewPiLogger.info(category: "app", message: "User message sent", details: NewPiLogFormat.truncate(text, maxLength: 1000))
        let message = attachments.isEmpty
            ? AgentMessage.user(text)
            : AgentMessage.user(text, attachments: attachments)
        Task {
            await runtime.session.prompt(message)
        }
    }

    /// MIME 类型 → 文件扩展名。
    private static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "png"
        }
    }

    func approvePendingTool(scope: ApprovalScope = .once) {
        guard let request = pendingToolApproval, let runtime = activeRuntime else {
            NewPiLogger.error(category: "app", message: "Approve tapped with no pending request")
            return
        }
        NewPiLogger.info(
            category: "app",
            message: "User approved tool",
            details: "requestID=\(request.id) tool=\(request.toolName) scope=\(scope.rawValue)"
        )
        runtime.pendingToolApproval = nil
        reflectActive()
        Task {
            await runtime.session.respondToToolApproval(requestID: request.id, approved: true, scope: scope)
        }
    }

    func denyPendingTool() {
        guard let request = pendingToolApproval, let runtime = activeRuntime else {
            NewPiLogger.error(category: "app", message: "Deny tapped with no pending request")
            return
        }
        NewPiLogger.info(
            category: "app",
            message: "User denied tool",
            details: "requestID=\(request.id) tool=\(request.toolName)"
        )
        runtime.pendingToolApproval = nil
        reflectActive()
        Task {
            await runtime.session.respondToToolApproval(requestID: request.id, approved: false)
        }
    }

    func abort() {
        NewPiLogger.info(category: "app", message: "User aborted agent run")
        guard let runtime = activeRuntime else { return }
        flushStreamingDelta(on: runtime)
        runtime.pendingToolApproval = nil
        runtime.agentActivity = .idle
        reflectActive()
        Task {
            await runtime.session.abort()
            runtime.isStreaming = false
            reflectActive()
        }
    }

    /// 为某个 runtime 建立常驻事件循环：持续读取该 AgentSession 的事件，更新它自己
    /// 的转录与状态。**不会**因 UI 切到其它 session 而取消，从而保证后台 session 的
    /// 输出一直累积在自己名下。
    private func startRuntimeEventLoop(_ runtime: SessionRuntime) {
        runtime.eventTask?.cancel()
        let session = runtime.session
        runtime.eventTask = Task { @MainActor in
            let stream = await session.events()
            // 诊断：记录 agent 起点与上一事件的处理间隔，定位「LLM 已完、UI 未更新」的延迟。
            var runStartedAt: Date?
            var lastEventHandledAt = Date()
            for await event in stream {
                let now = Date()
                let gap = now.timeIntervalSince(lastEventHandledAt)
                if gap > 0.5 {
                    NewPiLogger.info(
                        category: "app",
                        message: "UI event loop stall",
                        details: "gap=\(String(format: "%.2f", gap))s nextEvent=\(event.diagnosticName)"
                    )
                }
                if case .agentStart = event { runStartedAt = now }
                if case .agentEnd = event, let runStartedAt {
                    NewPiLogger.info(
                        category: "app",
                        message: "UI: run wall time",
                        details: "elapsed=\(String(format: "%.2f", now.timeIntervalSince(runStartedAt)))s"
                    )
                }
                handle(event, on: runtime)
                lastEventHandledAt = Date()
            }
        }
    }

    /// 把 activeRuntime 的状态映射到 @Published 属性上，供 SwiftUI 渲染当前会话。
    private func reflectActive() {
        guard let r = activeRuntime else {
            transcript = []
            isStreaming = false
            agentActivity = .idle
            pendingToolApproval = nil
            branchPointCount = 0
            isForkedBranch = false
            return
        }
        transcript = r.transcript
        isStreaming = r.isStreaming
        agentActivity = r.agentActivity
        pendingToolApproval = r.pendingToolApproval
        finalAnswerComplete = r.finalAnswerComplete
        branchPointCount = r.branchPointCount
        isForkedBranch = r.isForkedBranch
    }

    private func handle(_ event: AgentEvent, on runtime: SessionRuntime) {
        // 非文本事件是状态边界：先把未合并的流式增量冲刷掉，保证内容顺序一致且不丢失。
        switch event {
        case .messageStart, .messageEnd, .toolExecutionStart, .toolExecutionEnd, .agentEnd, .error:
            flushStreamingDelta(on: runtime)
        default:
            break
        }

        var hasVisibleStateChange = true
        switch event {
        case .agentStart:
            runtime.isStreaming = true
            runtime.agentActivity = .thinking
            runtime.streamingBubbleComplete = false
            runtime.finalAnswerComplete = false
            NewPiLogger.info(category: "app", message: "UI: agent started")
        case let .messageStart(message):
            NewPiLogger.debug(category: "app", message: "UI: message started", details: message.roleLabel)
            if case let .compactionSummary(summary) = message {
                appendTranscript(kind: .summary, body: summary, on: runtime)
                NewPiLogger.info(
                    category: "agent",
                    message: "Context compacted",
                    details: "Summary length: \(summary.count) characters"
                )
            }
        case let .messageEnd(message):
            // token 用量累计：assistant 消息落定即累加，状态栏实时反映（BACKLOG-TOKEN-BAR）。
            if case let .assistant(assistant) = message,
               assistant.usage.inputTokens > 0 || assistant.usage.outputTokens > 0 {
                runtime.totalUsage.add(assistant.usage)
                runtime.lastTurnUsage = assistant.usage
            }
            // 正文已完整：气泡提前切完成态渲染（去 ✦ 光标），不等 agentEnd。
            if case let .assistant(assistant) = message {
                runtime.streamingBubbleComplete = true
                freezeStreamingThinking(on: runtime)
                // 状态栏提前翻 ready（BACKLOG-STATUS-READY-LAG）：仅当这是最终答复
                //（无工具调用 → 不会再来新一轮）；有工具调用则后面还有 turn，不翻。
                if assistant.toolCalls.isEmpty {
                    runtime.finalAnswerComplete = true
                    // 最终答复落定（BACKLOG-DETAIL-GROUP，决策 1+2）：
                    // a. 把该 streaming assistant 条目 detailTurnID 置 nil（移出组，DOM 不动只改标记，
                    //    原地留下，折叠后作为该 turn 组后第一条可见内容）；
                    // b. marker 更新为 collapsed=true（同 id 替换走 upsert）。
                    finalizeDetailGroup(on: runtime)
                }
            }
            // messageEnd 默认不触发镜像刷新；最终答复落定（状态栏翻 ready）时除外。
            hasVisibleStateChange = runtime.finalAnswerComplete
        case let .textDelta(delta):
            runtime.agentActivity = .writing
            // 新一轮正文开始（多轮 run 的后续 turn）：气泡切回流式渲染。
            runtime.streamingBubbleComplete = false
            runtime.finalAnswerComplete = false
            enqueueStreamingDelta(delta, on: runtime)
            if runtime === activeRuntime, agentActivity != .writing {
                agentActivity = .writing
            }
            hasVisibleStateChange = false
        case let .thinkingDelta(delta):
            // 思考过程入转录：缓冲后按与正文相同的节流节奏合并进 thinking 条目。
            enqueueThinkingDelta(delta, on: runtime)
            NewPiLogger.debug(
                category: "app",
                message: "UI: reasoning delta",
                details: "length=\(delta.count)"
            )
            hasVisibleStateChange = false
        case let .toolApprovalRequired(request):
            runtime.pendingToolApproval = request
            NewPiLogger.info(
                category: "app",
                message: "UI: showing tool approval sheet",
                details: """
                requestID=\(request.id)
                tool=\(request.toolName)
                summary=\(request.summary)
                """
            )
        case let .toolExecutionStart(id, name, arguments):
            runtime.agentActivity = .runningTool(name)
            runtime.finalAnswerComplete = false
            freezeStreamingThinking(on: runtime)
            let commandSummary = newPiToolCommandSummary(name: name, arguments: arguments)
            if let commandSummary {
                runtime.toolCommands[id] = commandSummary
            }
            // 工具卡入组（BACKLOG-DETAIL-GROUP）：首个组内条目触发 marker 懒创建，条目带当前 turn ID。
            ensureDetailGroupMarker(on: runtime)
            appendTranscript(kind: .tool(name: name, state: .running), body: "", toolCommand: commandSummary, detailTurnID: runtime.detailTurnID, on: runtime)
            NewPiLogger.info(
                category: "app",
                message: "UI: tool execution started",
                details: "\(name)\n\(NewPiLogFormat.describeJSONValue(arguments))"
            )
        case let .toolExecutionEnd(id, name, result):
            // isError 入 kind（结构化），body 只存原始输出，不再拼接 "Error: " 前缀。
            let command = runtime.toolCommands.removeValue(forKey: id)
            if let lastIndex = runtime.transcript.indices.last,
               case .tool(_, .running) = runtime.transcript[lastIndex].kind {
                let running = runtime.transcript[lastIndex]
                runtime.transcript[lastIndex] = NewPiTranscriptItem(
                    id: running.id,
                    kind: .tool(name: name, state: .completed(isError: result.isError)),
                    body: result.content,
                    toolCommand: command ?? running.toolCommand,
                    messageIndex: running.messageIndex,
                    sessionEntryID: running.sessionEntryID,
                    detailTurnID: running.detailTurnID
                )
            } else {
                ensureDetailGroupMarker(on: runtime)
                appendTranscript(
                    kind: .tool(name: name, state: .completed(isError: result.isError)),
                    body: result.content,
                    toolCommand: command,
                    detailTurnID: runtime.detailTurnID,
                    on: runtime
                )
            }
            NewPiLogger.info(
                category: "app",
                message: result.isError ? "UI: tool failed" : "UI: tool finished",
                details: "\(name): \(NewPiLogFormat.truncate(result.content, maxLength: 2000))"
            )
            runtime.agentActivity = .thinking
        case .agentEnd:
            runtime.isStreaming = false
            runtime.agentActivity = .idle
            runtime.pendingToolApproval = nil
            freezeStreamingThinking(on: runtime)
            NewPiLogger.info(category: "app", message: "UI: agent finished")
            Task {
                await appendTruncatedOutputNoticeIfNeeded(on: runtime)
                await syncTranscriptMessageIndices(on: runtime)
                await autoLabelCurrentSessionIfNeeded(on: runtime)
                await refreshSessionList()
            }
        case let .error(error):
            appendTranscript(kind: .error, body: error.localizedDescription, on: runtime)
            runtime.isStreaming = false
            runtime.agentActivity = .idle
            runtime.pendingToolApproval = nil
            freezeStreamingThinking(on: runtime)
            NewPiLogger.error(
                category: "app",
                message: "UI: agent error shown to user",
                details: error.localizedDescription
            )
        default:
            break
        }
        if hasVisibleStateChange, runtime === activeRuntime {
            reflectActive()
        }
    }

    func testProviderConnection(profile: ProviderProfile, apiKeyDraft: String) async -> ProviderConnectionTester.TestResult {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolver: ProviderCredentialResolver
        if !trimmedKey.isEmpty {
            resolver = ProviderCredentialResolver(store: InMemoryCredentialStore(secrets: [
                ProviderCredentialResolver.keychainAccount(for: profile.id): trimmedKey,
            ]))
        } else {
            resolver = providerCredentialResolver
        }
        return await ProviderConnectionTester.test(profile: profile, credentialResolver: resolver)
    }

    private func resolveProfile(for header: SessionHeader?) throws -> ProviderProfile {
        if let header,
           let profileID = header.providerProfileID,
           var profile = providerConfig.profiles.first(where: { $0.id == profileID }) {
            if let modelID = header.modelID, !modelID.isEmpty {
                profile.modelID = modelID
            }
            return profile
        }
        return try providerConfig.defaultProfile()
    }

    /// 全量重建 transcript（fork / 无 compaction 的 agentEnd 场景）。
    /// `preservedPrefixCount`：需保留在前的 transcript 条目数（方案 A —— compaction 后
    /// agentEnd 就地校准时，被压缩的完整历史要原样保留，只重建 summary 及其后的尾巴）。
    /// 为 0（默认）时等价旧行为：`removeAll()` 后全量重建。
    private func rebuildTranscript(
        from messages: [AgentMessage],
        entryIDs: [String] = [],
        on runtime: SessionRuntime,
        preservedPrefixCount: Int = 0
    ) {
        // 方案 A（compaction 后）保留前缀时，index 空间会重叠：被压缩旧历史的 messageIndex
        // 是压缩前原始 position（0..N-1），而重建的 summary+尾巴在 messages 里从 0 重新排。
        // 若用整个 transcript 构建 existingByMessageIndex，重建 summary（index=0）会误命中
        // 旧历史第一条（index=0）的 id。因此保留前缀场景下，index 保留表只基于被重建的
        // 后半段（transcript[preservedPrefixCount...]）构建，避免跨段误命中。
        // entryID 是全局唯一短 id（不复用），existingByEntryID 可安全基于整个 transcript。
        let idSourceRange = preservedPrefixCount > 0
            ? runtime.transcript[preservedPrefixCount...]
            : runtime.transcript[...]
        let existingByMessageIndex = Dictionary(
            uniqueKeysWithValues: idSourceRange.compactMap { item -> (Int, UUID)? in
                guard let messageIndex = item.messageIndex else { return nil }
                return (messageIndex, item.id)
            }
        )
        let existingByEntryID = Dictionary(
            uniqueKeysWithValues: runtime.transcript.compactMap { item -> (String, UUID)? in
                guard let sessionEntryID = item.sessionEntryID else { return nil }
                return (sessionEntryID, item.id)
            }
        )
        let streamingAssistantID = runtime.transcript.last(where: { $0.kind == .assistant && $0.messageIndex == nil })?.id
        let lastAssistantMessageIndex = messages.lastIndex(where: {
            if case .assistant = $0 { return true }
            return false
        })

        // 方案 A：保留前缀（被压缩的完整旧历史）时，撤掉 removeAll，改为截断到前缀末尾。
        if preservedPrefixCount > 0 {
            // Bug 2（FORK-STALE-INDEX）：被压缩旧历史的 messageIndex 是压缩前原始 position，
            // 而 session.fork(atMessageIndex:) 作用于压缩后的 context.messages（0 起重新排）。
            // 旧 index 要么越界抛错，要么静默 fork 到错误位置。压缩历史语义上不可回 fork，
            // 因此把保留前缀的 messageIndex 统一置 nil（canFork 即 false，按钮不显示）。
            for i in 0..<preservedPrefixCount {
                runtime.transcript[i] = NewPiTranscriptItem(
                    id: runtime.transcript[i].id,
                    kind: runtime.transcript[i].kind,
                    body: runtime.transcript[i].body,
                    toolCommand: runtime.transcript[i].toolCommand,
                    messageIndex: nil,
                    sessionEntryID: runtime.transcript[i].sessionEntryID,
                    detailTurnID: runtime.transcript[i].detailTurnID
                )
            }
            runtime.transcript.removeSubrange(preservedPrefixCount...)
        } else {
            runtime.transcript.removeAll()
        }
        // 同 makeTranscriptItems：toolResult 只有结果没有参数，用 toolCallID 回查上一条
        // assistant 消息的工具调用表，恢复命令摘要。
        var lastToolCalls: [String: ToolCallContent] = [:]
        // 处理详情分组（BACKLOG-DETAIL-GROUP）：当前 turn id；turn 内已产出过组内条目的标记。
        var currentTurnID: String? = nil
        var turnHasGroupItems = false

        // 预计算每个 user 消息之后的 turn 是否有组内条目（与 makeTranscriptItems 一致）。
        var turnHasGroupItemsByUserIndex: [Int: Bool] = [:]
        var lastUserIndex: Int? = nil
        for (index, message) in messages.enumerated() {
            if case .user = message {
                lastUserIndex = index
                turnHasGroupItemsByUserIndex[index] = false
            } else if let ui = lastUserIndex, makeTranscriptItems_isGroupMessage(message) {
                turnHasGroupItemsByUserIndex[ui] = true
            }
        }

        for (index, message) in messages.enumerated() {
            let entryID = index < entryIDs.count ? entryIDs[index] : nil
            let preservedID = preservedTranscriptID(
                for: index,
                entryID: entryID,
                message: message,
                existingByMessageIndex: existingByMessageIndex,
                existingByEntryID: existingByEntryID,
                streamingAssistantID: streamingAssistantID,
                lastAssistantMessageIndex: lastAssistantMessageIndex
            )
            switch message {
            case let .user(user):
                // review「🟡 turnID 稳定性」修复：按 preservedID 查映射表复用历史 live turnID，
                // 使每个 user 消息的 turnID 跨多轮 rebuild 稳定（不翻成 "turn-<entryID>"），
                // detailMarkerIDs 与 JS 端 groupState/manualOverride（以 turnID 为 key）始终命中，
                // 手动展开过的旧组不会被后续轮的 rebuild 重新收起。
                if let liveTurnID = runtime.detailLiveTurnIDByUser[preservedID] {
                    currentTurnID = liveTurnID
                } else {
                    currentTurnID = detailTurnID(userMessageIndex: index, entryID: entryID)
                }
                turnHasGroupItems = turnHasGroupItemsByUserIndex[index] ?? false
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    kind: .user,
                    body: user.content,
                    messageIndex: index,
                    sessionEntryID: entryID,
                    // 附件必须随 rebuild 保留（BACKLOG-IMAGE-INPUT）：agentEnd 后的
                    // rebuild 重建全部条目，漏传会使用户气泡缩略图在回复结束后消失
                    //（与加载路径 257 行保持一致）。
                    attachments: user.attachments
                ))
                // marker 在 user 之后、组内条目之前插入（恢复默认收起）；marker id 从缓存复用防闪烁。
                if turnHasGroupItems, let turnID = currentTurnID {
                    let markerID = runtime.detailMarkerIDs[turnID] ?? UUID()
                    runtime.detailMarkerIDs[turnID] = markerID
                    runtime.transcript.append(NewPiTranscriptItem(
                        id: markerID,
                        kind: .detailGroup(collapsed: true),
                        body: "",
                        detailTurnID: turnID
                    ))
                }
            case let .assistant(assistant):
                lastToolCalls = Dictionary(uniqueKeysWithValues: assistant.toolCalls.map { ($0.id, $0) })
                // 与 makeTranscriptItems 一致：reasoningContent 非空时在正文前补 thinking 条目
                //（fresh id，不占 messageIndex，避免与正文争抢 id 保留表）。
                if !assistant.reasoningContent.isEmpty {
                    runtime.transcript.append(NewPiTranscriptItem(
                        kind: .thinking(isStreaming: false),
                        body: assistant.reasoningContent,
                        detailTurnID: currentTurnID
                    ))
                }
                let assistantIsGroup = assistantBelongsToGroup(assistant)
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    kind: .assistant,
                    body: assistant.text,
                    messageIndex: index,
                    sessionEntryID: entryID,
                    detailTurnID: assistantIsGroup ? currentTurnID : nil
                ))
            case let .toolResult(result):
                let command = lastToolCalls[result.toolCallID]
                    .flatMap { newPiToolCommandSummary(name: $0.name, arguments: $0.arguments) }
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    kind: .tool(name: result.toolName, state: .completed(isError: result.isError)),
                    body: result.content,
                    toolCommand: command,
                    messageIndex: index,
                    sessionEntryID: entryID,
                    detailTurnID: currentTurnID
                ))
            case let .compactionSummary(summary):
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    kind: .summary,
                    body: summary,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            }
        }
        runtime.liveMessageCount = messages.count
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
    }

    private func preservedTranscriptID(
        for messageIndex: Int,
        entryID: String?,
        message: AgentMessage,
        existingByMessageIndex: [Int: UUID],
        existingByEntryID: [String: UUID],
        streamingAssistantID: UUID?,
        lastAssistantMessageIndex: Int?
    ) -> UUID {
        if let entryID, let id = existingByEntryID[entryID] {
            return id
        }
        if let id = existingByMessageIndex[messageIndex] {
            return id
        }
        if case .assistant = message,
           messageIndex == lastAssistantMessageIndex,
           let streamingAssistantID {
            return streamingAssistantID
        }
        return UUID()
    }

    private func cleanupEmptySessions() async {
        guard let projectURL else { return }
        let deleted = await Task.detached(priority: .utility) {
            (try? SessionManager.deleteEmptySessions(for: projectURL)) ?? 0
        }.value
        if deleted > 0 {
            NewPiLogger.info(
                category: "app",
                message: "Deleted empty sessions on startup",
                details: "count=\(deleted)"
            )
        }
    }

    private func autoLabelCurrentSessionIfNeeded(on runtime: SessionRuntime) async {
        guard let header = await runtime.session.attachedSessionHeader else { return }
        let existingLabel = header.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existingLabel.isEmpty else { return }

        let messages = await runtime.session.context.messages
        guard let exchange = SessionLabelService.firstExchange(from: messages) else { return }

        do {
            let profile = try resolveProfile(for: header)
            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            let label = try await SessionLabelService.generateLabel(
                userMessage: exchange.user,
                assistantMessage: exchange.assistant,
                model: profile.modelConfig,
                llm: llm
            )
            guard !label.isEmpty else { return }
            await runtime.session.updateSessionLabel(label)
            NewPiLogger.info(
                category: "app",
                message: "Session auto-labeled",
                details: label
            )
        } catch {
            NewPiLogger.error(
                category: "app",
                message: "Failed to auto-label session",
                details: error.localizedDescription
            )
        }
    }

    private func loadMCPTools() async -> [MCPAgentTool] {
        if let cachedMCPTools {
            return cachedMCPTools
        }
        if let mcpToolsLoadTask {
            return await mcpToolsLoadTask.value
        }

        let task = Task { await MCPToolLoader.loadAgentTools() }
        mcpToolsLoadTask = task
        let tools = await task.value
        cachedMCPTools = tools
        mcpToolsLoadTask = nil
        return tools
    }

    private func invalidateMCPToolsCache() {
        cachedMCPTools = nil
        mcpToolsLoadTask?.cancel()
        mcpToolsLoadTask = nil
    }

    private func appendTruncatedOutputNoticeIfNeeded(on runtime: SessionRuntime) async {
        let messages = await runtime.session.context.messages
        guard case let .assistant(assistant) = messages.last else { return }
        guard assistant.stopReason == .length,
              assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assistant.toolCalls.isEmpty else {
            return
        }

        let notice = assistant.reasoningContent.isEmpty
            ? "模型输出达到长度上限且未返回内容。请新开 session 或简化请求后重试。"
            : "模型推理达到长度上限，未完成最终回答或工具调用。请新开 session 或简化请求后重试。"
        appendTranscript(kind: .system, body: notice, on: runtime)
        NewPiLogger.info(
            category: "app",
            message: "UI: truncated empty assistant output notice shown",
            details: "reasoningLength=\(assistant.reasoningContent.count)"
        )
    }

    private func syncTranscriptMessageIndices(on runtime: SessionRuntime) async {
        let messages = await runtime.session.context.messages
        let entryIDs = await runtime.session.branchEntryIDs()
        // 方案 A：agentEnd 后不再全量 rebuild（那会 removeAll 后用截断的 context.messages
        // 覆盖完整 transcript，compaction 被压缩的历史就此丢失）。改为就地校准：保留
        // runtime.transcript 完整内容，只把刚结束的 streaming assistant 补上 messageIndex /
        // sessionEntryID（fork 锚点 + id 稳定所需），并校准 liveMessageCount。
        calibrateTranscriptAfterAgentEnd(from: messages, entryIDs: entryIDs, on: runtime)
        runtime.branchPointCount = await runtime.session.branchPointCount()
        runtime.isForkedBranch = runtime.branchPointCount > 0
        if runtime === activeRuntime {
            branchPointCount = runtime.branchPointCount
            isForkedBranch = runtime.isForkedBranch
        }
    }

    /// 方案 A（agentEnd 就地校准）：compaction 后保留被压缩的完整历史，只重建 summary 及其后的尾巴。
    ///
    /// 背景：live 期间所有内容已通过 appendTranscript / appendOrUpdateAssistant /
    /// appendOrUpdateThinking / tool 事件逐条累积进 transcript，被压缩前的完整历史天然保留在
    /// transcript 里。compaction 一旦触发，`context.messages` 和落盘 JSONL 不可逆地变成
    /// `[summary] + 最近8条`，旧历史只能从 UI 的 runtime.transcript 里找。因此 agentEnd 不能
    /// 再用截断后的 messages 全量 rebuild（否则被压缩历史被擦除）。
    ///
    /// 精确策略（区分有无 compaction）：
    ///   - 无 compaction（messages.first ≠ .compactionSummary）：走原 rebuildTranscript 全量重建
    ///     （安全，不会丢历史，且能正确重建带 toolCalls 的中间 assistant、补 messageIndex）。
    ///   - 有 compaction：保留 transcript 里 summary 之前的完整旧历史，只重建 summary 及之后的
    ///     尾巴（最近8条里的中间 assistant / toolResult / 最终答复能正确重建 + 补 index）。
    ///
    /// 为什么不能纯「就地校准只补 streaming assistant index」：带 toolCalls 的中间 assistant
    /// 在 live 期不产生 textDelta，因此不会进 transcript，只能靠重建 context.messages 补出。
    /// 所以必须重建尾部（含 compaction summary 之后的所有消息），而非只补 index。
    private func calibrateTranscriptAfterAgentEnd(
        from messages: [AgentMessage],
        entryIDs: [String],
        on runtime: SessionRuntime
    ) {
        // 判断是否发生了 compaction：messages 首条是 .compactionSummary。
        guard case .compactionSummary = messages.first else {
            // 无 compaction：保持原行为（全量重建，可正确补中间 assistant 与 index）。
            rebuildTranscript(from: messages, entryIDs: entryIDs, on: runtime)
            return
        }

        // 有 compaction：找到 transcript 里最后一个 .summary 条目（live 期 messageStart
        // (.compactionSummary) append 的那个，它是「被压缩历史」与「压缩后新内容」的分界）。
        // 保留它之前的完整旧历史，删除它及其后，再用 messages 重建尾巴。
        guard let summaryTranscriptIndex = runtime.transcript.lastIndex(where: { $0.kind == .summary }) else {
            // 理论上不应发生（compaction summary 必已 append），防御性回退全量重建。
            rebuildTranscript(from: messages, entryIDs: entryIDs, on: runtime)
            return
        }

        // 保留 summary 之前的完整旧历史（preservedPrefixCount = summary 下标），
        // rebuild 会撤掉 removeAll、截断到该前缀末尾，再 append 重建的 summary+尾巴。
        rebuildTranscript(
            from: messages,
            entryIDs: entryIDs,
            on: runtime,
            preservedPrefixCount: summaryTranscriptIndex
        )
    }

    private func appendTranscript(kind: NewPiTranscriptItemKind, body: String, toolCommand: String? = nil, messageIndex: Int? = nil, sessionEntryID: String? = nil) {
        let item = NewPiTranscriptItem(kind: kind, body: body, toolCommand: toolCommand, messageIndex: messageIndex, sessionEntryID: sessionEntryID)
        if let r = activeRuntime {
            r.transcript.append(item)
            transcript = r.transcript
        } else {
            transcript.append(item)
        }
    }

    /// 追加到指定 runtime（一般是后台 session 的事件循环），只在它是当前显示时同步到 published。
    @discardableResult
    private func appendTranscript(kind: NewPiTranscriptItemKind, body: String, toolCommand: String? = nil, messageIndex: Int? = nil, sessionEntryID: String? = nil, detailTurnID: String? = nil, attachments: [MessageAttachment] = [], on runtime: SessionRuntime) -> UUID {
        let item = NewPiTranscriptItem(kind: kind, body: body, toolCommand: toolCommand, messageIndex: messageIndex, sessionEntryID: sessionEntryID, detailTurnID: detailTurnID, attachments: attachments)
        runtime.transcript.append(item)
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
        return item.id
    }

    /// 流式增量合并的节流间隔（毫秒）：间隔内到达的 textDelta 会合并成一次 transcript 刷新。
    /// 自适应：主线程渲染跟不上时 delta 会积压，积压越深刷新间隔越长——
    /// 用更少的渲染提交换主线程喘息，避免 backlog 雪崩（实测：40ms 固定节流时
    /// LLM 流完后 UI 还要 4 分钟排空积压，run wall time 272s）。
    private func streamingFlushIntervalMS(for runtime: SessionRuntime) -> UInt64 {
        // 平滑斜坡：随积压线性增加（40ms 起、每 150 字符 +1ms、600ms 封顶），
        // 避免硬档位切换造成的「顺畅→突然卡一下→涌一大段」观感。
        // 实测（sample）：主线程 ~44% 时间阻塞在每次渲染提交的 CA 表面分配同步上，
        // 单次提交成本 0.5~1s；积压越深就要把提交降得越稀，否则 backlog 雪崩。
        let backlog = runtime.pendingStreamingDelta.count
        return UInt64(min(40 + backlog / 150, 600))
    }

    /// 缓冲一个流式文本增量，并按节流间隔调度一次合并刷新；若已有刷新任务在排队则只追加。
    private func enqueueStreamingDelta(_ delta: String, on runtime: SessionRuntime) {
        runtime.pendingStreamingDelta += delta
        scheduleStreamingFlush(on: runtime)
    }

    /// 缓冲一个流式思考增量（与正文共用同一刷新任务与节流节奏）。
    private func enqueueThinkingDelta(_ delta: String, on runtime: SessionRuntime) {
        runtime.pendingThinkingDelta += delta
        scheduleStreamingFlush(on: runtime)
    }

    private func scheduleStreamingFlush(on runtime: SessionRuntime) {
        guard runtime.streamingFlushTask == nil else { return }
        let intervalMS = streamingFlushIntervalMS(for: runtime)
        runtime.streamingFlushTask = Task { @MainActor [weak runtime] in
            do {
                try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
            } catch {
                return
            }
            guard let runtime else { return }
            runtime.streamingFlushTask = nil
            flushStreamingDelta(on: runtime)
        }
    }

    /// 立即把未合并的流式增量写入 transcript（在状态边界 / abort 前调用，防止文本丢失与乱序）。
    private func flushStreamingDelta(on runtime: SessionRuntime) {
        runtime.streamingFlushTask?.cancel()
        runtime.streamingFlushTask = nil
        // 思考增量先于正文 flush：时序上 thinkingDelta 总是先于同轮 textDelta 到达。
        if !runtime.pendingThinkingDelta.isEmpty {
            let delta = runtime.pendingThinkingDelta
            runtime.pendingThinkingDelta = ""
            appendOrUpdateThinking(delta, on: runtime)
        }
        guard !runtime.pendingStreamingDelta.isEmpty else { return }
        let delta = runtime.pendingStreamingDelta
        runtime.pendingStreamingDelta = ""
        // 诊断：flush 本身（字符串拼接 + transcript 更新 + SwiftUI 提交）若过慢会卡事件循环。
        let start = Date()
        appendOrUpdateAssistant(delta, on: runtime)
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 0.1 {
            NewPiLogger.info(category: "app", message: "Slow streaming flush", details: "elapsed=\(String(format: "%.2f", elapsed))s deltaLen=\(delta.count)")
        }
    }

    private func appendOrUpdateThinking(_ delta: String, on runtime: SessionRuntime) {
        if let last = runtime.transcript.last, case .thinking(true) = last.kind {
            let index = runtime.transcript.count - 1
            runtime.transcript[index] = NewPiTranscriptItem(
                id: last.id,
                kind: .thinking(isStreaming: true),
                body: last.body + delta,
                messageIndex: last.messageIndex,
                sessionEntryID: last.sessionEntryID,
                detailTurnID: last.detailTurnID ?? runtime.detailTurnID
            )
        } else {
            ensureDetailGroupMarker(on: runtime)
            runtime.transcript.append(NewPiTranscriptItem(
                kind: .thinking(isStreaming: true),
                body: delta,
                detailTurnID: runtime.detailTurnID
            ))
        }
    }

    /// 思考阶段结束（正文开始 / 工具开始 / 消息或 run 结束）：把尾部流式 thinking 条目冻结为完成态。
    private func freezeStreamingThinking(on runtime: SessionRuntime) {
        guard let last = runtime.transcript.last, case .thinking(true) = last.kind else { return }
        let index = runtime.transcript.count - 1
        runtime.transcript[index] = NewPiTranscriptItem(
            id: last.id,
            kind: .thinking(isStreaming: false),
            body: last.body,
            messageIndex: last.messageIndex,
            sessionEntryID: last.sessionEntryID,
            detailTurnID: last.detailTurnID
        )
    }

    /// marker 懒创建（BACKLOG-DETAIL-GROUP）：当前 turn 尚未创建 disclosure 行时，
    /// 在组内第一条条目之前插入 marker 条目（collapsed=false，流式期间展开），
    /// 并缓存其 id 到 detailMarkerIDs 跨 rebuild 复用。
    private func ensureDetailGroupMarker(on runtime: SessionRuntime) {
        guard let turnID = runtime.detailTurnID, runtime.detailGroupMarkerID == nil else { return }
        let markerID = runtime.detailMarkerIDs[turnID] ?? UUID()
        runtime.detailMarkerIDs[turnID] = markerID
        runtime.detailGroupMarkerID = markerID
        runtime.transcript.append(NewPiTranscriptItem(
            id: markerID,
            kind: .detailGroup(collapsed: false),
            body: "",
            detailTurnID: turnID
        ))
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
    }

    /// 最终答复落定（BACKLOG-DETAIL-GROUP，决策 1+2）：把 turn 内最后一个 assistant 条目
    /// detailTurnID 置 nil（移出组，原地保留），并把 marker 置为 collapsed=true。
    /// 仅在存在当前 turn 且有 marker 时执行；无中间过程（无 marker）的 turn 是纯最终答复，无需处理。
    private func finalizeDetailGroup(on runtime: SessionRuntime) {
        guard let turnID = runtime.detailTurnID else { return }
        // a. 找到最后一个 detailTurnID == 当前 turn 的 assistant 条目，置 nil 移出组。
        if let lastIndex = runtime.transcript.lastIndex(where: { $0.kind == .assistant && $0.detailTurnID == turnID }) {
            let item = runtime.transcript[lastIndex]
            runtime.transcript[lastIndex] = NewPiTranscriptItem(
                id: item.id,
                kind: item.kind,
                body: item.body,
                toolCommand: item.toolCommand,
                messageIndex: item.messageIndex,
                sessionEntryID: item.sessionEntryID,
                detailTurnID: nil
            )
        }
        // b. marker：最终答复已移出组后，若组内已无剩余条目，说明这是无中间过程的
        //    纯最终答复 turn——移除 marker（否则留下一个点开后空无一物的「处理详情」行，
        //    review 意见4，方案 B.2「无中间过程直接出答复的 turn 没有 marker」）。
        //    若组内仍有条目（thinking / tool / 中间 assistant），则把 marker 收起（同 id 替换，走 upsert）。
        if let markerID = runtime.detailGroupMarkerID,
           let markerIndex = runtime.transcript.firstIndex(where: { $0.id == markerID }) {
            let marker = runtime.transcript[markerIndex]
            let turnHasRemainingGroupItems = runtime.transcript.contains {
                $0.id != markerID && $0.detailTurnID == turnID
            }
            if turnHasRemainingGroupItems {
                runtime.transcript[markerIndex] = NewPiTranscriptItem(
                    id: marker.id,
                    kind: .detailGroup(collapsed: true),
                    body: marker.body,
                    detailTurnID: marker.detailTurnID
                )
            } else {
                runtime.transcript.remove(at: markerIndex)
            }
        }
        // 本轮收尾完成，关闭 turn 状态（abort 不走到这里，组保持展开）。
        runtime.detailTurnID = nil
        runtime.detailGroupMarkerID = nil
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
    }

    private func appendOrUpdateAssistant(_ delta: String, on runtime: SessionRuntime) {
        // 正文开始 = 思考阶段结束。
        freezeStreamingThinking(on: runtime)
        if let last = runtime.transcript.last, last.kind == .assistant {
            let index = runtime.transcript.count - 1
            runtime.transcript[index] = NewPiTranscriptItem(
                id: last.id,
                kind: .assistant,
                body: last.body + delta,
                messageIndex: last.messageIndex,
                sessionEntryID: last.sessionEntryID,
                detailTurnID: last.detailTurnID ?? runtime.detailTurnID
            )
        } else {
            ensureDetailGroupMarker(on: runtime)
            runtime.transcript.append(NewPiTranscriptItem(
                kind: .assistant,
                body: delta,
                detailTurnID: runtime.detailTurnID
            ))
        }
        // 流式 flush 不再镜像到 viewModel.transcript：面板观察的是 runtime.transcript，
        // 镜像只会让 NewPiRootView（NavigationSplitView + 侧边栏 List）每次 flush 都跟着
        // 重评估。viewModel.transcript 在 agentEnd 的 rebuildTranscript 时统一同步。
    }
}
