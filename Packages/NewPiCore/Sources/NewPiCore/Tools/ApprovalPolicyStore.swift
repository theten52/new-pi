import Foundation

/// 危险评估策略持久化：`~/.new-pi/agent/approval-policy.json`。
public struct ApprovalPolicyStore: Sendable {
    public var fileURL: URL

    public init(fileURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("approval-policy.json")) {
        self.fileURL = fileURL
    }

    public func load() -> ApprovalPolicy {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return ApprovalPolicy()
        }
        let decoder = JSONDecoder()
        if let policy = try? decoder.decode(ApprovalPolicy.self, from: data) {
            return policy
        }
        return ApprovalPolicy()
    }

    public func save(_ policy: ApprovalPolicy) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(policy)
        try data.write(to: fileURL, options: .atomic)
    }
}
