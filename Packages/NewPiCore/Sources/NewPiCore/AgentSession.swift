import Foundation

/// High-level facade used by the NewPi macOS app and CLI.
public actor AgentSession {
    public private(set) var context: AgentContext
    public private(set) var config: AgentLoopConfig
    private let loop = AgentLoop()
    private var runTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var steeringQueue: [AgentMessage] = []

    public init(context: AgentContext, config: AgentLoopConfig) {
        self.context = context
        self.config = config
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
                }
                broadcast(event)
            }
        }
    }

    public func steer(_ text: String) {
        steeringQueue.append(.user(text))
    }

    public func abort() {
        runTask?.cancel()
        broadcast(.error(.aborted))
        broadcast(.agentEnd)
    }

    public func updateConfig(_ config: AgentLoopConfig) {
        self.config = config
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
