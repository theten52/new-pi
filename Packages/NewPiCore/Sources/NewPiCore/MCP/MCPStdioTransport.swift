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
    private var readTask: Task<Void, Never>?
    private var buffer = Data()
    private var pendingFrames: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []

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

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await self.enqueueWaiter(continuation)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPTransportError.timedOut
            }

            guard let result = try await group.next() else {
                throw MCPTransportError.receiveFailed("No MCP response")
            }
            group.cancelAll()
            return result
        }
    }

    func close() async {
        readTask?.cancel()
        readTask = nil
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
            waiter.resume(throwing: MCPTransportError.notStarted)
        }
        waiters.removeAll()
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Data, Error>) {
        if let frame = pendingFrames.first {
            pendingFrames.removeFirst()
            continuation.resume(returning: frame)
            return
        }
        waiters.append(continuation)
    }

    private func startReadLoop(stdout: FileHandle) {
        readTask = Task {
            while !Task.isCancelled {
                let chunk = stdout.availableData
                if chunk.isEmpty {
                    if process?.isRunning == false {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                appendChunk(chunk)
            }
            markProcessEnded()
        }
    }

    private func startStderrLoop(stderr: FileHandle) {
        Task {
            while !Task.isCancelled {
                let chunk = stderr.availableData
                if chunk.isEmpty {
                    if process?.isRunning == false {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                let text = String(data: chunk, encoding: .utf8) ?? ""
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    NewPiLogger.info(category: "mcp", message: "MCP stderr", details: trimmed)
                }
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
            waiter.resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }

    private func markProcessEnded() {
        let exitCode = process?.terminationStatus ?? -1
        for waiter in waiters {
            waiter.resume(throwing: MCPTransportError.processExited(code: exitCode))
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
