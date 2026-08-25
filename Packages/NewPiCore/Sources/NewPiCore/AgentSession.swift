import Foundation

/// High-level facade used by the NewPi macOS app and CLI.
public actor AgentSession {
    public private(set) var context: AgentContext
    public private(set) var config: AgentLoopConfig
    private let loop = AgentLoop()
    private let approvalGate = ToolApprovalGate()
    private var runTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var steeringQueue: [AgentMessage] = []
    private var persistenceFileURL: URL?
    private var persistenceHeader: SessionHeader?
    private var jsonlStore = JSONLSessionStore()

    public init(context: AgentContext, config: AgentLoopConfig) {
        self.context = context
        var configured = config
        configured.requestToolApproval = { [approvalGate] request in
            await approvalGate.wait(for: request.id)
        }
        self.config = configured
    }

    public func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func prompt(_ text: String) {
        prompt(.user(text))
    }

    public func prompt(_ message: AgentMessage) {
        runTask?.cancel()
        runTask = Task {
            let steeringProvider: (@Sendable () async -> AgentMessage?)? = { [weak self] in
                guard let self else { return nil }
                return await self.dequeueSteering()
            }

            for await event in loop.run(
                prompt: message,
                context: context,
                config: config,
                steeringProvider: steeringProvider
            ) {
                if case let .contextSnapshot(snapshot) = event {
                    context = snapshot
                    persistIfNeeded()
                }
                broadcast(event)
            }
        }
    }

    public func steer(_ text: String) {
        steeringQueue.append(.user(text))
    }

    public func respondToToolApproval(requestID: String, approved: Bool) async {
        await approvalGate.respond(requestID: requestID, approved: approved)
    }

    public func abort() {
        runTask?.cancel()
        Task {
            await approvalGate.cancelAll()
        }
        broadcast(.error(.aborted))
        broadcast(.agentEnd)
    }

    public func updateConfig(_ config: AgentLoopConfig) {
        var configured = config
        configured.requestToolApproval = { [approvalGate] request in
            await approvalGate.wait(for: request.id)
        }
        self.config = configured
    }

    public func attachPersistence(fileURL: URL, header: SessionHeader) {
        persistenceFileURL = fileURL
        persistenceHeader = header
    }

    public var attachedSessionHeader: SessionHeader? {
        persistenceHeader
    }

    private func persistIfNeeded() {
        guard let fileURL = persistenceFileURL, let header = persistenceHeader else { return }
        let rebuilt = SessionManager.rebuildContext(from: context.messages, header: header)
        try? jsonlStore.save(rebuilt, to: fileURL)
    }

    private func dequeueSteering() -> AgentMessage? {
        guard !steeringQueue.isEmpty else { return nil }
        return steeringQueue.removeFirst()
    }

    private func broadcast(_ event: AgentEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}

public enum AgentSessionFactory {
    public static func codingSession(
        workingDirectory: URL,
        llm: any LLMProvider,
        model: ModelConfig,
        toolPolicy: ToolPolicyRules = .codingAgentDefault,
        restoredMessages: [AgentMessage] = [],
        additionalTools: [any AgentTool] = []
    ) -> AgentSession {
        var tools = BuiltInTools.codingTools(for: workingDirectory)
        tools.append(contentsOf: additionalTools)
        let config = AgentLoopConfig(
            model: model,
            llm: llm,
            tools: tools,
            toolPolicy: toolPolicy
        )
        let context = AgentContext(
            systemPrompt: SystemPromptComposer.compose(for: workingDirectory).text,
            messages: restoredMessages,
            workingDirectory: workingDirectory
        )
        return AgentSession(context: context, config: config)
    }
}
