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
}
