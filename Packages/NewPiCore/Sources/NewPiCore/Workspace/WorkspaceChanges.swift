import Foundation
import Darwin

/// 只读 Git 视图，不代表某次 Agent 执行的归属，也不提供恢复操作。
public enum WorkspaceChanges {
    public static let notice = "工作区 Git 改动，包含用户和其他工具修改，并非本轮 Agent 独占；只读，无撤销或回滚"

    /// 路径控制字符转义仅用于显示；执行 Git 时始终使用原始路径。
    public static func displayPath(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            switch scalar.value {
            case 92: return "\\\\"
            case 10: return "\\n"
            case 13: return "\\r"
            case 9: return "\\t"
            case 0..<32, 127, 0x202A...0x202E, 0x2066...0x2069:
                return "\\u{\(String(scalar.value, radix: 16))}"
            default: return String(scalar)
            }
        }.joined()
    }
}

public struct WorkspaceChangedFile: Sendable, Equatable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    public var hasStagedChanges: Bool { !isUntracked && indexStatus != " " }
    public var hasUnstagedChanges: Bool { !isUntracked && worktreeStatus != " " }
    public var displayPath: String { WorkspaceChanges.displayPath(path) }
    public var statusLabel: String {
        if isUntracked { return "未跟踪" }
        func label(_ c: Character) -> String {
            switch c {
            case "A": "新增"
            case "M": "修改"
            case "D": "删除"
            case "R": "重命名"
            case "C": "复制"
            case "U": "冲突"
            case "T": "类型变化"
            default: String(c)
            }
        }
        return [hasStagedChanges ? "暂存 · \(label(indexStatus))" : nil,
                hasUnstagedChanges ? "未暂存 · \(label(worktreeStatus))" : nil]
            .compactMap { $0 }.joined(separator: " / ")
    }
}

public struct WorkspaceChangesSnapshot: Sendable, Equatable {
    public let requestedDirectory: URL
    /// 总是整个 Git 根目录，包括所选子目录以外的改动。
    public let repositoryRoot: URL
    public let files: [WorkspaceChangedFile]
    public let readAt: Date
}

public enum WorkspaceDiffArea: String, Sendable, CaseIterable {
    case staged, unstaged, untracked
}

public struct WorkspaceFileDiff: Sendable, Equatable {
    public enum Kind: Sendable { case patch, untrackedText, binary, symbolicLink, unavailable }
    public let kind: Kind
    public let text: String
    public let isTruncated: Bool
    public let message: String?
}

public enum WorkspaceChangesError: Error, LocalizedError, Sendable, Equatable {
    case notRepository, invalidDirectory, gitUnavailable, timeout, outputLimit
    case gitFailed(Int32), invalidStatus, unsafePath, unreadableFile

    public var errorDescription: String? {
        switch self {
        case .notRepository: "此目录不在 Git 工作区中；仅支持 Git，不会自动初始化仓库。"
        case .invalidDirectory: "工作目录不存在或无法访问。"
        case .gitUnavailable: "无法启动系统 Git。"
        case .timeout: "读取超时，未取得完整结果。请稍后刷新。"
        case .outputLimit: "文件清单或配置超过读取上限，无法给出准确文件数。"
        case .gitFailed(let code): "Git 读取失败（退出码 \(code)）；未取得完整结果。"
        case .invalidStatus: "Git 文件清单不完整或含不支持的非 UTF-8 路径，无法给出准确文件数。"
        case .unsafePath: "路径超出安全读取范围，或父目录是符号链接；未读取内容。"
        case .unreadableFile: "文件已变化、不可访问或不是普通文件；请刷新文件清单。"
        }
    }
}

/// 所有 Process / 文件 IO 均在独立任务执行，不占用 MainActor。
public struct WorkspaceChangesReader: Sendable {
    public struct Limits: Sendable {
        public let statusBytes: Int
        public let diffBytes: Int
        public let timeout: TimeInterval
        public init(statusBytes: Int = 8 * 1024 * 1024, diffBytes: Int = 256 * 1024,
                    timeout: TimeInterval = 8) {
            self.statusBytes = max(1, min(statusBytes, 64 * 1024 * 1024))
            self.diffBytes = max(1, min(diffBytes, 4 * 1024 * 1024))
            self.timeout = timeout.isFinite ? max(0, min(timeout, 60)) : 8
        }
    }

    public let limits: Limits
    private let configurationHome: URL?

    /// 默认保留用户 Git 配置（例如全局 ignore）；测试可指定临时 HOME，隔离系统/用户配置。
    public init(limits: Limits = Limits(), configurationHome: URL? = nil) {
        self.limits = limits
        self.configurationHome = configurationHome
    }

    public func changes(in directory: URL) async throws -> WorkspaceChangesSnapshot {
        try await offMain {
            let deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
            guard directory.isFileURL else { throw WorkspaceChangesError.invalidDirectory }
            let requested = directory.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw WorkspaceChangesError.invalidDirectory }
            let probe = try git(["rev-parse", "--show-toplevel"], in: requested,
                                cap: limits.statusBytes, deadline: deadline)
            guard !probe.truncated else { throw WorkspaceChangesError.outputLimit }
            if probe.exitCode != 0 {
                let error = String(decoding: probe.stderr, as: UTF8.self)
                if error.contains("not a git repository") || error.contains("must be run in a work tree") {
                    throw WorkspaceChangesError.notRepository
                }
                throw WorkspaceChangesError.gitFailed(probe.exitCode)
            }
            // Git 加的最后一个换行不是路径的一部分；不能 trim 路径自身的空白/换行。
            var rootData = probe.stdout
            guard rootData.last == 10 else { throw WorkspaceChangesError.invalidStatus }
            rootData.removeLast()
            guard let rootPath = String(data: rootData, encoding: .utf8), rootPath.hasPrefix("/") else {
                throw WorkspaceChangesError.invalidStatus
            }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let filters = try disabledFilters(in: root, deadline: deadline)
            let result = try git(filters + ["status", "--porcelain=v1", "-z", "--untracked-files=all",
                                           "--ignore-submodules=none", "--renames"],
                                 in: root, cap: limits.statusBytes, deadline: deadline)
            guard !result.truncated else { throw WorkspaceChangesError.outputLimit }
            try result.checkExit()
            let files = try Self.parseStatus(result.stdout)
            try checkBudget(deadline)
            return WorkspaceChangesSnapshot(requestedDirectory: requested, repositoryRoot: root,
                                            files: files, readAt: Date())
        }
    }

    public func diff(for file: WorkspaceChangedFile, area: WorkspaceDiffArea,
                     in snapshot: WorkspaceChangesSnapshot) async throws -> WorkspaceFileDiff {
        try await offMain {
            let deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
            try Task.checkCancellation()
            guard snapshot.files.contains(file), Self.safeRelativePath(file.path),
                  file.originalPath.map(Self.safeRelativePath) ?? true else {
                throw WorkspaceChangesError.unsafePath
            }
            if area == .untracked {
                guard file.isUntracked else { throw WorkspaceChangesError.unsafePath }
                return try readUntracked(file.path, root: snapshot.repositoryRoot, deadline: deadline)
            }
            guard !file.isUntracked else { throw WorkspaceChangesError.unsafePath }
            let filters = try disabledFilters(in: snapshot.repositoryRoot, deadline: deadline)
            var args = filters + ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative",
                                  "--src-prefix=a/", "--dst-prefix=b/", "--output-indicator-new=+",
                                  "--output-indicator-old=-", "--output-indicator-context= ",
                                  "--submodule=short", "--ignore-submodules=none", "--find-renames",
                                  "--unified=3"]
            if area == .staged { args.append("--cached") }
            args.append("--")
            args.append(file.path)
            if let old = file.originalPath { args.append(old) }
            let result = try git(args, in: snapshot.repositoryRoot, cap: limits.diffBytes, deadline: deadline)
            if !result.truncated { try result.checkExit() }
            let text = String(decoding: result.stdout, as: UTF8.self)
            let binary = text.split(separator: "\n").contains { $0.hasPrefix("Binary files ") && $0.hasSuffix(" differ") }
            return WorkspaceFileDiff(kind: binary ? .binary : .patch, text: text,
                                     isTruncated: result.truncated,
                                     message: result.truncated ? "达到 diff 字节上限；仅显示前缀，不是完整 diff。" :
                                        (binary ? "二进制文件：不展示二进制内容。" :
                                            (text.isEmpty ? "当前分区没有可显示的文本 diff（内容可能已变化或仅有子模块状态变化）。" : nil)))
        }
    }

    // MARK: - NUL 分隔状态；rename 在 -z 下是新路径\0旧路径\0

    static func parseStatus(_ data: Data) throws -> [WorkspaceChangedFile] {
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw WorkspaceChangesError.invalidStatus }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var files: [WorkspaceChangedFile] = []
        var seen = Set<String>()
        var i = 0
        while i < fields.count - 1 {
            try Task.checkCancellation()
            let record = Array(fields[i]); i += 1
            guard record.count > 3, record[2] == 32,
                  let path = String(bytes: record.dropFirst(3), encoding: .utf8),
                  Self.safeRelativePath(path) else { throw WorkspaceChangesError.invalidStatus }
            let x = Character(UnicodeScalar(record[0]))
            let y = Character(UnicodeScalar(record[1]))
            let valid = " MADRCUT?!"
            guard valid.contains(x), valid.contains(y), seen.insert(path).inserted else {
                throw WorkspaceChangesError.invalidStatus
            }
            var old: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard i < fields.count - 1, let original = String(data: Data(fields[i]), encoding: .utf8),
                      Self.safeRelativePath(original) else { throw WorkspaceChangesError.invalidStatus }
                old = original; i += 1
            }
            files.append(WorkspaceChangedFile(path: path, originalPath: old, indexStatus: x, worktreeStatus: y))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        // Git 将未跟踪的嵌套仓库表示为 name/；允许这一末尾分隔符，但不遍历其内容。
        let relative = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !relative.isEmpty && !relative.hasPrefix("/") && !relative.utf8.contains(0) &&
        !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }

    /// 用 openat + O_NOFOLLOW 逐级锁定目录，避免检查后替换 symlink 的竞态。
    private func readUntracked(_ path: String, root: URL, deadline: TimeInterval) throws -> WorkspaceFileDiff {
        try checkBudget(deadline)
        var directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw WorkspaceChangesError.unsafePath }
        defer { close(directoryFD) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            try checkBudget(deadline)
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw WorkspaceChangesError.unsafePath }
            close(directoryFD); directoryFD = next
        }
        let name = components.last!
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw WorkspaceChangesError.unreadableFile
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return WorkspaceFileDiff(kind: .unavailable, text: "", isTruncated: false,
                                     message: "Git 将此目录作为一个条目报告（例如嵌套仓库）；不递归读取其内容。")
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = readlinkat(directoryFD, name, &bytes, bytes.count)
            guard count >= 0 else { throw WorkspaceChangesError.unreadableFile }
            return WorkspaceFileDiff(kind: .symbolicLink,
                                     text: WorkspaceChanges.displayPath(String(decoding: bytes.prefix(count), as: UTF8.self)),
                                     isTruncated: count == bytes.count, message: "符号链接目标；未跟随链接、未读取目标文件。")
        }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceChangesError.unsafePath }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceChangesError.unreadableFile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16384, limits.diffBytes + 1))
        while data.count <= limits.diffBytes {
            try checkBudget(deadline)
            let count = read(fd, &buffer, min(buffer.count, limits.diffBytes + 1 - data.count))
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceChangesError.unreadableFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        let truncated = data.count > limits.diffBytes || info.st_size > limits.diffBytes
        // 保留一个额外字节只用于判定截断，不伪造缺失的内容。
        let prefix = Data(data.prefix(limits.diffBytes))
        var decoded = String(data: prefix, encoding: .utf8)
        // 截断可能正好切开 UTF-8 码点；仅去掉最多三个尾字节。
        if decoded == nil && truncated {
            for removed in 1...min(3, prefix.count) {
                if let value = String(data: prefix.dropLast(removed), encoding: .utf8) { decoded = value; break }
            }
        }
        if prefix.contains(0) || decoded == nil {
            return WorkspaceFileDiff(kind: .binary, text: "", isTruncated: truncated,
                                     message: "二进制或非 UTF-8 文件（\(info.st_size) 字节）；不显示内容。\(truncated ? "仅检查了受限前缀。" : "")")
        }
        return WorkspaceFileDiff(kind: .untrackedText, text: decoded ?? "", isTruncated: truncated,
                                 message: "未跟踪文件内容预览（不是 Git diff）。\(truncated ? "达到读取上限；不是完整内容。" : "")")
    }

    /// clean/process filter 也能执行仓库配置里的程序；除了 diff/textconv 还需显式关掉。
    private func disabledFilters(in root: URL, deadline: TimeInterval) throws -> [String] {
        let result = try git(["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"],
                             in: root, cap: limits.statusBytes, deadline: deadline)
        guard !result.truncated else { throw WorkspaceChangesError.outputLimit }
        guard result.exitCode == 0 || result.exitCode == 1 else { throw WorkspaceChangesError.gitFailed(result.exitCode) }
        var args: [String] = []
        for entry in result.stdout.split(separator: 0) {
            guard let key = String(data: Data(entry), encoding: .utf8), !key.contains("=") else {
                throw WorkspaceChangesError.invalidStatus
            }
            args += ["-c", key + (key.hasSuffix(".required") ? "=false" : "=")]
        }
        return args
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try body() }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    private func checkBudget(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceChangesError.timeout }
    }

    struct GitOutput: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
        let truncated: Bool
        func checkExit() throws {
            guard exitCode == 0 else { throw WorkspaceChangesError.gitFailed(exitCode) }
        }
    }

    /// 不经 shell；非阻塞同时排空 stdout/stderr，超限立即终止，错误信息不带文件内容。
    func git(_ arguments: [String], in directory: URL, cap: Int, deadline: TimeInterval,
             input: FileHandle = .nullDevice) throws -> GitOutput {
        try checkBudget(deadline)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "--no-optional-locks", "--literal-pathspecs",
                             "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                             "-c", "core.untrackedCache=false", "-c", "core.attributesFile=/dev/null",
                             "-c", "diff.external=", "-c", "diff.trustExitCode=false",
                             "-c", "diff.suppressBlankEmpty=false",
                             "-c", "protocol.allow=never", "-c", "submodule.recurse=false"] + arguments
        // 不继承 GIT_DIR / INDEX_FILE / 外部 diff / 注入配置 / trace 等环境，避免越界或内容日志。
        var environment = ["PATH": "/usr/bin:/bin", "HOME": configurationHome?.path ?? NSHomeDirectory(), "LC_ALL": "C",
                           "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                           "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "", "GIT_ATTR_NOSYSTEM": "1",
                           "GIT_TRACE2": "0", "GIT_TRACE2_EVENT": "0", "GIT_TRACE2_PERF": "0"]
        if let configurationHome {
            environment["XDG_CONFIG_HOME"] = configurationHome.appendingPathComponent(".config").path
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = configurationHome.appendingPathComponent(".gitconfig").path
        } else {
            // 仅保留配置文件定位，不继承可注入命令、仓库定位或 trace 的环境。
            for key in ["XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM"] {
                environment[key] = ProcessInfo.processInfo.environment[key]
            }
        }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) >= 0, fcntl(errFD, F_SETFL, O_NONBLOCK) >= 0 else {
            throw WorkspaceChangesError.gitUnavailable
        }
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        do { try process.run() } catch { throw WorkspaceChangesError.gitUnavailable }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var stdout = Data(), stderr = Data()
        var ended = [false, false]
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 16384)
        while !ended.allSatisfy({ $0 }) || process.isRunning {
            try checkBudget(deadline)
            var descriptors = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, 2, 20)
            for index in 0..<2 where !ended[index] {
                // 每轮每管道只读一块，持续 stderr 不会饿死 stdout 或预算检查。
                let count = read(index == 0 ? outFD : errFD, &buffer, buffer.count)
                if count == 0 { ended[index] = true }
                else if count > 0 {
                    if index == 0 {
                        let remaining = max(0, cap - stdout.count)
                        stdout.append(contentsOf: buffer.prefix(min(count, remaining)))
                        if count > remaining { truncated = true }
                    } else {
                        stderr.append(contentsOf: buffer.prefix(min(count, max(0, 16384 - stderr.count))))
                    }
                } else if errno != EAGAIN && errno != EINTR {
                    throw WorkspaceChangesError.gitFailed(-1)
                }
            }
            if truncated { break }
        }
        if truncated && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return GitOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, truncated: truncated)
    }
}