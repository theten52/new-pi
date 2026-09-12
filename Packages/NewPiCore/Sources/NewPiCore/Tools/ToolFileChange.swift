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

/// 审批时的只读拟执行预览，绝不是已完成编辑。所有分支均提供可展示说明。
public struct ToolChangePreview: Sendable, Equatable {
    public let fileChanges: [ToolFileChange]
    public let message: String
    public static let maxReadBytes = 64 * 1024
    public static let staleNotice = "这是审批时的拟执行预览，文件可能在实际执行前变化；历史记录以实际成功写入为准。"

    public static func make(request: ToolApprovalRequest, workingDirectory: URL) async -> ToolChangePreview {
        do {
            guard ["write", "edit", "write_file"].contains(request.toolName) else {
                return unavailable("该工具不支持文件 diff 预览；bash、子代理和 MCP 的文件修改不在捕获范围内。")
            }
            let path = try ToolArguments.requiredString(request.arguments, key: "path", aliases: ["file_path", "filePath"])
            let target = try readWithinRoot(path: path, root: workingDirectory)
            let after: String
            if request.toolName == "edit" {
                guard let before = target.text else { return unavailable("edit 目标不存在，无法预览。") }
                let old = try ToolArguments.requiredString(request.arguments, key: "old_string")
                let new = request.arguments.objectValue?["new_string"]?.stringValue ?? ""
                guard old.utf8.count <= maxReadBytes, new.utf8.count <= maxReadBytes else {
                    return unavailable("edit 参数超过预览预算，未计算差异。")
                }
                after = try ToolTextEdit.replacing(before, old: old, new: new, path: path)
            } else {
                if request.toolName == "write_file", request.arguments.objectValue?["content"]?.stringValue == nil {
                    return unavailable("write_file 缺少 content 参数。")
                }
                after = request.arguments.objectValue?["content"]?.stringValue ?? ""
            }
            guard after.utf8.count <= maxReadBytes else { return unavailable("拟写入内容超过 64 KiB 预览预算，未计算差异。") }
            if let before = target.text, before.utf8.elementsEqual(after.utf8) {
                return unavailable("拟执行写入与当前文件内容相同，没有文件编辑。")
            }
            let change = ToolFileChange.capture(path: target.path, before: target.text, after: after,
                beforeExists: target.text != nil,
                patchPath: ToolFileChange.patchPath(for: URL(fileURLWithPath: target.path), in: workingDirectory))
            return ToolChangePreview(fileChanges: [change], message: [change.note, staleNotice].compactMap { $0 }.joined(separator: " "))
        } catch {
            return unavailable(error.localizedDescription)
        }
    }

    private static func unavailable(_ reason: String) -> ToolChangePreview {
        ToolChangePreview(fileChanges: [], message: reason + " " + staleNotice)
    }

    /// 根目录是调用方的信任锚；不使用请求路径 resolvingSymlinksInPath 后再打开。
    /// 每一级通过已打开目录 fd + O_NOFOLLOW 进入，拒绝符号链接、..、设备/FIFO。
    private static func readWithinRoot(path: String, root: URL) throws -> (path: String, text: String?) {
        guard root.isFileURL else { throw AgentError.invalidState("工作目录不是本地目录。") }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        var relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relative.contains("\0"), !relative.hasPrefix("~"), relative.utf8.count <= 4096 else {
            throw AgentError.invalidState("不支持该预览路径。")
        }
        if relative.hasPrefix("/") {
            let roots = [root.standardizedFileURL.path, canonicalRoot]
            guard let base = roots.first(where: { relative.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
                throw AgentError.invalidState("预览只允许工作目录内路径，未读取根目录外文件。")
            }
            relative = String(relative.dropFirst(base == "/" ? 1 : base.count + 1))
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentError.invalidState("预览路径含空分量、. 或 ..，未读取文件。")
        }
        let resolvedPath = (canonicalRoot == "/" ? "" : canonicalRoot) + "/" + parts.joined(separator: "/")
        var directory = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AgentError.invalidState("无法安全打开工作目录。") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { return (resolvedPath, nil) }
                throw AgentError.invalidState("预览拒绝符号链接或不可访问的父目录。")
            }
            close(directory)
            directory = next
        }
        let fd = openat(directory, parts[parts.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return (resolvedPath, nil) }
            throw AgentError.invalidState("预览拒绝符号链接或不可访问的文件。")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentError.invalidState("仅普通文本文件支持预览。")
        }
        guard info.st_size <= maxReadBytes else { throw AgentError.invalidState("文件超过 64 KiB 预览读取预算。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maxReadBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxReadBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentError.invalidState("预览读取失败。")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maxReadBytes else { throw AgentError.invalidState("文件在读取期间超过预览预算。") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AgentError.invalidState("二进制或非 UTF-8 文件不支持文本预览。")
        }
        return (resolvedPath, text)
    }
}

/// 生产 edit 与审批共用精确替换规则，避免预览承诺一个实际会失败的替换。
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