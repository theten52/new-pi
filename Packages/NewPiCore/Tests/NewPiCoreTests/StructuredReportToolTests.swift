import Foundation
import Darwin
import Testing
@testable import NewPiCore

enum StructuredReportFixtures {
    static func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structured-reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func step(_ id: String, _ status: String = "pending", title: String = "步骤") -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "status": .string(status)])
    }

    static let plan: JSONValue = .object(["steps": .array([step("X", "completed"), step("Y", "inProgress")])])
    static let xml = """
        <testsuites tests="999" failures="0"><testsuite name="outer" tests="999">
        <testcase name="pass &amp; escaped"/><testcase name="skip"><skipped/></testcase>
        <testsuite name="nested"><testcase name="fail"><failure>bad</failure><failure>again</failure></testcase>
        <testcase name="error"><skipped/><error>boom</error></testcase></testsuite>
        <system-out>日志不参与统计</system-out></testsuite></testsuites>
        """

    static var calls: [ToolCallContent] {
        [ToolCallContent(id: "plan", name: "update_plan", arguments: plan),
         ToolCallContent(id: "tests", name: "read_test_report", arguments: .object(["path": .string("report.xml")]))]
    }

    static var scripts: [[LLMStreamEvent]] {
        [calls.map { .toolCall($0) } + [.completed(stopReason: .toolUse, usage: UsageStats())],
         [.textDelta("报告读取完毕，不代表测试全过"), .completed(stopReason: .stop, usage: UsageStats())]]
    }
}

@Suite("结构化报告工具验证")
struct StructuredReportToolTests {
    @Test("计划声明提供真实步骤计数，不生成测试结论")
    func plan() async throws {
        let result = try await UpdatePlanTool().execute(id: "p", arguments: StructuredReportFixtures.plan,
            context: ToolContext(workingDirectory: URL(fileURLWithPath: "/unused")), onUpdate: nil)
        let plan = try #require(result.progressReport)
        #expect(plan.completedCount == 1 && plan.totalCount == 2)
        #expect(plan.steps.map(\.id) == ["X", "Y"])
        #expect(plan.source == .agentReport)
        #expect(!result.isError && result.testReport == nil)
        #expect(result.content.contains("agent report") && result.content.contains("未经执行验证"))
        #expect(try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test("拒绝空、重复、错误类型/状态、多进行中及超限步骤")
    func invalidPlans() async {
        let step = StructuredReportFixtures.step
        let invalid: [JSONValue] = [
            .object([:]), .object(["steps": .array([])]), .object(["steps": .string("wrong")]),
            .object(["steps": .array([step("a", "pending", "标题")]), "total": .int(99)]),
            .object(["steps": .array([step("a", "pending", "标题"), step("a", "completed", "标题")])]),
            .object(["steps": .array([step("a", "inProgress", "标题"), step("b", "inProgress", "标题")])]),
            .object(["steps": .array([step(" ", "pending", "标题")])]),
            .object(["steps": .array([step("a", "pending", " \n")])]),
            .object(["steps": .array([step("a", "done", "标题")])]),
            .object(["steps": .array([step("a", "pending", String(repeating: "中", count: 171))])]),
            .object(["steps": .array([step(String(repeating: "x", count: 129), "pending", "标题")])]),
            .object(["steps": .array([step("a\u{0}", "pending", "标题")])]),
            .object(["steps": .array([.object(["id": .int(1), "title": .string("标题"), "status": .string("pending")])])]),
            .object(["steps": .array((0...100).map { step("\($0)", "pending", "标题") })])
        ]
        for arguments in invalid {
            do {
                _ = try await UpdatePlanTool().execute(id: "bad", arguments: arguments,
                    context: ToolContext(workingDirectory: URL(fileURLWithPath: "/unused")), onUpdate: nil)
                Issue.record("无效计划不应被接受")
            } catch { #expect(error is AgentError) }
        }
    }

    @Test("有界计划最大值可接受，X/Y 从完成状态推导")
    func planLimit() async throws {
        let arguments: JSONValue = .object(["steps": .array((0..<100).map {
            StructuredReportFixtures.step("\($0)", "completed", title: String(repeating: "a", count: 512))
        })])
        let result = try await UpdatePlanTool().execute(id: "limit", arguments: arguments,
            context: ToolContext(workingDirectory: URL(fileURLWithPath: "/unused")), onUpdate: nil)
        #expect(result.progressReport?.completedCount == 100)
        #expect(result.progressReport?.totalCount == 100)
        #expect(result.testReport == nil)
    }

    @Test("JUnit 统计实际 testcase，嵌套 suite 不重复，error 计入 failed")
    func junit() async throws {
        let root = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root) }
        try StructuredReportFixtures.xml.write(to: root.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        let result = try await ReadTestReportTool().execute(id: "r", arguments: .object(["path": .string("report.xml")]),
            context: ToolContext(workingDirectory: root), onUpdate: nil)
        #expect(result.testReport == TestReport(path: "report.xml", passed: 1, failed: 2, skipped: 1))
        #expect(result.testReport?.total == 4 && result.testReport?.source == .junit)
        #expect(!result.isError) // 读取成功与测试通过分离。
        #expect(result.progressReport == nil)
    }

    @Test("空 suite/纯跳过/失败/错误结果不冒充通过")
    func outcomes() throws {
        for (xml, passed, failed, skipped) in [
            ("<testsuites/>", 0, 0, 0), ("<testsuite tests='90'/>", 0, 0, 0),
            ("<testsuite><testcase/></testsuite>", 1, 0, 0),
            ("<testsuite><testcase><skipped/></testcase></testsuite>", 0, 0, 1),
            ("<testsuite><testcase status='notrun' result='suppressed'/></testsuite>", 0, 0, 1),
            ("<testsuite><testcase status='run' result='skipped'/></testsuite>", 0, 0, 1),
            ("<testsuite><testcase><failure/></testcase></testsuite>", 0, 1, 0),
            ("<testsuite><testcase><error/></testcase></testsuite>", 0, 1, 0)
        ] {
            let report = try ReadTestReportTool.parse(Data(xml.utf8), path: "report.xml")
            #expect(report == TestReport(path: "report.xml", passed: passed, failed: failed, skipped: skipped))
        }
    }

    @Test("拒绝畸形 XML、实体、外部 DTD、编码绕过、不支持结构及资源超限")
    func rejectedXML() {
        let invalid = [
            "", "  ", "<html/>", "<testsuite>", "<testsuite/><testsuite/>",
            "<testsuites><testcase/></testsuites>", "<testsuite><error/></testsuite>",
            "<testsuite xmlns='urn:unsupported'><testcase/></testsuite>",
            "<testsuite xmlns:x='urn:unsupported'><testcase><x:failure/></testcase></testsuite>",
            "<testsuite><testcase><testcase/></testcase></testsuite>",
            "<testsuite><testcase>&unknown;</testcase></testsuite>",
            "<!DOCTYPE testsuite SYSTEM 'file:///never-read'><testsuite/>",
            "<!DOCTYPE testsuite SYSTEM 'https://invalid.example/never-fetch'><testsuite/>",
            "<!DOCTYPE testsuite [<!ENTITY x 'expanded'>]><testsuite><testcase>&x;</testcase></testsuite>",
            "<!DOCTYPE testsuite [<!ENTITY % x SYSTEM 'file:///never-read'>%x;]><testsuite/>",
            String(repeating: "<testsuite>", count: 65) + String(repeating: "</testsuite>", count: 65),
            "<testsuite>" + String(repeating: "<testcase/>", count: 10_001) + "</testsuite>",
            String(repeating: "x", count: ReadTestReportTool.maxBytes + 1)
        ].map { Data($0.utf8) } + [Data([0xff, 0xfe]), "<testsuite/>".data(using: .utf16)!]
        for data in invalid {
            #expect(throws: AgentError.self) { try ReadTestReportTool.parse(data, path: "report.xml") }
        }
    }

    @Test("读取边界拒绝穿越、文件及父目录链接（包括根内链接）、非普通文件和超限文件")
    func paths() async throws {
        let root = try StructuredReportFixtures.project()
        let outside = try StructuredReportFixtures.project()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let fm = FileManager.default
        try "<testsuite/>".write(to: root.appendingPathComponent("valid.xml"), atomically: true, encoding: .utf8)
        try "<testsuite/>".write(to: outside.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("inside-link.xml"), withDestinationURL: root.appendingPathComponent("valid.xml"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("outside-link.xml"), withDestinationURL: outside.appendingPathComponent("report.xml"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("dir-link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("inside-dir"), withDestinationURL: root)
        try fm.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data(repeating: 65, count: ReadTestReportTool.maxBytes + 1).write(to: root.appendingPathComponent("big.xml"))
        #expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
        for path in ["../report.xml", outside.appendingPathComponent("report.xml").path, "inside-link.xml",
                     "outside-link.xml", "dir-link/report.xml", "inside-dir/valid.xml", "dir", "fifo", "big.xml",
                     "missing.xml", "./valid.xml", "dir/../valid.xml", "dir//report.xml", "valid.xml\u{0}suffix"] {
            do {
                _ = try await ReadTestReportTool().execute(id: "r", arguments: .object(["path": .string(path)]),
                    context: ToolContext(workingDirectory: root), onUpdate: nil)
                Issue.record("不应接受路径：\(path)")
            } catch { #expect(error is AgentError) }
        }
        let prefix = "<testsuite><!--"
        let suffix = "--></testsuite>"
        let boundary = prefix + String(repeating: "x", count: ReadTestReportTool.maxBytes - prefix.utf8.count - suffix.utf8.count) + suffix
        try boundary.write(to: root.appendingPathComponent("dir/boundary.xml"), atomically: true, encoding: .utf8)
        let result = try await ReadTestReportTool().execute(id: "ok", arguments: .object(["path": .string("dir/boundary.xml")]),
            context: ToolContext(workingDirectory: root), onUpdate: nil)
        #expect(result.testReport?.total == 0)
    }
}