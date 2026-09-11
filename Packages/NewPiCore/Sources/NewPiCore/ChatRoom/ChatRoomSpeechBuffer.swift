import Foundation

/// 一次正在进行的角色发言的显式渲染身份；插话追加到消息列表不会改变它。
public struct ChatRoomLiveSpeech: Equatable, Sendable {
    public enum Phase: Sendable { case waiting, thinking, text, complete }
    public var id: String
    public var messageID: String?
    public var phase: Phase

    public init(id: String, messageID: String? = nil, phase: Phase = .waiting) {
        self.id = id
        self.messageID = messageID
        self.phase = phase
    }
}

/// 消费端合并器。首批立即显示，后续增量最多等待 120ms；没有新 token 时也会冲刷。
/// Task 只在有脏数据时存在，边界/结束取消定时任务，不在空闲时周期唤醒。
@MainActor
final class ChatRoomSpeechBuffer {
    private let runtime: ChatRoomRuntime
    private let speechID: String
    private let interval: Duration
    private var messageID: String?
    private var text = ""
    private var thinking = ""
    private var lastFlush: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    nonisolated let incoming = StreamingDeltaBuffer()
    private var finished = false

    init(runtime: ChatRoomRuntime, speechID: String, interval: Duration = .milliseconds(120)) {
        self.runtime = runtime
        self.speechID = speechID
        self.interval = interval
        runtime.liveSpeech = ChatRoomLiveSpeech(id: speechID)
    }

    func beginSegment(_ message: ChatRoomMessage) {
        flush()
        messageID = message.id
        lastFlush = nil
        runtime.messages.append(message)
        runtime.liveSpeech = ChatRoomLiveSpeech(id: speechID, messageID: message.id)
    }

    func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        if runtime.liveSpeech?.phase == .thinking { flush() }
        setPhase(.text)
        text += delta
        scheduleFlush()
    }

    func appendThinking(_ delta: String) {
        guard !delta.isEmpty else { return }
        // 极少数 provider 会交错返回 reasoning/text；正文开始后不重新亮起 Thinking 光标。
        if runtime.liveSpeech?.phase != .text { setPhase(.thinking) }
        thinking += delta
        scheduleFlush()
    }

    func completeMessage() {
        flush()
        setPhase(.complete)
    }

    func flush() {
        task?.cancel()
        task = nil
        let pending = incoming.drain()
        if !pending.thinking.isEmpty {
            if runtime.liveSpeech?.phase != .text { setPhase(.thinking) }
            thinking += pending.thinking
        }
        if !pending.text.isEmpty {
            setPhase(.text)
            text += pending.text
        }
        guard !text.isEmpty || !thinking.isEmpty else { return }
        let textChunk = text, thinkingChunk = thinking
        text = ""
        thinking = ""
        lastFlush = ContinuousClock.now
        guard let messageID,
              let index = runtime.messages.firstIndex(where: { $0.id == messageID }) else { return }
        // 一次发布，避免 Thinking 和正文分别触发两次全量适配。
        var message = runtime.messages[index]
        message.content += textChunk
        if !thinkingChunk.isEmpty {
            message.reasoningContent = (message.reasoningContent ?? "") + thinkingChunk
        }
        runtime.messages[index] = message
    }

    func finish() {
        flush()
        finished = true
        if runtime.liveSpeech?.id == speechID { runtime.liveSpeech = nil }
        messageID = nil
    }

    private func setPhase(_ phase: ChatRoomLiveSpeech.Phase) {
        guard runtime.liveSpeech?.id == speechID, runtime.liveSpeech?.phase != phase else { return }
        runtime.liveSpeech?.phase = phase
    }

    private func scheduleFlush() {
        guard !finished else { return }
        let elapsed = lastFlush.map { $0.duration(to: .now) } ?? interval
        if elapsed >= interval { flush(); return }
        guard task == nil else { return }
        let delay = interval - elapsed
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }

    /// 原始 delta 在后台合并；边界才等待 MainActor，并先冲刷前序字符。
    /// 取消要传递给消费任务并等它退出，避免结束后仍往下一段投递。
    func consume(
        _ stream: AsyncStream<AgentEvent>,
        applyEvent: @escaping @MainActor @Sendable (AgentEvent) -> Void
    ) async {
        let worker = Task.detached { [self] in
            for await event in stream {
                switch event {
                case .textDelta(let delta):
                    if incoming.appendText(delta) {
                        Task { @MainActor in scheduleFlush() }
                    }
                case .thinkingDelta(let delta):
                    if incoming.appendThinking(delta) {
                        Task { @MainActor in scheduleFlush() }
                    }
                default:
                    await MainActor.run {
                        flush()
                        applyEvent(event)
                    }
                }
            }
            await MainActor.run { flush() }
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// 生产端可能先进入审批回调，消费端还没处理完之前的文字事件。
/// 只有消费到 toolApprovalRequired（已冲刷前序增量）才允许显示审批。
@MainActor
final class ChatRoomApprovalEventGate {
    private var reached: Set<String> = []
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var finished = false

    func reach(_ id: String) {
        guard !finished else { return }
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: true) }
        else { reached.insert(id) }
    }

    func wait(for id: String) async -> Bool {
        guard !finished, !Task.isCancelled else { return false }
        if reached.remove(id) != nil { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, !Task.isCancelled else { continuation.resume(returning: false); return }
                // 同一 requestID 不应并发复用，异常重复请求保守拒绝。
                guard waiters[id] == nil else { continuation.resume(returning: false); return }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }

    func finish() {
        finished = true
        let pending = waiters.values
        waiters.removeAll()
        reached.removeAll()
        for waiter in pending { waiter.resume(returning: false) }
    }
}
