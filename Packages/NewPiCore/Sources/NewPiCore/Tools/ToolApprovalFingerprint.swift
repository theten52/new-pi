import CryptoKit
import Foundation

/// 基于工具参数的稳定指纹，用于区分同一工具的不同调用。
public enum ToolApprovalFingerprint {
    /// 对 JSONValue 做规范化 + 稳定排序后 SHA256。
    public static func make(arguments: JSONValue) -> String {
        let canonical = canonicalJSON(arguments)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 递归规范化 JSON：字典按键排序。
    private static func canonicalJSON(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case let .bool(b):
            return b ? "true" : "false"
        case let .int(n):
            return "\(n)"
        case let .double(n):
            return "\(n)"
        case let .string(s):
            return jsonString(s)
        case let .array(arr):
            return "[\(arr.map(canonicalJSON).joined(separator: ","))]"
        case let .object(dict):
            let pairs = dict.keys.sorted().map { key in
                "\(jsonString(key)):\(canonicalJSON(dict[key] ?? .null))"
            }
            return "{\(pairs.joined(separator: ","))}"
        }
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONEncoder().encode(s)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }
}
