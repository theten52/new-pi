import Foundation
import Testing
@testable import NewPiCore

/// 所有写操作只用于隔离的临时仓库夹具，不调用 Agent 工具、不访问用户工作区 Git。
@Suite("WorkspaceChanges read-only Git")
struct WorkspaceChangesTests {
    private struct Repository: Sendable {
        let base: URL
        let root: URL

        init(name: String = "repo", initialize: Bool = true) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("newpi-changes-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if initialize {
                try git(["init", "--quiet", "--initial-branch=main"])
                try git(["config", "user.name", "Fixture"])
                try git(["config", "user.email", "fixture@example.invalid"])
                try git(["config", "commit.gpgsign", "false"])
            }
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
        var reader: WorkspaceChangesReader { WorkspaceChangesReader(configurationHome: base) }
        func file(_ path: String) -> URL { root.appendingPathComponent(path) }
        func write(_ path: String, _ text: String) throws { try write(path, bytes: Data(text.utf8)) }
        func write(_ path: String, bytes: Data) throws {
            try FileManager.default.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file(path))
        }

        @discardableResult
        func git(_ args: [String]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never"] + args
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": base.path, "LC_ALL": "C",
                                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                                   "GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceChangesError.gitFailed(process.terminationStatus) }
            return output
        }

        func commit() throws {
            try git(["add", "--all", "--", "."])
            try git(["commit", "--quiet", "-m", "fixture"])
        }
    }

    @Test("真实暂存、未暂存、新文件、删除与去重文件计数")
    func stagedUnstagedAndDeleted() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("both.txt", "base\n")
        try repo.write("deleted.txt", "remove me\n")
        try repo.write("staged-delete.txt", "staged removal\n")
        try repo.commit()
        try repo.write("both.txt", "staged\n")
        try repo.git(["add", "--", "both.txt"])
        try repo.write("both.txt", "worktree\n")
        try repo.write("new.txt", "new content\n")
        try FileManager.default.removeItem(at: repo.file("deleted.txt"))
        try repo.git(["rm", "--", "staged-delete.txt"])
        let indexBefore = try Data(contentsOf: repo.file(".git/index"))
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        #expect(snapshot.files.count == 4)
        let both = try #require(snapshot.files.first { $0.path == "both.txt" })
        #expect(both.hasStagedChanges && both.hasUnstagedChanges)
        let staged = try await reader.diff(for: both, area: .staged, in: snapshot)
        let unstaged = try await reader.diff(for: both, area: .unstaged, in: snapshot)
        #expect(staged.text.contains("-base\n+staged"))
        #expect(!staged.text.contains("+worktree"))
        #expect(unstaged.text.contains("-staged\n+worktree"))
        #expect(!staged.isTruncated && staged.kind == .patch)
        let deleted = try #require(snapshot.files.first { $0.path == "deleted.txt" })
        #expect(deleted.worktreeStatus == "D")
        #expect(try await reader.diff(for: deleted, area: .unstaged, in: snapshot).text.contains("-remove me"))
        let stagedDeleted = try #require(snapshot.files.first { $0.path == "staged-delete.txt" })
        #expect(stagedDeleted.indexStatus == "D")
        #expect(try await reader.diff(for: stagedDeleted, area: .staged, in: snapshot).text.contains("deleted file mode"))
        let new = try #require(snapshot.files.first { $0.path == "new.txt" })
        #expect(new.isUntracked)
        let preview = try await reader.diff(for: new, area: .untracked, in: snapshot)
        #expect(preview.kind == .untrackedText && preview.text == "new content\n")
        #expect(try Data(contentsOf: repo.file(".git/index")) == indexBefore)
        #expect(!FileManager.default.fileExists(atPath: repo.file(".git/index.lock").path))
    }

    @Test("rename -z 保留空格、Unicode、换行与原路径")
    func renameAndSpecialPaths() async throws {
        let repo = try Repository(); defer { repo.remove() }
        let old = "旧 名\n\t.txt", new = "新 名\n\t.txt"
        try repo.write(old, "same content\nsecond line\n")
        try repo.commit()
        try FileManager.default.moveItem(at: repo.file(old), to: repo.file(new))
        try repo.git(["add", "--all", "--", "."])
        try repo.write("untracked 名\nline.txt", "preview\n")
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        #expect(snapshot.files.count == 2)
        let renamed = try #require(snapshot.files.first { $0.path == new })
        #expect(renamed.originalPath == old && renamed.indexStatus == "R")
        #expect(renamed.displayPath == "新 名\\n\\t.txt")
        let diff = try await reader.diff(for: renamed, area: .staged, in: snapshot)
        #expect(diff.text.contains("rename from "))
        #expect(diff.text.contains("rename to "))
        #expect(diff.text.contains("similarity index 100%"))
    }

    @Test("pathspec magic、选项与通配符均作为字面路径")
    func literalPaths() async throws {
        let repo = try Repository(); defer { repo.remove() }
        let paths = ["--output=owned", ":(glob)*", "[ab]*.txt", "other.txt"]
        for path in paths { try repo.write(path, "base\n") }
        try repo.commit()
        for (index, path) in paths.enumerated() { try repo.write(path, "unique-\(index)\n") }
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        #expect(snapshot.files.count == 4)
        for (index, path) in paths.enumerated() {
            let file = try #require(snapshot.files.first { $0.path == path })
            let diff = try await reader.diff(for: file, area: .unstaged, in: snapshot)
            #expect(diff.text.contains("+unique-\(index)"))
            for other in paths.indices where other != index { #expect(!diff.text.contains("+unique-\(other)")) }
        }
        #expect(!FileManager.default.fileExists(atPath: repo.file("owned").path))
    }

    @Test("空仓库、无 HEAD 的暂存新文件、干净仓库")
    func unbornAndClean() async throws {
        let repo = try Repository(); defer { repo.remove() }
        let reader = repo.reader
        #expect(try await reader.changes(in: repo.root).files.isEmpty)
        try repo.write("first.txt", "first\n")
        try repo.git(["add", "--", "first.txt"])
        let snapshot = try await reader.changes(in: repo.root)
        let first = try #require(snapshot.files.first)
        #expect(first.indexStatus == "A")
        let diff = try await reader.diff(for: first, area: .staged, in: snapshot)
        #expect(diff.text.contains("new file mode") && diff.text.contains("+first"))
        try repo.commit()
        #expect(try await reader.changes(in: repo.root).files.isEmpty)
    }

    @Test("非 Git 不自动 init；不存在的目录明确失败")
    func nonGit() async throws {
        let repo = try Repository(initialize: false); defer { repo.remove() }
        let reader = repo.reader
        await #expect(throws: WorkspaceChangesError.notRepository) { try await reader.changes(in: repo.root) }
        #expect(!FileManager.default.fileExists(atPath: repo.file(".git").path))
        await #expect(throws: WorkspaceChangesError.invalidDirectory) { try await reader.changes(in: repo.file("missing")) }
    }

    @Test("从子目录读取整个 Git 根；根目录尾部换行不被 trim")
    func rootScope() async throws {
        let repo = try Repository(name: "repo 空格\n"); defer { repo.remove() }
        try repo.write("outside.txt", "outside\n")
        try repo.write("nested/inside.txt", "inside\n")
        let snapshot = try await repo.reader.changes(in: repo.file("nested"))
        // Foundation 会保留 /var 别名，而 Git 返回 /private/var；以 Git 实际输出为准。
        let expectedRoot = String(decoding: try repo.git(["rev-parse", "--show-toplevel"]).dropLast(), as: UTF8.self)
        #expect(snapshot.repositoryRoot.path == expectedRoot)
        #expect(snapshot.repositoryRoot.path.hasSuffix("repo 空格\n"))
        #expect(snapshot.requestedDirectory.path == repo.file("nested").resolvingSymlinksInPath().path)
        #expect(Set(snapshot.files.map(\.path)) == ["outside.txt", "nested/inside.txt"])
    }

    @Test("文本里的二进制提示不是二进制；遵循 Git ignore 规则")
    func binaryLookalikeAndIgnoredFiles() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("text.txt", "base\n")
        try repo.write(".gitignore", "ignored.txt\n")
        try repo.commit()
        try repo.write("text.txt", "Binary files a/example and b/example differ\n")
        try repo.write("ignored.txt", "ignored fixture\n")
        try repo.write("global-ignored.txt", "global ignored fixture\n")
        let ignoreFile = repo.base.appendingPathComponent("global-ignore")
        let traceFile = repo.base.appendingPathComponent("must-not-log")
        try "global-ignored.txt\n".write(to: ignoreFile, atomically: true, encoding: .utf8)
        try "[core]\n\texcludesFile = \(ignoreFile.path)\n[trace2]\n\teventTarget = \(traceFile.path)\n".write(
            to: repo.base.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        #expect(snapshot.files.count == 1)
        let file = try #require(snapshot.files.first)
        let diff = try await reader.diff(for: file, area: .unstaged, in: snapshot)
        #expect(diff.kind == .patch)
        #expect(diff.text.contains("+Binary files "))
        #expect(!FileManager.default.fileExists(atPath: traceFile.path))
    }

    @Test("未跟踪嵌套 Git 仓库作为一个条目，不递归读取")
    func nestedRepositoryEntry() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("nested/file", "nested fixture\n")
        try repo.git(["-C", repo.file("nested").path, "init", "--quiet"])
        try repo.git(["-C", repo.file("nested").path, "add", "--", "file"])
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        let file = try #require(snapshot.files.first { $0.path == "nested/" })
        #expect(snapshot.files.count == 1)
        let preview = try await reader.diff(for: file, area: .untracked, in: snapshot)
        #expect(preview.kind == .unavailable && preview.text.isEmpty)
    }

    @Test("跟踪与未跟踪二进制、非 UTF-8 内容均不伪造文本")
    func binary() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("tracked.bin", bytes: Data([0, 1, 2]))
        try repo.commit()
        try repo.write("tracked.bin", bytes: Data([0, 1, 3]))
        try repo.write("untracked.bin", bytes: Data([0, 8, 9]))
        try repo.write("non-utf8", bytes: Data([0xFF, 0xFE, 0xFD]))
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        for file in snapshot.files {
            let diff = try await reader.diff(for: file, area: file.isUntracked ? .untracked : .unstaged, in: snapshot)
            #expect(diff.kind == .binary)
            if file.isUntracked { #expect(diff.text.isEmpty) }
        }
    }

    @Test("diff 与预览截断明确，status 截断拒绝不准确计数")
    func boundedOutput() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("tracked.txt", "base\n")
        try repo.commit()
        try repo.write("tracked.txt", String(repeating: "many lines\n", count: 1000))
        try repo.write("new.txt", String(repeating: "新内容\n", count: 1000))
        let reader = WorkspaceChangesReader(limits: .init(diffBytes: 128), configurationHome: repo.base)
        let snapshot = try await reader.changes(in: repo.root)
        for file in snapshot.files {
            let diff = try await reader.diff(for: file, area: file.isUntracked ? .untracked : .unstaged, in: snapshot)
            #expect(diff.isTruncated)
            #expect(diff.text.utf8.count <= 128)
            #expect(diff.message != nil)
            if file.isUntracked { #expect(diff.kind == .untrackedText) }
        }
        for i in 0..<30 { try repo.write("long-file-name-\(i).txt", "x") }
        let tiny = WorkspaceChangesReader(limits: .init(statusBytes: 256), configurationHome: repo.base)
        await #expect(throws: WorkspaceChangesError.outputLimit) { try await tiny.changes(in: repo.root) }
    }

    @Test("symlink 只展示目标；祖先 symlink 替换不能读出根目录")
    func symlinkContainment() async throws {
        let repo = try Repository(); defer { repo.remove() }
        let outside = repo.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "synthetic-private-content".write(to: outside.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: repo.file("link"), withDestinationURL: outside.appendingPathComponent("file"))
        try repo.write("dir/file", "inside")
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        let link = try #require(snapshot.files.first { $0.path == "link" })
        let preview = try await reader.diff(for: link, area: .untracked, in: snapshot)
        #expect(preview.kind == .symbolicLink)
        #expect(!preview.text.contains("synthetic-private-content"))
        #expect(preview.text == outside.appendingPathComponent("file").path)
        let nested = try #require(snapshot.files.first { $0.path == "dir/file" })
        try FileManager.default.removeItem(at: repo.file("dir"))
        try FileManager.default.createSymbolicLink(at: repo.file("dir"), withDestinationURL: outside)
        await #expect(throws: WorkspaceChangesError.unsafePath) {
            try await reader.diff(for: nested, area: .untracked, in: snapshot)
        }
    }

    @Test("禁用外部 diff、textconv、clean/process filter 和 fsmonitor")
    func disablesExternalPrograms() async throws {
        let repo = try Repository(); defer { repo.remove() }
        try repo.write("file.txt", "base\n")
        try repo.write(".gitattributes", "*.txt diff=fixture filter=fixture\n")
        try repo.commit()
        try repo.write("file.txt", "changed\n")
        let marker = repo.base.appendingPathComponent("executed")
        let program = repo.base.appendingPathComponent("must-not-run")
        try "#!/bin/sh\nprintf ran > '\(marker.path)'\nexit 1\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        for key in ["diff.external", "diff.fixture.command", "diff.fixture.textconv", "filter.fixture.clean",
                    "filter.fixture.smudge", "filter.fixture.process", "core.fsmonitor"] {
            try repo.git(["config", key, program.path])
        }
        try repo.git(["config", "filter.fixture.required", "true"])
        let reader = repo.reader
        let snapshot = try await reader.changes(in: repo.root)
        let file = try #require(snapshot.files.first { $0.path == "file.txt" })
        let diff = try await reader.diff(for: file, area: .unstaged, in: snapshot)
        #expect(diff.text.contains("-base\n+changed"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("stderr 持续排空且内存受限，不泄露 Git 错误原文")
    func stderrDrain() throws {
        let repo = try Repository(); defer { repo.remove() }
        let output = try repo.reader.git(["--unknown-" + String(repeating: "x", count: 80_000)],
            in: repo.root, cap: 128, deadline: ProcessInfo.processInfo.systemUptime + 5)
        #expect(output.exitCode != 0)
        #expect(output.stderr.count == 16384)
        #expect(WorkspaceChangesError.gitFailed(output.exitCode).localizedDescription.count < 100)
    }

    @Test("明确超时与取消，而非返回空清单")
    func timeoutAndCancellation() async throws {
        let repo = try Repository(); defer { repo.remove() }
        let noBudget = WorkspaceChangesReader(limits: .init(timeout: 0), configurationHome: repo.base)
        await #expect(throws: WorkspaceChangesError.timeout) { try await noBudget.changes(in: repo.root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repo.reader.changes(in: repo.root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("运行中的 Git 等待输入时也受预算约束并被终止")
    func runningProcessTimeout() throws {
        let repo = try Repository(); defer { repo.remove() }
        let input = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
        }
        let started = ProcessInfo.processInfo.systemUptime
        // cat-file --batch 等待仍打开的管道，不靠外部脚本或 sleep 制造阻塞。
        #expect(throws: WorkspaceChangesError.timeout) {
            try repo.reader.git(["cat-file", "--batch"], in: repo.root, cap: 128,
                deadline: started + 0.15, input: input.fileHandleForReading)
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    @Test("损坏 NUL 状态、缺少 rename 原路径、越界路径全部拒绝")
    func malformedStatus() throws {
        for bytes in [Data(" M file".utf8), Data("R  new\0".utf8), Data("?? ../outside\0".utf8),
                      Data("?? /outside\0".utf8), Data([63, 63, 32, 255, 0])] {
            #expect(throws: WorkspaceChangesError.invalidStatus) { try WorkspaceChangesReader.parseStatus(bytes) }
        }
        let parsed = try WorkspaceChangesReader.parseStatus(Data("R  new\nname\0old name\0 M file\0".utf8))
        #expect(parsed.count == 2)
        #expect(parsed.first { $0.path == "new\nname" }?.originalPath == "old name")
    }
}