import Foundation

/// 模型声明的计划，不是执行证明；计数始终由步骤推导。
public struct ProgressReport: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case agentReport }
    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case pending, inProgress, completed }
        public let id: String
        public let title: String
        public let status: Status

        public init(id: String, title: String, status: Status) {
            self.id = id
            self.title = title
            self.status = status
        }
    }

    public let steps: [Step]
    public let source: Source
    public var completedCount: Int { steps.filter { $0.status == .completed }.count }
    public var totalCount: Int { steps.count }

    public init(steps: [Step]) {
        self.steps = steps
        self.source = .agentReport
    }
}

/// 仅报告读取到的 JUnit testcase 结果，不证明报告新鲜度或对应当前代码。
/// error 与 failure 都计入 failed；同一 testcase 只计一次。
public struct TestReport: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case junit = "JUnit" }
    public let path: String
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let total: Int
    public let source: Source

    public init(path: String, passed: Int, failed: Int, skipped: Int) {
        self.path = path
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.total = passed + failed + skipped
        self.source = .junit
    }
}

public struct UpdatePlanTool: AgentTool {
    public static let maxSteps = 100
    public let name = "update_plan"
    public let definition = ToolDefinition(
        name: "update_plan",
        description: "Report the complete current plan with stable step IDs. Agent report only, not verified execution or test success. No external side effects. At most one inProgress step.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"), "minItems": .int(1), "maxItems": .int(100),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(128)]),
                            "title": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(512)]),
                            "status": .object(["type": .string("string"), "enum": .array([.string("pending"), .string("inProgress"), .string("completed")])])
                        ]),
                        "required": .array([.string("id"), .string("title"), .string("status")]),
                        "additionalProperties": .bool(false)
                    ])
                ])
            ]),
            "required": .array([.string("steps")]), "additionalProperties": .bool(false)
        ])
    )

    public init() {}

    public func execute(id: String, arguments: JSONValue, context: ToolContext,
                        onUpdate: (@Sendable (ToolProgress) -> Void)?) async throws -> ToolResult {
        try Task.checkCancellation()
        guard let object = arguments.objectValue, Set(object.keys) == ["steps"],
              case let .array(values)? = object["steps"], !values.isEmpty, values.count <= Self.maxSteps else {
            throw AgentError.invalidState("steps 必须包含 1–100 个步骤，且不接受额外字段。")
        }
        var steps: [ProgressReport.Step] = []
        var ids = Set<String>()
        for value in values {
            guard let step = value.objectValue, Set(step.keys) == ["id", "title", "status"],
                  let id = step["id"]?.stringValue, let title = step["title"]?.stringValue,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  id.utf8.count <= 128, title.utf8.count <= 512,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let rawStatus = step["status"]?.stringValue,
                  let status = ProgressReport.Step.Status(rawValue: rawStatus), ids.insert(id).inserted else {
                throw AgentError.invalidState("计划步骤无效：需要唯一 id、非空 title 和 pending/inProgress/completed 状态（id ≤128、title ≤512 UTF-8 字节）。")
            }
            steps.append(.init(id: id, title: title, status: status))
        }
        guard steps.filter({ $0.status == .inProgress }).count <= 1 else {
            throw AgentError.invalidState("最多允许一个 inProgress 步骤。")
        }
        let report = ProgressReport(steps: steps)
        return ToolResult(content: "计划（agent report，未经执行验证）：\(report.completedCount)/\(report.totalCount)。不代表测试通过。",
                          progressReport: report)
    }
}