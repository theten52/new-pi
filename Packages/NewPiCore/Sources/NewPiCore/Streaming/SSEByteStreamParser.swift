import Foundation

/// Accumulates raw SSE bytes and emits completed SSE blocks (lines separated by blank lines).
/// Decodes UTF-8 per line so multi-byte characters (e.g. CJK) are not corrupted.
public struct SSEByteStreamParser: Sendable {
    private var byteBuffer = Data()
    private var pendingLines: [String] = []

    public init() {}

    public mutating func feed(_ byte: UInt8) -> [[String]] {
        byteBuffer.append(byte)
        return drainCompleteBlocks(flushPartialLine: false)
    }

    public mutating func finish() -> [[String]] {
        drainCompleteBlocks(flushPartialLine: true)
    }

    private mutating func drainCompleteBlocks(flushPartialLine: Bool) -> [[String]] {
        var blocks: [[String]] = []

        while let newlineIndex = byteBuffer.firstIndex(of: 0x0A) {
            let lineData = byteBuffer[..<newlineIndex]
            byteBuffer.removeSubrange(..<byteBuffer.index(after: newlineIndex))

            var trimmed = Data(lineData)
            if trimmed.last == 0x0D {
                trimmed.removeLast()
            }

            let line = String(data: trimmed, encoding: .utf8) ?? ""
            if line.isEmpty {
                if !pendingLines.isEmpty {
                    blocks.append(pendingLines)
                    pendingLines = []
                }
            } else {
                pendingLines.append(line)
            }
        }

        if flushPartialLine, !byteBuffer.isEmpty {
            let line = String(data: byteBuffer, encoding: .utf8) ?? ""
            byteBuffer.removeAll()
            if !line.isEmpty {
                pendingLines.append(line)
            }
        }

        if flushPartialLine, !pendingLines.isEmpty {
            blocks.append(pendingLines)
            pendingLines = []
        }

        return blocks
    }
}
