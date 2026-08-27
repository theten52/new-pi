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
    var liveMessageCount = 0
    var eventTask: Task<Void, Never>?
    /// 最近一次成为活跃会话的时间，用于缓存淘汰（LRU）。
    var lastUsedAt = Date()
    /// 流式文本增量合并缓冲：textDelta 先累积到这里，按节流间隔一次性合并进 transcript，
    /// 避免每个 delta 都触发 O(n) 字符串拼接与全量 UI 重渲染（见流式渲染优化）。
    var pendingStreamingDelta = ""
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
        if newURL != projectURL {
            await stopAllLiveSessions()
            // 跨项目时高度缓存里的内容不再适用，清空避免残留。
            MarkdownRenderingCache.shared.clear()
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
        await startNewSession()
        // 预热 MCP 工具（后台，不阻塞打开流程），让用户首次切换 session 时无需当场等待。
        Task { await self.loadMCPTools() }
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
                await startNewSession()
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

        if let defaultProfile = try? providerConfig.defaultProfile() {
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
               let fileURL = currentSessionFileURL,
               var header = await session.attachedSessionHeader {
                header.providerProfileID = profile.id
                header.modelID = profile.modelID
                await session.attachPersistence(fileURL: fileURL, header: header)
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
            await startNewSession()
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
            await startNewSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func deleteProfile(id: String) async {
        do {
            try providerConfigStore.deleteProfile(id: id, from: &providerConfig)
            await refreshProviderList()
            await startNewSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func resetSession() async {
        await startNewSession()
    }

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
            if summary.fileURL == currentSessionFileURL {
                await startNewSession()
            }
            await refreshSessionList()
            NewPiLogger.info(
                category: "app",
                message: "Session archived",
                details: summary.fileURL.lastPathComponent
            )
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
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
            }
            existing.lastUsedAt = Date()
            activeRuntime = existing
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
                return BuiltSessionPayload(
                    session: session,
                    header: header,
                    fileURL: sessionFileURL,
                    transcriptItems: makeTranscriptItems(from: messages, entryIDs: entryIDs),
                    branchPointCount: branchPointCount,
                    isForkedBranch: branchPointCount > 0,
                    liveMessageCount: messages.count
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
            runtime.lastUsedAt = Date()
            activeRuntime = runtime
            activeSessionID = payload.header.id

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

    /// 把当前 provider 状态同步到 @Published（供两个分支复用）。
    private func setActiveProviderState(_ profile: ProviderProfile) async {
        activeProviderID = profile.id
        activeProviderName = profile.name
        activeProviderModel = profile.modelID
        activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)
    }

    func send(_ text: String) {
        guard let runtime = activeRuntime else {
            appendTranscript(title: "System", body: "Open a project first.")
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
            for await event in stream {
                handle(event, on: runtime)
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
        case .messageStart, .toolExecutionStart, .toolExecutionEnd, .agentEnd, .error:
            flushStreamingDelta(on: runtime)
        default:
            break
        }

        var hasVisibleStateChange = true
        switch event {
        case .agentStart:
            runtime.isStreaming = true
            runtime.agentActivity = .thinking
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
        case let .textDelta(delta):
            runtime.agentActivity = .writing
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

    /// 流式增量合并的节流间隔（毫秒）：间隔内到达的 textDelta 会合并成一次 transcript 刷新，
    /// 避免逐字符触发 O(n) 拼接、全量 markdown 重解析与 UI 重渲染。
    private let streamingFlushIntervalMS: UInt64 = 40

    /// 缓冲一个流式文本增量，并按节流间隔调度一次合并刷新；若已有刷新任务在排队则只追加。
    private func enqueueStreamingDelta(_ delta: String, on runtime: SessionRuntime) {
        runtime.pendingStreamingDelta += delta
        guard runtime.streamingFlushTask == nil else { return }
        runtime.streamingFlushTask = Task { @MainActor [weak runtime] in
            do {
                try await Task.sleep(nanoseconds: streamingFlushIntervalMS * 1_000_000)
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
        appendOrUpdateAssistant(delta, on: runtime)
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
        if runtime === activeRuntime {
            transcript = runtime.transcript
        }
    }
}
