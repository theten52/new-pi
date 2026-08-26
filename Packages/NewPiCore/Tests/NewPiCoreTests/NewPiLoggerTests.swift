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
        NewPiLogger.bootstrapFileLogging(sessionID: sessionID)
        NewPiLogger.setProjectLogDirectory(tempDir)
        NewPiLogger.debug(category: "test-file", message: "disk write", details: "payload")

        let projectLog = NewPiFileLogSink.shared.projectLogURL(for: tempDir)
        let globalLog = NewPiLogger.globalLogFileURL
        #expect(FileManager.default.fileExists(atPath: globalLog.path))
        #expect(FileManager.default.fileExists(atPath: projectLog.path))

        let projectContents = try String(contentsOf: projectLog, encoding: .utf8)
        #expect(projectContents.contains(sessionID))
        #expect(projectContents.contains("[DEBUG] [test-file] disk write"))
        #expect(projectContents.contains("payload"))
    }
}
