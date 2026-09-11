import Foundation

/// Session 与聊天室共用的线程安全增量缓冲。只在首次变脏时调度 UI，后续字符原地合并。
public final class StreamingDeltaBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var thinking = ""
    private var dirty = false

    public init() {}

    public func appendText(_ delta: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let needsSchedule = !dirty
        text += delta
        dirty = true
        return needsSchedule
    }

    public func appendThinking(_ delta: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let needsSchedule = !dirty
        thinking += delta
        dirty = true
        return needsSchedule
    }

    public func drain() -> (text: String, thinking: String) {
        lock.lock()
        defer { lock.unlock() }
        let result = (text: text, thinking: thinking)
        text = ""
        thinking = ""
        dirty = false
        return result
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return text.count + thinking.count
    }
}
