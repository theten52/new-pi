import AppKit
import Foundation
import NewPiCore
import SwiftUI
import UniformTypeIdentifiers

struct NewPiTranscriptItem: Identifiable {
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

    private var session: AgentSession?
    private var eventTask: Task<Void, Never>?
    private var currentSessionFileURL: URL?
    private let providerConfigStore = ProviderConfigStore()
    private let providerCredentialResolver = ProviderCredentialResolver.makeDefault()
    @Published var useKeychainForCredentials = ProviderCredentialPreferences.load().useKeychain
    private let jsonlStore = JSONLSessionStore()
    private let sessionExporter = SessionExporter()
    private var liveMessageCount = 0

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
        projectURL = url.standardizedFileURL
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
        await refreshSessionList()
        await startNewSession()
    }

    func reloadProviders() async {
        do {
            useKeychainForCredentials = ProviderCredentialPreferences.load().useKeychain
            providerConfig = try providerConfigStore.load()
            await refreshProviderList()
            if projectURL != nil {
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
        savedSessions = (try? SessionManager.listSessions(for: projectURL)) ?? []
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
            let mcpTools = await MCPToolLoader.loadAgentTools()
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
            try await providerCredentialResolver.saveAPIKey(apiKeyDraft, for: profile)

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
        do {
            let context = try jsonlStore.load(from: summary.fileURL)
            await beginSession(restoredContext: context, fileURL: summary.fileURL)
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func forkFromMessage(index: Int) async {
        guard !isStreaming, let session else { return }
        do {
            try await session.fork(atMessageIndex: index)
            let messages = await session.context.messages
            rebuildTranscript(from: messages, entryIDs: await session.branchEntryIDs())
            branchPointCount = await session.branchPointCount()
            isForkedBranch = branchPointCount > 0
            appendTranscript(title: "System", body: "Forked conversation from message \(index + 1). New replies continue on this branch.")
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
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
        eventTask?.cancel()
        transcript.removeAll()
        pendingToolApproval = nil
        isStreaming = false
        agentActivity = .idle

        guard let projectURL else { return }

        NewPiLogger.info(
            category: "app",
            message: "Beginning agent session",
            details: """
            project=\(projectURL.path)
            restored=\(restoredContext != nil)
            sessionFile=\(fileURL?.path ?? "new")
            """
        )

        do {
            let profile = try resolveProfile(for: restoredContext?.header)
            let messages = restoredContext.map { SessionManager.messages(from: $0) } ?? []

            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            let mcpTools = await MCPToolLoader.loadAgentTools()
            let agentSession = AgentSessionFactory.codingSession(
                workingDirectory: projectURL,
                llm: llm,
                model: profile.modelConfig,
                restoredMessages: messages,
                additionalTools: mcpTools
            )

            let sessionFileURL: URL
            let header: SessionHeader
            if let restoredContext, let fileURL {
                sessionFileURL = fileURL
                header = restoredContext.header
            } else {
                let created = try SessionManager.createSession(
                    workingDirectory: projectURL,
                    providerProfileID: profile.id,
                    modelID: profile.modelID
                )
                sessionFileURL = created.fileURL
                header = created.context.header
            }

            await agentSession.attachPersistence(fileURL: sessionFileURL, header: header)
            session = agentSession
            currentSessionFileURL = sessionFileURL
            activeSessionID = header.id

            let entryIDs = await agentSession.branchEntryIDs()
            rebuildTranscript(from: messages, entryIDs: entryIDs)
            branchPointCount = await agentSession.branchPointCount()
            isForkedBranch = branchPointCount > 0
            liveMessageCount = messages.count

            activeProviderID = profile.id
            activeProviderName = profile.name
            activeProviderModel = profile.modelID
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)

            subscribe(to: agentSession)
            await refreshSessionList()
            NewPiLogger.info(
                category: "app",
                message: "Agent session ready",
                details: """
                provider=\(profile.name) model=\(profile.modelID)
                mcpTools=\(mcpTools.count)
                restoredMessages=\(messages.count)
                sessionFile=\(sessionFileURL.path)
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

    func send(_ text: String) {
        guard let session else {
            appendTranscript(title: "System", body: "Open a project first.")
            return
        }

        appendTranscript(title: "You", body: text)
        isStreaming = true
        agentActivity = .thinking
        NewPiLogger.info(category: "app", message: "User message sent", details: NewPiLogFormat.truncate(text, maxLength: 1000))
        Task {
            await session.prompt(text)
        }
    }

    func approvePendingTool() {
        guard let request = pendingToolApproval, let session else {
            NewPiLogger.error(category: "app", message: "Approve tapped with no pending request")
            return
        }
        NewPiLogger.info(
            category: "app",
            message: "User approved tool",
            details: "requestID=\(request.id) tool=\(request.toolName)"
        )
        pendingToolApproval = nil
        Task {
            await session.respondToToolApproval(requestID: request.id, approved: true)
        }
    }

    func denyPendingTool() {
        guard let request = pendingToolApproval, let session else {
            NewPiLogger.error(category: "app", message: "Deny tapped with no pending request")
            return
        }
        NewPiLogger.info(
            category: "app",
            message: "User denied tool",
            details: "requestID=\(request.id) tool=\(request.toolName)"
        )
        pendingToolApproval = nil
        Task {
            await session.respondToToolApproval(requestID: request.id, approved: false)
        }
    }

    func abort() {
        NewPiLogger.info(category: "app", message: "User aborted agent run")
        pendingToolApproval = nil
        agentActivity = .idle
        Task {
            await session?.abort()
            isStreaming = false
        }
    }

    private func subscribe(to session: AgentSession) {
        eventTask = Task { @MainActor in
            let stream = await session.events()
            for await event in stream {
                handle(event)
            }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            isStreaming = true
            agentActivity = .thinking
            NewPiLogger.info(category: "app", message: "UI: agent started")
        case let .messageStart(message):
            NewPiLogger.debug(category: "app", message: "UI: message started", details: message.roleLabel)
            if case let .compactionSummary(summary) = message {
                appendTranscript(title: "Summary", body: summary)
                NewPiLogger.info(
                    category: "agent",
                    message: "Context compacted",
                    details: "Summary length: \(summary.count) characters"
                )
            }
        case let .textDelta(delta):
            agentActivity = .writing
            appendOrUpdateAssistant(delta)
        case let .thinkingDelta(delta):
            NewPiLogger.debug(
                category: "app",
                message: "UI: reasoning delta",
                details: "length=\(delta.count)"
            )
        case let .toolApprovalRequired(request):
            pendingToolApproval = request
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
            agentActivity = .runningTool(name)
            appendTranscript(title: "Tool", body: "Running \(name)…")
            NewPiLogger.info(
                category: "app",
                message: "UI: tool execution started",
                details: "\(name)\n\(NewPiLogFormat.describeJSONValue(arguments))"
            )
        case let .toolExecutionEnd(_, name, result):
            let body = result.isError ? "Error: \(result.content)" : result.content
            if let lastIndex = transcript.indices.last,
               transcript[lastIndex].title == "Tool",
               transcript[lastIndex].body.hasPrefix("Running ") {
                let running = transcript[lastIndex]
                transcript[lastIndex] = NewPiTranscriptItem(
                    id: running.id,
                    title: "Tool \(name)",
                    body: body,
                    messageIndex: running.messageIndex,
                    sessionEntryID: running.sessionEntryID
                )
            } else {
                appendTranscript(title: "Tool \(name)", body: body)
            }
            NewPiLogger.info(
                category: "app",
                message: result.isError ? "UI: tool failed" : "UI: tool finished",
                details: "\(name): \(NewPiLogFormat.truncate(result.content, maxLength: 2000))"
            )
            agentActivity = .thinking
        case .agentEnd:
            isStreaming = false
            agentActivity = .idle
            pendingToolApproval = nil
            NewPiLogger.info(category: "app", message: "UI: agent finished")
            Task {
                await appendTruncatedOutputNoticeIfNeeded()
                await syncTranscriptMessageIndices()
                await refreshSessionList()
            }
        case let .error(error):
            appendTranscript(title: "Error", body: error.localizedDescription)
            isStreaming = false
            agentActivity = .idle
            pendingToolApproval = nil
            NewPiLogger.error(
                category: "app",
                message: "UI: agent error shown to user",
                details: error.localizedDescription
            )
        default:
            break
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

    private func rebuildTranscript(from messages: [AgentMessage], entryIDs: [String] = []) {
        let existingByMessageIndex = Dictionary(
            uniqueKeysWithValues: transcript.compactMap { item -> (Int, UUID)? in
                guard let messageIndex = item.messageIndex else { return nil }
                return (messageIndex, item.id)
            }
        )
        let existingByEntryID = Dictionary(
            uniqueKeysWithValues: transcript.compactMap { item -> (String, UUID)? in
                guard let sessionEntryID = item.sessionEntryID else { return nil }
                return (sessionEntryID, item.id)
            }
        )
        let streamingAssistantID = transcript.last(where: { $0.title == "NewPi" && $0.messageIndex == nil })?.id
        let lastAssistantMessageIndex = messages.lastIndex(where: {
            if case .assistant = $0 { return true }
            return false
        })

        transcript.removeAll()
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
                transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "You",
                    body: user.content,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .assistant(assistant):
                transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "NewPi",
                    body: assistant.text,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .toolResult(result):
                transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "Tool \(result.toolName)",
                    body: result.isError ? "Error: \(result.content)" : result.content,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            case let .compactionSummary(summary):
                transcript.append(NewPiTranscriptItem(
                    id: preservedID,
                    title: "Summary",
                    body: summary,
                    messageIndex: index,
                    sessionEntryID: entryID
                ))
            }
        }
        liveMessageCount = messages.count
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

    private func appendTruncatedOutputNoticeIfNeeded() async {
        guard let session else { return }
        let messages = await session.context.messages
        guard case let .assistant(assistant) = messages.last else { return }
        guard assistant.stopReason == .length,
              assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assistant.toolCalls.isEmpty else {
            return
        }

        let notice = assistant.reasoningContent.isEmpty
            ? "模型输出达到长度上限且未返回内容。请新开 session 或简化请求后重试。"
            : "模型推理达到长度上限，未完成最终回答或工具调用。请新开 session 或简化请求后重试。"
        appendTranscript(title: "System", body: notice)
        NewPiLogger.info(
            category: "app",
            message: "UI: truncated empty assistant output notice shown",
            details: "reasoningLength=\(assistant.reasoningContent.count)"
        )
    }

    private func syncTranscriptMessageIndices() async {
        guard let session else { return }
        let messages = await session.context.messages
        let entryIDs = await session.branchEntryIDs()
        rebuildTranscript(from: messages, entryIDs: entryIDs)
        branchPointCount = await session.branchPointCount()
        isForkedBranch = branchPointCount > 0
    }

    private func appendTranscript(title: String, body: String, messageIndex: Int? = nil) {
        transcript.append(NewPiTranscriptItem(title: title, body: body, messageIndex: messageIndex))
    }

    private func appendOrUpdateAssistant(_ delta: String) {
        if let last = transcript.last, last.title == "NewPi" {
            let index = transcript.count - 1
            transcript[index] = NewPiTranscriptItem(
                id: last.id,
                title: "NewPi",
                body: last.body + delta,
                messageIndex: last.messageIndex,
                sessionEntryID: last.sessionEntryID
            )
        } else {
            appendTranscript(title: "NewPi", body: delta)
        }
    }
}
