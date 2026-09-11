import Foundation

/// 单次发送的稀疏时间线。只记录阶段和单调时钟，不记录正文、路径或凭据。
public final class RequestLatencyTrace: @unchecked Sendable {
    public enum Stage: String, Sendable, CaseIterable {
        case sendEntered, sendAccepted, sendRejected, promptReceived, agentStarted
        case preparationStarted, preparationFinished
        case providerStarted, requestSent, responseHeaders, firstProviderText
        case firstConsumerText, firstUIFlush, firstJSDispatch, firstDOMAcknowledged
        case firstFrameCallback, frameNotObserved, presentationUnavailable
        case textDone, terminalReceived, providerEnded, agentEnded, uiUnlocked, failed
    }

    public let id: UUID
    private let started: ContinuousClock.Instant
    private let lock = NSLock()
    private var stages: [Stage: Double] = [:]

    public init(id: UUID = UUID()) {
        self.id = id
        started = .now
        mark(.sendEntered)
    }

    /// 返回值仅表示首次到达；同一阶段不反复写日志。
    @discardableResult
    public func mark(_ stage: Stage) -> Bool {
        let elapsed = started.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        lock.lock()
        guard stages[stage] == nil else { lock.unlock(); return false }
        stages[stage] = ms
        lock.unlock()
        NewPiLogger.info(category: "latency", message: "Request latency milestone",
            details: "runID=\(id.uuidString) stage=\(stage.rawValue) elapsedMs=\(String(format: "%.3f", ms))")
        return true
    }

    public func hasReached(_ stage: Stage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stages[stage] != nil
    }
}

/// 普通 Task 会继承；常驻 detached UI 消费者显式持有本次 trace，不依赖全局“当前会话”。
public enum RequestLatencyContext {
    @TaskLocal public static var current: RequestLatencyTrace?
}
