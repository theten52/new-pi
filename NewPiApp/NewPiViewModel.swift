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
    @Published var activeProviderName = "Anthropic"
    @Published var activeProviderReady = false

    private var session: AgentSession?
    private var eventTask: Task<Void, Never>?
    private let providerConfigStore = ProviderConfigStore()
    private let providerCredentialResolver = ProviderCredentialResolver()

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
            await resetSession()
        }
    }

    func reloadProviders() async {
        do {
            providerConfig = try providerConfigStore.load()
            await refreshProviderList()
            await resetSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func refreshProviderList() async {
        var items: [NewPiProviderListItem] = []
        for profile in providerConfig.profiles {
            let hasKey = await providerCredentialResolver.hasAPIKey(for: profile)
            items.append(NewPiProviderListItem(profile: profile, hasAPIKey: hasKey))
        }
        providerListItems = items

        if let defaultProfile = try? providerConfig.defaultProfile() {
            activeProviderName = defaultProfile.name
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: defaultProfile)
        }
    }

    func setDefaultProvider(profileID: String) async {
        providerConfig.defaultProfileID = profileID
        do {
            try providerConfigStore.save(providerConfig)
            await refreshProviderList()
            await resetSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func saveProfile(_ profile: ProviderProfile, apiKeyDraft: String) async {
        do {
            try await providerCredentialResolver.saveAPIKey(apiKeyDraft, for: profile)
            try await providerConfigStore.upsertProfile(profile, in: &providerConfig)
            await refreshProviderList()
            await resetSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func deleteProfile(id: String) async {
        do {
            try providerConfigStore.deleteProfile(id: id, from: &providerConfig)
            await refreshProviderList()
            await resetSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func resetSession() async {
        eventTask?.cancel()
        transcript.removeAll()
        pendingToolApproval = nil

        guard let projectURL else { return }

        do {
            let profile = try providerConfig.defaultProfile()
            let llm = try LLMProviderFactory.make(
                profile: profile,
                credentialResolver: providerCredentialResolver
            )
            session = AgentSessionFactory.codingSession(
                workingDirectory: projectURL,
                llm: llm,
                model: profile.modelConfig
            )
            activeProviderName = profile.name
            activeProviderReady = await providerCredentialResolver.hasAPIKey(for: profile)

            if let session {
                subscribe(to: session)
            }
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
        case let .error(error):
            appendTranscript(title: "Error", body: error.localizedDescription)
            isStreaming = false
            pendingToolApproval = nil
        default:
            break
        }
    }

    private func appendTranscript(title: String, body: String) {
        transcript.append(NewPiTranscriptItem(title: title, body: body))
    }

    private func appendOrUpdateAssistant(_ delta: String) {
        if let index = transcript.lastIndex(where: { $0.title == "NewPi" }) {
            let existing = transcript[index]
            transcript[index] = NewPiTranscriptItem(title: existing.title, body: existing.body + delta)
        } else {
            appendTranscript(title: "NewPi", body: delta)
        }
    }
}
