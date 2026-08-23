import AppKit
import Foundation
import NewPiCore
import SwiftUI

struct NewPiTranscriptItem: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct NewPiProviderListItem: Identifiable, Equatable {
    let profile: ProviderProfile
    var hasAPIKey: Bool

    var id: String { profile.id }
}

@MainActor
final class NewPiViewModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var transcript: [NewPiTranscriptItem] = []
    @Published var isStreaming = false
    @Published var pendingToolApproval: ToolApprovalRequest?
    @Published var providerConfig = ProviderConfigStore.bootstrapDefaultConfig()
    @Published var providerListItems: [NewPiProviderListItem] = []
    @Published var savedSessions: [SessionSummary] = []
    @Published var activeProviderName = "Anthropic"
    @Published var activeProviderID: String?
    @Published var activeProviderModel = ""
    @Published var activeProviderReady = false

    private var session: AgentSession?
    private var eventTask: Task<Void, Never>?
    private var currentSessionFileURL: URL?
    private let providerConfigStore = ProviderConfigStore()
    private let providerCredentialResolver = ProviderCredentialResolver()
    private let jsonlStore = JSONLSessionStore()

    init() {
        Task {
            await reloadProviders()
        }
    }

    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        Task {
            await refreshSessionList()
            await startNewSession()
        }
    }

    func reloadProviders() async {
        do {
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
        guard var profile = providerConfig.profiles.first(where: { $0.id == profileID }) else { return }

        do {
            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            let newConfig = AgentLoopConfig(
                model: profile.modelConfig,
                llm: llm,
                tools: BuiltInTools.codingTools(for: projectURL),
                toolPolicy: .codingAgentDefault
            )
            await session?.updateConfig(newConfig)

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

    private func beginSession(restoredContext: SessionContext?, fileURL: URL?) async {
        eventTask?.cancel()
        transcript.removeAll()
        pendingToolApproval = nil

        guard let projectURL else { return }

        do {
            let profile = try resolveProfile(for: restoredContext?.header)
            let messages = restoredContext.map { SessionManager.messages(from: $0) } ?? []
            rebuildTranscript(from: messages)

            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            let agentSession = AgentSessionFactory.codingSession(
                workingDirectory: projectURL,
                llm: llm,
                model: profile.modelConfig,
                restoredMessages: messages
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
            activeProviderID = profile.id
            activeProviderName = profile.name
            activeProviderModel = profile.modelID
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)

            subscribe(to: agentSession)
            await refreshSessionList()
        } catch {
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
        Task {
            await session.prompt(text)
        }
    }

    func approvePendingTool() {
        guard let request = pendingToolApproval, let session else { return }
        pendingToolApproval = nil
        Task {
            await session.respondToToolApproval(requestID: request.id, approved: true)
        }
    }

    func denyPendingTool() {
        guard let request = pendingToolApproval, let session else { return }
        pendingToolApproval = nil
        Task {
            await session.respondToToolApproval(requestID: request.id, approved: false)
        }
    }

    func abort() {
        pendingToolApproval = nil
        Task {
            await session?.abort()
            isStreaming = false
        }
    }

    private func subscribe(to session: AgentSession) {
        eventTask = Task {
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
        case let .messageStart(message):
            if case let .compactionSummary(summary) = message {
                appendTranscript(title: "Summary", body: summary)
            }
        case let .textDelta(delta):
            appendOrUpdateAssistant(delta)
        case let .thinkingDelta(delta):
            appendOrUpdateAssistant(delta)
        case let .toolApprovalRequired(request):
            pendingToolApproval = request
        case let .toolExecutionStart(_, name, _):
            appendTranscript(title: "Tool", body: "Running \(name)…")
        case let .toolExecutionEnd(_, name, result):
            appendTranscript(
                title: "Tool \(name)",
                body: result.isError ? "Error: \(result.content)" : result.content
            )
        case .agentEnd:
            isStreaming = false
            pendingToolApproval = nil
            Task { await refreshSessionList() }
        case let .error(error):
            appendTranscript(title: "Error", body: error.localizedDescription)
            isStreaming = false
            pendingToolApproval = nil
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

    private func rebuildTranscript(from messages: [AgentMessage]) {
        for message in messages {
            switch message {
            case let .user(user):
                appendTranscript(title: "You", body: user.content)
            case let .assistant(assistant):
                appendTranscript(title: "NewPi", body: assistant.text)
            case let .toolResult(result):
                appendTranscript(
                    title: "Tool \(result.toolName)",
                    body: result.isError ? "Error: \(result.content)" : result.content
                )
            case let .compactionSummary(summary):
                appendTranscript(title: "Summary", body: summary)
            }
        }
    }

    private func appendTranscript(title: String, body: String) {
        transcript.append(NewPiTranscriptItem(title: title, body: body))
    }

    private func appendOrUpdateAssistant(_ delta: String) {
        if let last = transcript.last, last.title == "NewPi" {
            let index = transcript.count - 1
            transcript[index] = NewPiTranscriptItem(title: "NewPi", body: last.body + delta)
        } else {
            appendTranscript(title: "NewPi", body: delta)
        }
    }
}
