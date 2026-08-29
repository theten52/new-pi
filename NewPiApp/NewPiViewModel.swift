import AppKit
import Foundation
import NewPiCore
import SwiftUI
import UniformTypeIdentifiers

struct NewPiTranscriptItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let messageIndex: Int?
    let sessionEntryID: String?

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        messageIndex: Int? = nil,
        sessionEntryID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.messageIndex = messageIndex
        self.sessionEntryID = sessionEntryID
    }

    var canFork: Bool {
        messageIndex != nil && (title == "You" || title == "NewPi" || title == "Summary")
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
    var liveMessageCount = 0
    var eventTask: Task<Void, Never>?
    /// 最近一次成为活跃会话的时间，用于缓存淘汰（LRU）。
    var lastUsedAt = Date()
    /// 流式文本增量合并缓冲：textDelta 先累积到这里，按节流间隔一次性合并进 transcript，
    /// 避免每个 delta 都触发 O(n) 字符串拼接与全量 UI 重渲染（见流式渲染优化）。
    var pendingStreamingDelta = ""
    var streamingFlushTask: Task<Void, Never>?
    /// 冷加载就绪门控：false 时面板隐藏内容、显示 Loading，等尾部 markdown 行上报首次高度
    /// （或超时）后才揭示。默认 true（新会话/保活命中零开销）。
    @Published var initialRenderReady = true
    /// 待就绪的 markdown 行 id（冷恢复时只纳入「高度缓存 miss」的行，GLM review 意见3）。
    private var pendingInitialRenderIDs: Set<UUID> = []
    private var initialRenderGateTask: Task<Void, Never>?

    init(session: AgentSession, fileURL: URL, sessionID: UUID) {
        self.session = session
        self.fileURL = fileURL
        self.sessionID = sessionID
    }

    /// 开启就绪门：rowIDs 为待就绪的 markdown 行。rowIDs 空则保持就绪并当作已完成。
    /// 超时强制就绪，防止 LazyVStack 惰性只实例化视口行、其余 pending 行永不发信号导致超时常态化。
    @MainActor
    func beginInitialRenderGate(rowIDs: Set<UUID>) {
        cancelInitialRenderGate()
        guard !rowIDs.isEmpty else { return }
        pendingInitialRenderIDs = rowIDs
        initialRenderReady = false
        initialRenderGateTask = Task { [weak self] in
            do {
                // 窗口化 + 产物重放后，占位高度已精确、揭示不再伴随布局跳动；
                // 超时压到 0.6s：超时即揭示，结构先行、内容陆续填入（浏览器式渐进呈现）。
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return // 取消：不再强制揭示，避免旧 task 提前揭示新 gate（K3 review minor）
            }
            self?.forceInitialRenderReady()
        }
    }

    /// 某 markdown 行首次高度已上报（= 初始渲染完成）。pending 清空即揭示。
    @MainActor
    func markInitialRowRendered(_ id: UUID) {
        guard pendingInitialRenderIDs.remove(id) != nil else { return }
        if pendingInitialRenderIDs.isEmpty {
            forceInitialRenderReady()
        }
    }

    @MainActor
    private func forceInitialRenderReady() {
        initialRenderGateTask?.cancel()
        initialRenderGateTask = nil
        pendingInitialRenderIDs.removeAll()
        initialRenderReady = true
    }

    @MainActor
    private func cancelInitialRenderGate() {
        initialRenderGateTask?.cancel()
        initialRenderGateTask = nil
        pendingInitialRenderIDs.removeAll()
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

/// 由消息列表构建转录条目（纯函数，供后台线程调用；新建 session 的转录为空，
/// 无需保留既有条目的 id）。
private func makeTranscriptItems(
    from messages: [AgentMessage],
    entryIDs: [String]
) -> [NewPiTranscriptItem] {
    var items: [NewPiTranscriptItem] = []
    items.reserveCapacity(messages.count)
    for (index, message) in messages.enumerated() {
        let entryID = index < entryIDs.count ? entryIDs[index] : nil
        switch message {
        case let .user(user):
            items.append(NewPiTranscriptItem(title: "You", body: user.content, messageIndex: index, sessionEntryID: entryID))
        case let .assistant(assistant):
            items.append(NewPiTranscriptItem(title: "NewPi", body: assistant.text, messageIndex: index, sessionEntryID: entryID))
        case let .toolResult(result):
            items.append(NewPiTranscriptItem(
                title: "Tool \(result.toolName)",
                body: result.isError ? "Error: \(result.content)" : result.content,
                messageIndex: index,
                sessionEntryID: entryID
            ))
        case let .compactionSummary(summary):
            items.append(NewPiTranscriptItem(title: "Summary", body: summary, messageIndex: index, sessionEntryID: entryID))
        }
    }
    return items
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
        if isStreaming {
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
            // 跨项目时高度缓存里的内容不再适用，清空避免残留。
            MarkdownRenderingCache.shared.clear()
            // 换项目时取消在飞的离屏预测高，避免向已清空的缓存写跨项目高度（GLM #1）。
            MarkdownHeightPreheater.shared.cancel()
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
            appendTranscript(title: "Error", body: error.localizedDescription)
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
        guard !isStreaming else { return }
        guard let projectURL else { return }
        guard let profile = providerConfig.profiles.first(where: { $0.id == profileID }) else { return }

        do {
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
                message: "Provider switched",
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
                // 立即落盘：切换后未发消息就退出 App，也要记住该会话的 provider 选择。
                await session.updateSessionHeader(header)
            }

            activeProviderID = profile.id
            activeProviderName = profile.name
            activeProviderModel = profile.modelID
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
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
            appendTranscript(title: "Error", body: error.localizedDescription)
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
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func deleteProfile(id: String) async {
        do {
            try providerConfigStore.deleteProfile(id: id, from: &providerConfig)
            await refreshProviderList()
            // 不自动新建会话、不改已有会话的 provider：新默认只作用于新建会话。
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
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
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func archiveSession(_ summary: SessionSummary) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try SessionManager.setArchived(true, for: summary.fileURL)
            }.value
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
                await closeActiveSession()
            }
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
            appendTranscript(title: "Error", body: error.localizedDescription)
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
                title: "System",
                body: "Forked conversation from message \(index + 1). New replies continue on this branch.",
                on: runtime
            )
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription, on: runtime)
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
            appendTranscript(title: "Error", body: error.localizedDescription)
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

            // 冷恢复：开启就绪门控——只纳入「高度缓存 miss」的 markdown 行，避免 LazyVStack 惰性
            // 只实例化视口行、其余 pending 行永不发信号导致超时常态化（GLM review 意见3）。
            if restoredContext != nil {
                // 变体 B（K3 方案，review 建议先做）：门控放面板内——activeRuntime 立即切换，
                // 面板挂载即 active，内容 opacity(0) + Loading 遮罩，等尾部 markdown 行首次高度
                //（或 1.2s 超时）后一次揭示。不依赖 opacity-0 面板预渲染（较稳妥，GLM review 意见8 风险点）。
                // 两段式（保留旧会话 + opacity-0 预渲染再激活）留待实测确认隐面板渲染后再上。
                runtime.beginInitialRenderGate(rowIDs: Self.initialRenderGateRowIDs(from: payload.transcriptItems))
            }

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

            // 冷恢复：启动离屏预测高（GLM #5：仅在真正激活的会话上启动，避免为被放弃的会话白跑）。
            // 只对 cache-miss 行串行测高填缓存；用户滚动到某行时"实例化即命中真实高度"→ 滚动条稳定。
            if restoredContext != nil {
                MarkdownHeightPreheater.shared.preheat(items: payload.transcriptItems)
            }

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
            appendTranscript(title: "Error", body: error.localizedDescription)
            activeProviderReady = false
        }
    }

    /// 冷恢复就绪门控的目标行：transcript 尾部（钉底后视口 ≈ 尾屏）最多 maxCount 条
    /// 「高度缓存 miss」的 markdown 行 id。缓存命中行首帧已是真实高度、无需门控；
    /// 只纳入 miss 行可大幅缩小 pending 集合，避免末条超高（长代码块）时 LazyVStack
    /// 只实例化 1-2 行、其余 pending 行永不发信号 → 超时常态化（GLM review 意见3）。
    /// 只扫尾部 scanLimit 条：miss 凑不满 maxCount 时不会一路扫到 transcript 头，
    /// 避免长会话全命中场景在主线程对每行做 SHA256（K3 review minor）。
    private static func initialRenderGateRowIDs(
        from items: [NewPiTranscriptItem],
        maxCount: Int = 8,
        scanLimit: Int = 40
    ) -> Set<UUID> {
        guard !items.isEmpty else { return [] }
        var ids: Set<UUID> = []
        for item in items.suffix(scanLimit).reversed() {
            guard item.title == "NewPi" || item.title == "Summary" else { continue }
            guard MarkdownRenderingCache.shared.height(for: item.body) == nil else { continue }
            ids.insert(item.id)
            if ids.count >= maxCount { break }
        }
        return ids
    }

    /// 把当前 provider 状态同步到 @Published（供两个分支复用）。
    private func setActiveProviderState(_ profile: ProviderProfile) async {
        activeProviderID = profile.id
        activeProviderName = profile.name
        activeProviderModel = profile.modelID
        activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)
    }

    func send(_ text: String) {
        guard let runtime = activeRuntime else {
            appendTranscript(
                title: "System",
                body: projectURL == nil
                    ? "Open a project first."
                    : "Start a new session first (⇧⌘N)."
            )
            return
        }

        appendTranscript(title: "You", body: text, on: runtime)
        runtime.isStreaming = true
        runtime.agentActivity = .thinking
        reflectActive()
        NewPiLogger.info(category: "app", message: "User message sent", details: NewPiLogFormat.truncate(text, maxLength: 1000))
        Task {
            await runtime.session.prompt(text)
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
            NewPiLogger.info(category: "app", message: "UI: agent started")
        case let .messageStart(message):
            NewPiLogger.debug(category: "app", message: "UI: message started", details: message.roleLabel)
            if case let .compactionSummary(summary) = message {
                appendTranscript(title: "Summary", body: summary, on: runtime)
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
            if case .assistant = message {
                runtime.streamingBubbleComplete = true
            }
            hasVisibleStateChange = false
        case let .textDelta(delta):
            runtime.agentActivity = .writing
            // 新一轮正文开始（多轮 run 的后续 turn）：气泡切回流式渲染。
            runtime.streamingBubbleComplete = false
            enqueueStreamingDelta(delta, on: runtime)
            if runtime === activeRuntime, agentActivity != .writing {
                agentActivity = .writing
            }
            hasVisibleStateChange = false
        case let .thinkingDelta(delta):
            NewPiLogger.debug(
                category: "app",
                message: "UI: reasoning delta",
                details: "length=\(delta.count)"
            )
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
        case let .toolExecutionStart(_, name, arguments):
            runtime.agentActivity = .runningTool(name)
            appendTranscript(title: "Tool", body: "Running \(name)…", on: runtime)
            NewPiLogger.info(
                category: "app",
                message: "UI: tool execution started",
                details: "\(name)\n\(NewPiLogFormat.describeJSONValue(arguments))"
            )
        case let .toolExecutionEnd(_, name, result):
            let body = result.isError ? "Error: \(result.content)" : result.content
            if let lastIndex = runtime.transcript.indices.last,
               runtime.transcript[lastIndex].title == "Tool",
               runtime.transcript[lastIndex].body.hasPrefix("Running ") {
                let running = runtime.transcript[lastIndex]
                runtime.transcript[lastIndex] = NewPiTranscriptItem(
                    id: running.id,
                    title: "Tool \(name)",
                    body: body,
                    messageIndex: running.messageIndex,
                    sessionEntryID: running.sessionEntryID
                )
            } else {
                appendTranscript(title: "Tool \(name)", body: body, on: runtime)
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
            NewPiLogger.info(category: "app", message: "UI: agent finished")
            Task {
                await appendTruncatedOutputNoticeIfNeeded(on: runtime)
                await syncTranscriptMessageIndices(on: runtime)
                await autoLabelCurrentSessionIfNeeded(on: runtime)
                await refreshSessionList()
            }
        case let .error(error):
            appendTranscript(title: "Error", body: error.localizedDescription, on: runtime)
            runtime.isStreaming = false
            runtime.agentActivity = .idle
            runtime.pendingToolApproval = nil
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

    private func rebuildTranscript(from messages: [AgentMessage], entryIDs: [String] = [], on runtime: SessionRuntime) {
        let existingByMessageIndex = Dictionary(
            uniqueKeysWithValues: runtime.transcript.compactMap { item -> (Int, UUID)? in
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
        let streamingAssistantID = runtime.transcript.last(where: { $0.title == "NewPi" && $0.messageIndex == nil })?.id
        let lastAssistantMessageIndex = messages.lastIndex(where: {
            if case .assistant = $0 { return true }
            return false
        })

        runtime.transcript.removeAll()
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
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "You",
                    body: user.content,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .assistant(assistant):
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "NewPi",
                    body: assistant.text,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .toolResult(result):
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "Tool \(result.toolName)",
                    body: result.isError ? "Error: \(result.content)" : result.content,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .compactionSummary(summary):
                runtime.transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "Summary",
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
        appendTranscript(title: "System", body: notice, on: runtime)
        NewPiLogger.info(
            category: "app",
            message: "UI: truncated empty assistant output notice shown",
            details: "reasoningLength=\(assistant.reasoningContent.count)"
        )
    }

    private func syncTranscriptMessageIndices(on runtime: SessionRuntime) async {
        let messages = await runtime.session.context.messages
        let entryIDs = await runtime.session.branchEntryIDs()
        rebuildTranscript(from: messages, entryIDs: entryIDs, on: runtime)
        runtime.branchPointCount = await runtime.session.branchPointCount()
        runtime.isForkedBranch = runtime.branchPointCount > 0
        if runtime === activeRuntime {
            branchPointCount = runtime.branchPointCount
            isForkedBranch = runtime.isForkedBranch
        }
    }

    private func appendTranscript(title: String, body: String, messageIndex: Int? = nil, sessionEntryID: String? = nil) {
        let item = NewPiTranscriptItem(title: title, body: body, messageIndex: messageIndex, sessionEntryID: sessionEntryID)
        if let r = activeRuntime {
            r.transcript.append(item)
            transcript = r.transcript
        } else {
            transcript.append(item)
        }
    }

    /// 追加到指定 runtime（一般是后台 session 的事件循环），只在它是当前显示时同步到 published。
    private func appendTranscript(title: String, body: String, messageIndex: Int? = nil, sessionEntryID: String? = nil, on runtime: SessionRuntime) {
        runtime.transcript.append(NewPiTranscriptItem(title: title, body: body, messageIndex: messageIndex, sessionEntryID: sessionEntryID))
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
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

    private func appendOrUpdateAssistant(_ delta: String, on runtime: SessionRuntime) {
        if let last = runtime.transcript.last, last.title == "NewPi" {
            let index = runtime.transcript.count - 1
            runtime.transcript[index] = NewPiTranscriptItem(
                id: last.id,
                title: "NewPi",
                body: last.body + delta,
                messageIndex: last.messageIndex,
                sessionEntryID: last.sessionEntryID
            )
        } else {
            runtime.transcript.append(NewPiTranscriptItem(title: "NewPi", body: delta))
        }
        // 流式 flush 不再镜像到 viewModel.transcript：面板观察的是 runtime.transcript，
        // 镜像只会让 NewPiRootView（NavigationSplitView + 侧边栏 List）每次 flush 都跟着
        // 重评估。viewModel.transcript 在 agentEnd 的 rebuildTranscript 时统一同步。
    }
}
