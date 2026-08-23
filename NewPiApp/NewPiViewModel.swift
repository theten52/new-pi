import AppKit
import Foundation
import NewPiCore
import SwiftUI

struct NewPiTranscriptItem: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

@MainActor
final class NewPiViewModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var transcript: [NewPiTranscriptItem] = []
    @Published var isStreaming = false
    @Published var hasAnthropicAPIKey = false
    @Published var anthropicAPIKeyDraft = ""

    private var session: AgentSession?
    private var eventTask: Task<Void, Never>?
    private let credentialResolver = CredentialResolver()

    init() {
        Task {
            await refreshCredentialState()
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

    func resetSession() async {
        eventTask?.cancel()
        transcript.removeAll()

        guard let projectURL else { return }

        let llm = LLMProviderFactory.anthropic(resolver: credentialResolver)
        let config = AgentLoopConfig(
            model: ModelConfig(provider: "anthropic", modelID: "claude-sonnet-4-20250514"),
            llm: llm
        )
        let context = AgentContext(
            systemPrompt: "You are NewPi, a native macOS coding agent.",
            workingDirectory: projectURL
        )

        let session = AgentSession(context: context, config: config)
        self.session = session
        subscribe(to: session)
    }

    func saveAnthropicAPIKey() async {
        do {
            try await credentialResolver.saveAPIKey(anthropicAPIKeyDraft, for: .anthropic)
            anthropicAPIKeyDraft = ""
            await refreshCredentialState()
            await resetSession()
        } catch {
            appendTranscript(title: "Error", body: error.localizedDescription)
        }
    }

    func refreshCredentialState() async {
        hasAnthropicAPIKey = (try? await credentialResolver.hasAPIKey(for: .anthropic)) ?? false
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

    func abort() {
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
        case let .toolExecutionStart(_, name, _):
            appendTranscript(title: "Tool", body: "Running \(name)…")
        case let .toolExecutionEnd(_, name, result):
            appendTranscript(
                title: "Tool \(name)",
                body: result.isError ? "Error: \(result.content)" : result.content
            )
        case .agentEnd:
            isStreaming = false
        case let .error(error):
            appendTranscript(title: "Error", body: error.localizedDescription)
            isStreaming = false
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
