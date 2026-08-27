import Foundation
import Testing
@testable import NewPiCore

@Suite("NewPiLogSanitizer")
struct NewPiLogSanitizerTests {
    @Test("redacts API keys and bearer tokens")
    func redactsSecrets() {
        let input = """
        Authorization: Bearer sk-secret-token-123
        apiKey=super-secret-key
        """
        let sanitized = NewPiLogSanitizer.sanitize(
            input,
            secrets: ["super-secret-key", "sk-secret-token-123"]
        )
        #expect(!sanitized.contains("super-secret-key"))
        #expect(!sanitized.contains("sk-secret-token-123"))
        #expect(sanitized.contains("Bearer [redacted]"))
    }
}

@Suite("NewPiLogger")
struct NewPiLoggerTests {
    @Test("delivers entries to configured handler")
    func handlerDelivery() async {
        final class CaptureBox: @unchecked Sendable {
            private let lock = NSLock()
            var entries: [NewPiLogEntry] = []
            func append(_ entry: NewPiLogEntry) {
                lock.lock()
                defer { lock.unlock() }
                entries.append(entry)
            }
            func matching(category: String, message: String, details: String) -> [NewPiLogEntry] {
                lock.lock()
                defer { lock.unlock() }
                return entries.filter { $0.category == category && $0.message == message && $0.details == details }
            }
        }
        let box = CaptureBox()
        NewPiLogger.setHandler { entry in
            box.append(entry)
        }
        defer { NewPiLogger.setHandler(nil) }

        NewPiLogger.info(category: "test", message: "hello", details: "world", secrets: ["secret"])
        // The handler is a global; other concurrently running suites may also
        // emit logs into it. Match on our own marker instead of assuming a
        // single captured entry.
        let mine = box.matching(category: "test", message: "hello", details: "world")
        #expect(mine.count == 1)
        #expect(mine.first?.category == "test")
        #expect(mine.first?.message == "hello")
        #expect(mine.first?.details == "world")
    }

    @Test("writes debug entries to configured file sink")
    func fileSinkDelivery() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-pi-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = UUID().uuidString
        // 重定向全局日志到临时目录，避免读写真实 ~/.new-pi/agent/logs
        // （enable 会触发轮转检查，可能动到用户真实日志）。
        NewPiFileLogSink.shared.setLogsDirectoryOverride(tempDir)
        defer {
            NewPiLogger.setProjectLogDirectory(nil)
            NewPiFileLogSink.shared.setLogsDirectoryOverride(nil)
        }
        NewPiLogger.bootstrapFileLogging(sessionID: sessionID)
        NewPiLogger.setProjectLogDirectory(tempDir)
        NewPiLogger.debug(category: "test-file", message: "disk write", details: "payload")

        let projectLog = NewPiFileLogSink.shared.projectLogURL(for: tempDir)
        let globalLog = NewPiLogger.globalLogFileURL
        #expect(FileManager.default.fileExists(atPath: globalLog.path))
        #expect(FileManager.default.fileExists(atPath: projectLog.path))

        let projectContents = try String(contentsOf: projectLog, encoding: .utf8)
        let globalContents = try String(contentsOf: globalLog, encoding: .utf8)
        // The file sink is a process-wide singleton, so other concurrently
        // running suites may append their own log lines to both files around
        // the time this test writes. We therefore assert only on this test's
        // own marker line, not on the sole contents or the session header.
        let marker = "[DEBUG] [test-file] disk write"
        #expect(projectContents.contains(marker))
        #expect(projectContents.contains("payload"))
        #expect(globalContents.contains(marker))
    }
}
