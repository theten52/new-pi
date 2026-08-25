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
            var entries: [NewPiLogEntry] = []
        }
        let box = CaptureBox()
        NewPiLogger.setHandler { entry in
            box.entries.append(entry)
        }
        defer { NewPiLogger.setHandler(nil) }

        NewPiLogger.info(category: "test", message: "hello", details: "world", secrets: ["secret"])
        #expect(box.entries.count == 1)
        #expect(box.entries[0].category == "test")
        #expect(box.entries[0].message == "hello")
        #expect(box.entries[0].details == "world")
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
