import Foundation
import Testing
@testable import NewPiCore

@Suite("文件编辑记录")
struct ToolFileChangeTests {
    private func project() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("file-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, at path: String = "file.txt", in root: URL) async throws -> ToolResult {
        try await WriteTool().execute(id: "write", arguments: .object([
            "path": .string(path), "content": .string(text)
        ]), context: ToolContext(workingDirectory: root), onUpdate: nil)
    }

    /// 不调用 shell：重建 unified hunk 的旧/新字节并校验声明行数，包含无 LF 标记。
    private func verifyPatch(_ change: ToolFileChange, old: String, new: String) throws {
        let patch = try #require(change.diff)
        let lines = patch.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("--- "))
        #expect(lines[1].hasPrefix("+++ "))
        let header = lines[2].split(separator: " ")
        let oldCount = Int(header[1].split(separator: ",")[1])
        let newCount = Int(header[2].split(separator: ",")[1])
        var oldBytes = Data(), newBytes = Data()
        var removed = 0, added = 0
        var index = 3
        while index < lines.count - 1 {
            let line = lines[index]
            let marker = try #require(line.first)
            #expect([" ", "-", "+"].contains(String(marker)))
            var bytes = Data((String(line.dropFirst()) + "\n").utf8)
            if index + 1 < lines.count, lines[index + 1] == "\\ No newline at end of file" {
                bytes.removeLast()
                index += 1
            }
            if marker != "+" { oldBytes.append(bytes); removed += 1 }
            if marker != "-" { newBytes.append(bytes); added += 1 }
            index += 1
        }
        #expect(oldBytes == Data(old.utf8))
        #expect(newBytes == Data(new.utf8))
        #expect(oldCount == removed && newCount == added)
    }

    @Test("新建、覆盖、空文件和不可变历史，不混入其他文件")
    func writesAndHistory() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try "unrelated".write(to: root.appendingPathComponent("unrelated"), atomically: true, encoding: .utf8)
        let first = try await write("hello\n", in: root)
        let created = try #require(first.fileChanges.first)
        #expect(first.fileChanges.count == 1 && !first.isError)
        #expect(created.before == nil && created.beforeExists == false)
        #expect(created.after == "hello\n" && !created.isTruncated)
        #expect(created.path == root.resolvingSymlinksInPath().appendingPathComponent("file.txt").path)
        #expect(created.diff?.contains("+++ \"b/file.txt\"\n") == true)
        try verifyPatch(created, old: "", new: "hello\n")
        let second = try await write("other", in: root)
        let changed = try #require(second.fileChanges.first)
        #expect(changed.before == "hello\n" && changed.beforeExists == true)
        try verifyPatch(changed, old: "hello\n", new: "other")
        try FileManager.default.removeItem(at: root.appendingPathComponent("file.txt"))
        #expect(created.after == "hello\n" && changed.after == "other")
        let empty = try await write("", in: root)
        #expect(empty.fileChanges.first?.beforeExists == false)
        #expect(empty.fileChanges.first?.before == nil && empty.fileChanges.first?.after == "")
        let fromEmpty = try await write("new", in: root)
        #expect(fromEmpty.fileChanges.first?.beforeExists == true)
        #expect(fromEmpty.fileChanges.first?.before == "")
        #expect((first.durationSeconds ?? -1) >= 0)
    }

    @Test("无变化 write 包括超过历史预算的大文件，不产生编辑记录")
    func unchanged() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        for text in ["", "same\n", String(repeating: "大", count: 40_000)] {
            try text.write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            let result = try await write(text, in: root)
            #expect(result.fileChanges.isEmpty && !result.isError)
        }
    }

    @Test("生产 edit 的唯一匹配、无变化、失败与实际 after")
    func edits() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try "old\nkeep\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = EditTool(snapshotStore: .forProject(root))
        func edit(old: String, new: String) async throws -> ToolResult {
            try await tool.execute(id: "edit", arguments: .object([
                "filePath": .string("file.txt"), "old_string": .string(old), "new_string": .string(new)
            ]), context: ToolContext(workingDirectory: root), onUpdate: nil)
        }
        let result = try await edit(old: "old", new: "new")
        let change = try #require(result.fileChanges.first)
        try verifyPatch(change, old: "old\nkeep\n", new: "new\nkeep\n")
        #expect(change.after == (try String(contentsOf: file, encoding: .utf8)))
        #expect(change.before == "old\nkeep\n")
        #expect(try await edit(old: "new", new: "new").fileChanges.isEmpty)
        await #expect(throws: AgentError.self) { try await edit(old: "absent", new: "bad") }
        try "repeat repeat".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: AgentError.self) { try await edit(old: "repeat", new: "bad") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "repeat repeat")
        #expect(change.after == "new\nkeep\n")
    }

    @Test("真正逐行 patch 保留 LF、CRLF、空行和 Unicode 字节差异",
          arguments: ["", "a", "a\n", "\n", "\n\n", "a\r\nb\r\n", "é\n", "e\u{301}\n"],
          ["", "b", "a\n", "\n", "\n\n", "a\r\nb\r\n", "é\n", "e\u{301}\n"])
    func linePatches(old: String, new: String) throws {
        guard !old.utf8.elementsEqual(new.utf8) else { return }
        let change = ToolFileChange.capture(path: "space\tquote\"\nfile", before: old, after: new, beforeExists: true)
        #expect(!change.isTruncated)
        try verifyPatch(change, old: old, new: new)
    }

    @Test("LCS 保留未变化行，不将全文件当增删")
    func minimalChanges() throws {
        let old = "head\nsame\nold\nsame\ntail\n"
        let new = "head\nsame\nnew\nsame\ntail\n"
        let change = ToolFileChange.capture(path: "f", before: old, after: new, beforeExists: true)
        try verifyPatch(change, old: old, new: new)
        let body = try #require(change.diff).components(separatedBy: "\n").dropFirst(3)
        #expect(body.filter { $0.hasPrefix("-") } == ["-old"])
        #expect(body.filter { $0.hasPrefix("+") } == ["+new"])
    }

    @Test("snapshot、diff 输出和 LCS 预算显式不完整，不产出部分 patch")
    func bounds() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = String(repeating: "🙂", count: 40_000)
        let result = try await write(large, in: root)
        let change = try #require(result.fileChanges.first)
        #expect(change.isTruncated && change.diff == nil && change.note != nil)
        #expect((change.after?.utf8.count ?? 0) <= ToolFileChange.maxSnapshotBytes)
        #expect((change.after?.utf8.count ?? 0) % 4 == 0)
        let overwritten = try await write("small", in: root)
        #expect(overwritten.fileChanges.first?.beforeExists == true)
        #expect(overwritten.fileChanges.first?.before == nil)
        #expect(overwritten.fileChanges.first?.isTruncated == true)
        let a = (0..<1100).map { "a\($0)\n" }.joined()
        let b = (0..<1100).map { "b\($0)\n" }.joined()
        let bounded = ToolFileChange.capture(path: "f", before: a, after: b, beforeExists: true)
        #expect(bounded.diff == nil && bounded.isTruncated)
        let outputBound = ToolFileChange.capture(path: "f", before: String(repeating: "a", count: 32768),
            after: String(repeating: "b", count: 32768), beforeExists: true)
        #expect(outputBound.diff == nil && outputBound.isTruncated)
        for item in [change, bounded, outputBound] {
            let retained = [item.before, item.after, item.diff].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
            #expect(retained <= ToolFileChange.maxRetainedTextBytes)
        }
    }

    @Test("二进制覆盖明确缺 before，失败不返回成功编辑")
    func binaryAndFailure() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data([0, 255, 1]).write(to: file)
        let change = try #require(try await write("text", in: root).fileChanges.first)
        #expect(change.before == nil && change.beforeExists == true)
        #expect(change.after == "text" && change.diff == nil && change.isTruncated)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
        await #expect(throws: AgentError.self) { try await write("bad", at: "directory", in: root) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "text")
    }

}