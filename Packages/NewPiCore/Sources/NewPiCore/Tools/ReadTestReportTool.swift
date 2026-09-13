import Foundation
import Darwin

public struct ReadTestReportTool: AgentTool {
    public static let maxBytes = 1024 * 1024
    public let name = "read_test_report"
    public let definition = ToolDefinition(
        name: "read_test_report",
        description: "Read an existing UTF-8 JUnit XML report (max 1 MiB) inside the project, without symlinks. Counts actual testcase outcomes, not suite counters; errors count as failed. Does not run tests, commands or network requests, or prove freshness. DTD/entity declarations are rejected.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["path": .object([
                "type": .string("string"), "description": .string("Project-relative report file path; no .. or symlinks")
            ])]),
            "required": .array([.string("path")]), "additionalProperties": .bool(false)
        ])
    )

    public init() {}

    public func execute(id: String, arguments: JSONValue, context: ToolContext,
                        onUpdate: (@Sendable (ToolProgress) -> Void)?) async throws -> ToolResult {
        try Task.checkCancellation()
        guard let object = arguments.objectValue, Set(object.keys) == ["path"] else {
            throw AgentError.invalidState("只接受 path 参数。")
        }
        let path = try ToolArguments.requiredString(arguments, key: "path")
        let data = try Self.read(path: path, root: context.workingDirectory)
        let report = try Self.parse(data, path: path)
        return ToolResult(content: "JUnit 报告 \(path)：passed=\(report.passed), failed=\(report.failed), skipped=\(report.skipped), total=\(report.total)。仅读取已有报告，未运行测试或验证时效。\(report.total == 0 ? "未发现测试用例。" : "")",
                          testReport: report)
    }

    /// 根目录由调用方选择；解析根的系统别名（如 /var），根内每层均禁止符号链接。
    /// 使用目录描述符逐层打开，避免先检查路径再按同一路径打开的符号链接竞态。
    private static func read(path: String, root: URL) throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.utf8.contains(0), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentError.invalidState("报告必须是项目内相对文件路径，不能包含空段、.、.. 或 NUL。")
        }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var directory = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw AgentError.invalidState("无法打开项目目录。") }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = Darwin.openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw AgentError.invalidState("报告目录不存在或包含符号链接。") }
            Darwin.close(directory)
            directory = next
        }
        let file = Darwin.openat(directory, String(components.last!), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw AgentError.invalidState("报告不存在、不可读或为符号链接。") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= Int64(maxBytes) else {
            throw AgentError.invalidState("报告必须是 ≤1 MiB 的普通文件。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let capacity = min(buffer.count, maxBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, capacity) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AgentError.invalidState("读取报告失败。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxBytes else { throw AgentError.invalidState("报告超过 1 MiB。") }
        }
        return data
    }

    static func parse(_ data: Data, path: String) throws -> TestReport {
        guard data.count <= maxBytes, !data.isEmpty,
              let text = String(data: data, encoding: .utf8), !text.utf8.contains(0),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw AgentError.invalidState("报告必须是非空 UTF-8 XML（≤1 MiB），禁止 DTD 和实体声明。")
        }
        let delegate = JUnitReportParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, delegate.valid, delegate.sawRoot,
              delegate.stack.isEmpty else {
            throw AgentError.invalidState("无效或不支持的 JUnit XML（需要 testsuite/testsuites 与 testcase 结构）。")
        }
        return TestReport(path: path, passed: delegate.passed, failed: delegate.failed, skipped: delegate.skipped)
    }
}

/// 有界流式计数，不保留失败正文、日志或实体内容。忽略 suite 汇总属性，避免重复计数。
private final class JUnitReportParser: NSObject, XMLParserDelegate {
    var stack: [String] = []
    var valid = true
    var sawRoot = false
    var passed = 0
    var failed = 0
    var skipped = 0
    private var outcome: Int? // 0=通过，1=跳过，2=失败（优先级最高）

    private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 64, !name.contains(":"), attributes["xmlns"] == nil else { reject(parser); return }
        let parent = stack.last
        if parent == nil {
            guard !sawRoot, name == "testsuite" || name == "testsuites" else { reject(parser); return }
            sawRoot = true
        }
        switch name {
        case "testsuite", "testsuites":
            guard parent == nil || parent == "testsuites" || parent == "testsuite" else { reject(parser); return }
        case "testcase":
            guard parent == "testsuite", outcome == nil, passed + failed + skipped < 10_000 else { reject(parser); return }
            // GoogleTest 禁用/跳过用例可能只有属性，没有 skipped 子节点。
            let status = attributes["status"]?.lowercased() ?? ""
            let result = attributes["result"]?.lowercased() ?? ""
            outcome = ["notrun", "disabled", "skipped"].contains(status)
                || ["suppressed", "skipped"].contains(result) ? 1 : 0
        case "failure", "error", "skipped":
            guard parent == "testcase", let current = outcome else { reject(parser); return }
            outcome = max(current, name == "skipped" ? 1 : 2)
        default: break
        }
        stack.append(name)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard stack.last == name else { reject(parser); return }
        if name == "testcase" {
            switch outcome {
            case 0: passed += 1
            case 1: skipped += 1
            case 2: failed += 1
            default: reject(parser); return
            }
            outcome = nil
        }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser)
        return nil
    }
}