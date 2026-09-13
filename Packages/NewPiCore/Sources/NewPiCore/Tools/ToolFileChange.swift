import Foundation
import Darwin

/// 单次成功文件编辑的不可变记录。仅供历史展示，不是工作区状态、测试结果或回滚备份。
/// before/after 为原始 UTF-8 文本（含末尾换行），nil 表示不存在或未捕获；
/// beforeExists 区分新建(false)、已有(true)、未知(nil)。截断文本绝不生成伪完整 patch。
public struct ToolFileChange: Codable, Sendable, Equatable {
    public let path: String
    public let before: String?
    public let after: String?
    public let diff: String?
    public let isTruncated: Bool
    public let note: String?
    public let beforeExists: Bool?

    /// 生产生成器的文本预算：两份各 32 KiB 快照 + 最多 64 KiB patch。
    public static let maxSnapshotBytes = 32 * 1024
    public static let maxDiffBytes = 64 * 1024
    public static let maxRetainedTextBytes = 128 * 1024
    /// 展示端必须提示：空记录不等于工作区无修改，也不能推导测试通过数。
    public static let coverageNotice = "文件编辑记录仅覆盖内置 write/edit（含聊天室 write_file）的成功写入；不覆盖 bash、子代理、MCP 或外部修改，不代表测试通过。"

    public init(path: String, before: String?, after: String?, diff: String?,
                isTruncated: Bool, note: String? = nil, beforeExists: Bool? = nil) {
        self.path = path
        self.before = before
        self.after = after
        self.diff = diff
        self.isTruncated = isTruncated
        self.note = note
        self.beforeExists = beforeExists
    }

    /// 输入来自执行工具已持有的字符串；不读取磁盘，也不引用可变 backup。
    static func capture(path: String, before: String?, after: String,
                        beforeExists: Bool, beforeNote: String? = nil, patchPath: String? = nil) -> ToolFileChange {
        let old = snapshot(before)
        let new = snapshot(after)
        var notes = [beforeNote, old.note, new.note].compactMap { $0 }
        var incomplete = beforeNote != nil || old.incomplete || new.incomplete
        var patch: String?
        if !incomplete {
            patch = unifiedPatch(path: patchPath ?? path, before: before, after: after)
            if patch == nil {
                if !beforeExists && after.isEmpty {
                    notes.append("空文件创建没有可表示的文本行差异。")
                } else {
                    incomplete = true
                    notes.append("逐行 diff 超过计算或输出预算，未保存 patch；不可据此统计增删行。")
                }
            }
        }
        return ToolFileChange(path: path, before: old.text, after: new.text, diff: patch,
            isTruncated: incomplete, note: notes.isEmpty ? nil : notes.joined(separator: " "),
            beforeExists: beforeExists)
    }

    /// path 留绝对历史定位，patch 使用工作目录相对路径；只处理调用方已校验的路径。
    static func patchPath(for file: URL, in directory: URL) -> String {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root == "/" ? "/" : root + "/"
        return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
    }

    private static func snapshot(_ text: String?) -> (text: String?, incomplete: Bool, note: String?) {
        guard let text else { return (nil, false, nil) }
        // 含 NUL 的 UTF-8 也按二进制处理，不向历史塞入控制字符。
        guard !text.utf8.contains(0) else { return (nil, true, "二进制内容不保存文本快照或 patch。") }
        guard text.utf8.count > maxSnapshotBytes else { return (text, false, nil) }
        var data = Data(text.utf8.prefix(maxSnapshotBytes))
        // 最多回退 3 字节，保留 UTF-8 标量边界，不插入替代字符。
        while String(data: data, encoding: .utf8) == nil, !data.isEmpty { data.removeLast() }
        return (String(data: data, encoding: .utf8), true, "文本快照仅保存前 32 KiB，内容不完整，未生成 patch。")
    }

    /// 有界 LCS，最多 1,000,000 个 UInt32 单元（约 4 MiB）；超限不给近似增删行。
    /// 行以 LF 字节分割，CRLF 与最后一行无 LF 均保留；Data 比较避免 Unicode 规范等价吞掉字节变化。
    private static func unifiedPatch(path: String, before: String?, after: String) -> String? {
        func lines(_ text: String) -> [Data] {
            let data = Data(text.utf8)
            guard !data.isEmpty else { return [] }
            var result = data.split(separator: 10, omittingEmptySubsequences: false).map { Data($0) }
            for index in result.indices.dropLast() { result[index].append(10) }
            if result.last?.isEmpty == true { result.removeLast() }
            return result
        }
        let a = lines(before ?? "")
        let b = lines(after)
        if a == b { return before == nil ? nil : "" }
        guard a.count + b.count <= 8192 else { return nil }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        guard (n + 1) * (m + 1) <= 1_000_000 else { return nil }
        let width = m + 1
        var lcs = [UInt32](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * width + j] = a[prefix + i] == b[prefix + j]
                        ? lcs[(i + 1) * width + j + 1] + 1
                        : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
        }
        func quoted(_ value: String) -> String {
            // git/unified diff 的 C 风格路径引用，避免换行/制表符注入伪 hunk。
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let label = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var output = "--- \(before == nil ? "/dev/null" : quoted("a/" + label))\n+++ \(quoted("b/" + label))\n"
        output += "@@ -\(a.isEmpty ? 0 : 1),\(a.count) +\(b.isEmpty ? 0 : 1),\(b.count) @@\n"
        func append(_ marker: String, _ line: Data) {
            output += marker + String(decoding: line, as: UTF8.self)
            if line.last != 10 { output += "\n\\ No newline at end of file\n" }
        }
        for i in 0..<prefix { append(" ", a[i]) }
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n, j < m, a[prefix + i] == b[prefix + j] {
                append(" ", a[prefix + i]); i += 1; j += 1
            } else if i < n, j == m || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
                append("-", a[prefix + i]); i += 1
            } else {
                append("+", b[prefix + j]); j += 1
            }
            if output.utf8.count > maxDiffBytes { return nil }
        }
        for i in (a.count - suffix)..<a.count { append(" ", a[i]) }
        return output.utf8.count <= maxDiffBytes ? output : nil
    }
}

enum ToolExecutionTiming {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// 生产 write 的额外读取仅限已解析/授权的目标。快照受限；同大小文件按块精确比较，
/// 即使超过历史预算，无变化 write 也不会被计为编辑。读取失败在写入之前抛出。
enum ToolWriteCapture {
    struct Before {
        let text: String?
        let exists: Bool
        let matches: Bool
        let note: String?

        func changes(path: String, after: String, patchPath: String? = nil) -> [ToolFileChange] {
            guard !matches else { return [] }
            return [.capture(path: path, before: text, after: after, beforeExists: exists,
                beforeNote: note, patchPath: patchPath)]
        }
    }

    static func read(_ url: URL, replacement: String) throws -> Before {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return Before(text: nil, exists: false, matches: false, note: nil) }
            throw AgentError.invalidState("无法安全读取写入前文件，未执行写入。")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentError.invalidState("写入目标不是普通文件。")
        }
        let limit = ToolFileChange.maxSnapshotBytes
        var saved = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytes = replacement.utf8
        var position = bytes.startIndex
        var matches = info.st_size == bytes.count
        var reachedEnd = false
        // 不同大小文件只读取快照预算；同大小文件流式比较，额外内存恒定。
        while matches || saved.count <= limit {
            let readLimit = matches ? buffer.count : min(buffer.count, limit + 1 - saved.count)
            let count = Darwin.read(fd, &buffer, readLimit)
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentError.invalidState("读取写入前文件失败，未执行写入。")
            }
            if count == 0 { reachedEnd = true; break }
            if saved.count <= limit { saved.append(contentsOf: buffer.prefix(min(count, limit + 1 - saved.count))) }
            if matches {
                for byte in buffer.prefix(count) {
                    guard position != bytes.endIndex, bytes[position] == byte else { matches = false; break }
                    bytes.formIndex(after: &position)
                }
            }
        }
        matches = matches && reachedEnd && position == bytes.endIndex
        if saved.count > limit || !reachedEnd {
            return Before(text: nil, exists: true, matches: matches,
                note: "写入前文件超过 32 KiB 快照预算，未保存 before 或 patch；记录不完整。")
        }
        guard !saved.contains(0), let text = String(data: saved, encoding: .utf8) else {
            return Before(text: nil, exists: true, matches: matches,
                note: "写入前文件为二进制或非 UTF-8，未保存 before 或 patch。")
        }
        return Before(text: text, exists: true, matches: matches, note: nil)
    }
}

/// 生产 edit 的精确替换规则，要求旧文本恰好匹配一次。
enum ToolTextEdit {
    static func replacing(_ original: String, old: String, new: String, path: String) throws -> String {
        guard original.contains(old) else { throw AgentError.invalidState("old_string not found in \(path)") }
        let occurrences = original.components(separatedBy: old).count - 1
        guard occurrences == 1 else {
            throw AgentError.invalidState("old_string must match exactly once, found \(occurrences) matches")
        }
        return original.replacingOccurrences(of: old, with: new)
    }
}