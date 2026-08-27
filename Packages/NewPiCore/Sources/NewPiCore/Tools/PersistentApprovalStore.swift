import Foundation

/// 持久化「一直允许」权限记录：`~/.new-pi/agent/approvals.json`。
public final class PersistentApprovalStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var approvals: [ApprovalRecord] = []

    public init(fileURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("approvals.json")) {
        self.fileURL = fileURL
        load()
    }

    public func saveForever(_ record: ApprovalRecord) {
        lock.lock()
        defer { lock.unlock() }
        // 去重：同工具名 + 同指纹，只保留一条。
        approvals.removeAll { existing in
            existing.toolName == record.toolName &&
            existing.parametersFingerprint == record.parametersFingerprint
        }
        approvals.append(record)
        persistLocked()
    }

    public func removeForever(toolName: String, fingerprint: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        approvals.removeAll { record in
            guard record.toolName == toolName else { return false }
            if let fingerprint {
                return record.parametersFingerprint == fingerprint
            }
            return true
        }
        persistLocked()
    }

    public func foreverRecords() -> [ApprovalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return approvals
    }

    public func isForeverApproved(toolName: String, fingerprint: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approvals.contains { $0.matches(toolName: toolName, fingerprint: fingerprint) }
    }

    // MARK: - Private

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            approvals = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ApprovalRecord].self, from: data) {
            approvals = loaded
        } else {
            approvals = []
        }
    }

    private func persistLocked() {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(approvals) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
