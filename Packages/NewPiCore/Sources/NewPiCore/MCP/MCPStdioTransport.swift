import Foundation

public protocol MCPTransporting: AnyObject, Sendable {
    func start(command: String, arguments: [String], environment: [String: String]) async throws
    func send(frame: Data) async throws
    func receiveResponse(timeout: TimeInterval) async throws -> Data
    func close() async
}

public enum MCPTransportError: LocalizedError, Sendable, Equatable {
    case notStarted
    case processExited(code: Int32)
    case sendFailed
    case receiveFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            "MCP transport is not started"
        case let .processExited(code):
            "MCP server process exited (\(code))"
        case .sendFailed:
            "Unable to send MCP request"
        case let .receiveFailed(message):
            message
        case .timedOut:
            "MCP request timed out"
        }
    }
}

actor MCPStdioTransport: MCPTransporting {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var pendingFrames: [Data] = []
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Data, Error>)] = []

    func start(command: String, arguments: [String], environment: [String: String]) async throws {
        await close()

        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            // SECURITY-REVIEW: spawns user-configured MCP commands; args come from mcp.json only.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        startReadLoop(stdout: stdoutPipe.fileHandleForReading)
        startStderrLoop(stderr: stderrPipe.fileHandleForReading)
    }

    func send(frame: Data) async throws {
        guard let stdinHandle else {
            throw MCPTransportError.notStarted
        }
        try stdinHandle.write(contentsOf: frame)
    }

    func receiveResponse(timeout: TimeInterval) async throws -> Data {
        if let frame = pendingFrames.first {
            pendingFrames.removeFirst()
            return frame
        }

        // 用 waiter id 实现真正的超时：超时任务从队列中移除该 waiter 并
        // resume throwing，不依赖 task group 的 cancelAll（它无法穿透
        // CheckedContinuation，会让 receiveResponse 永久挂起且 waiter 泄漏）。
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                self.enqueueWaiter(id: id, continuation: continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeoutWaiter(id: id)
            }
        }
    }

    func close() async {
        readTask?.cancel()
        readTask = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        stdinHandle?.closeFile()
        stdinHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }
        process = nil
        buffer.removeAll()
        pendingFrames.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: MCPTransportError.notStarted)
        }
        waiters.removeAll()
    }

    private func enqueueWaiter(id: UUID, continuation: CheckedContinuation<Data, Error>) {
        if let frame = pendingFrames.first {
            pendingFrames.removeFirst()
            continuation.resume(returning: frame)
            return
        }
        waiters.append((id: id, continuation: continuation))
    }

    private func timeoutWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: MCPTransportError.timedOut)
    }

    private func startReadLoop(stdout: FileHandle) {
        stdoutHandle = stdout
        // readabilityHandler 在系统队列上回调，避免在 actor 上同步阻塞读
        // （availableData 是阻塞调用，曾导致 actor 被占死、握手即死锁）。
        // 数据经 AsyncStream 保序地送回 actor。
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        stdout.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF：进程退出或管道关闭
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(chunk)
        }
        readTask = Task {
            for await chunk in stream {
                appendChunk(chunk)
            }
            markProcessEnded()
        }
    }

    private func startStderrLoop(stderr: FileHandle) {
        stderrHandle = stderr
        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: chunk, encoding: .utf8) ?? ""
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                NewPiLogger.info(category: "mcp", message: "MCP stderr", details: trimmed)
            }
        }
    }

    private func appendChunk(_ chunk: Data) {
        buffer.append(chunk)
        do {
            let frames = try MCPJSONRPC.decodeFrames(from: &buffer)
            for frame in frames {
                deliver(frame)
            }
        } catch MCPJSONRPCFramingError.incompleteFrame {
            return
        } catch {
            NewPiLogger.error(category: "mcp", message: "MCP frame decode failed")
        }
    }

    private func deliver(_ frame: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }

    private func markProcessEnded() {
        let exitCode = process?.terminationStatus ?? -1
        for waiter in waiters {
            waiter.continuation.resume(throwing: MCPTransportError.processExited(code: exitCode))
        }
        waiters.removeAll()
    }
}

/// In-memory transport for unit tests.
actor MockMCPTransport: MCPTransporting {
    private var scriptedResponses: [Data] = []
    private(set) var sentFrames: [Data] = []
    private var isStarted = false

    init(responses: [Data] = []) {
        self.scriptedResponses = responses
    }

    func start(command: String, arguments: [String], environment: [String: String]) async throws {
        isStarted = true
    }

    func send(frame: Data) async throws {
        guard isStarted else {
            throw MCPTransportError.notStarted
        }
        sentFrames.append(frame)
    }

    func receiveResponse(timeout: TimeInterval) async throws -> Data {
        guard isStarted, !scriptedResponses.isEmpty else {
            throw MCPTransportError.receiveFailed("No scripted MCP response")
        }
        return scriptedResponses.removeFirst()
    }

    func close() async {
        isStarted = false
    }
}
