import Foundation

/// 工具审批审计记录：每次工具调用一条，用于事后 review 权限设计是否合理。
public struct ToolApprovalAuditEntry: Sendable, Equatable, Codable {
    /// 审批路径：本次调用是如何被放行的。
    public enum Authorization: String, Sendable, Codable {
        case notRequired = "not-required"   // 工具策略本身不要求审批（如 read）
        case lowRisk = "low-risk"           // 只读命令，按危险等级豁免
        case sessionRecord = "session"      // 命中本对话授权记录
        case foreverRecord = "forever"      // 命中持久化授权记录
        case prompted                        // 实际弹窗，由用户决定
    }

    public var timestamp: Date
    public var workingDirectory: String
    public var callID: String
    public var toolName: String
    /// 原始参数（JSON 字符串；超长截断并置 argumentsTruncated）。
    public var arguments: String
    public var argumentsTruncated: Bool
    public var summary: String
    public var fingerprint: String
    public var dangerLevel: ToolDangerLevel
    public var dangerReason: String?
    public var matchedRules: [String]
    /// 工具策略是否要求审批（未经危险等级豁免）。
    public var policyRequiresApproval: Bool
    /// 实际是否弹窗等待用户决定。
    public var approvalPrompted: Bool
    public var authorization: Authorization
    /// 弹窗时用户的决定；未弹窗为 nil。
    public var decisionApproved: Bool?
    public var decisionScope: ApprovalScope?

    public init(
        timestamp: Date = Date(),
        workingDirectory: String,
        callID: String,
        toolName: String,
        arguments: String,
        argumentsTruncated: Bool,
        summary: String,
        fingerprint: String,
        dangerLevel: ToolDangerLevel,
        dangerReason: String?,
        matchedRules: [String],
        policyRequiresApproval: Bool,
        approvalPrompted: Bool,
        authorization: Authorization,
        decisionApproved: Bool? = nil,
        decisionScope: ApprovalScope? = nil
    ) {
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.callID = callID
        self.toolName = toolName
        self.arguments = arguments
        self.argumentsTruncated = argumentsTruncated
        self.summary = summary
        self.fingerprint = fingerprint
        self.dangerLevel = dangerLevel
        self.dangerReason = dangerReason
        self.matchedRules = matchedRules
        self.policyRequiresApproval = policyRequiresApproval
        self.approvalPrompted = approvalPrompted
        self.authorization = authorization
        self.decisionApproved = decisionApproved
        self.decisionScope = decisionScope
    }
}

/// 审计日志写入器：JSONL 追加写 `~/.new-pi/agent/approval-audit.jsonl`。
/// 超过 maxFileSize 后轮转为 `.1`（只保留一代旧文件）。
public final class ToolApprovalAuditLogger: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let maxFileSize: Int

    /// 单个参数字段的截断上限（write 的 content 可能很大）。
    public static let maxArgumentsLength = 16 * 1024

    public init(
        fileURL: URL = NewPiConfig.defaultAgentDirectory.appendingPathComponent("approval-audit.jsonl"),
        maxFileSize: Int = 10 * 1024 * 1024
    ) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
    }

    /// 序列化原始参数为 JSON 字符串（超长截断）。
    public static func serializeArguments(_ arguments: JSONValue) -> (text: String, truncated: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw: String
        if let data = try? encoder.encode(arguments), let text = String(data: data, encoding: .utf8) {
            raw = text
        } else {
            raw = String(describing: arguments)
        }
        if raw.count > maxArgumentsLength {
            return (String(raw.prefix(maxArgumentsLength)), true)
        }
        return (raw, false)
    }

    public func record(_ entry: ToolApprovalAuditEntry) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        appendLine(line)
    }

    // MARK: - Private

    private func appendLine(_ line: String) {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        rotateIfNeeded()

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL),
              let data = line.data(using: .utf8) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 审计日志失败不阻塞工具执行
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int,
              size > maxFileSize else {
            return
        }
        let rotated = fileURL.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(fileURL.pathExtension)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}
