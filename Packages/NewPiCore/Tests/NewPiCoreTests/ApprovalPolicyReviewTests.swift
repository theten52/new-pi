import Foundation
import Testing
import CryptoKit
@testable import NewPiCore

/// Review 补充测试：覆盖设计文档《approval-permissions-design.md》要求、
/// 但现有 `ApprovalPermissionTests.swift` 未覆盖的边界行为。
struct ReviewSafetyBoundariesTests {

    // MARK: - 危险评估边界

    @Test func editAndWriteContentsDoNotCauseBashRiskFalsePositive() async {
        let evaluator = DangerEvaluator()
        // 正文里出现的 rm -rf / sudo 不应误报为高风险（只对目标 path 判规则）
        let edit = await evaluator.evaluate(
            toolName: "edit",
            arguments: .object([
                "path": .string("a.swift"),
                "new_string": .string("cleanup: // rm -rf /tmp/build\nsudo install\n"),
            ]),
            cache: nil
        )
        #expect(edit.level != .high)   // 仅 edit 基线 medium

        let write = await evaluator.evaluate(
            toolName: "write",
            arguments: .object([
                "path": .string("script.sh"),
                "content": .string("#!/bin/bash\nsudo install_xpk\nrm -rf .\n"),
            ]),
            cache: nil
        )
        #expect(write.level != .high)  // 仅 write 基线 medium
    }

    @Test func writeToSystemSensitivePathIsHigh() async {
        let evaluator = DangerEvaluator()
        // 写入系统敏感路径 → 直接判为高风险（确定性）
        let assessment = await evaluator.evaluate(
            toolName: "write",
            arguments: .object(["path": .string("/etc/passwd"), "content": .string("x")]),
            cache: nil
        )
        #expect(assessment.level == .high)
    }

    @Test func mcpToolBaselineIsMedium() async {
        let evaluator = DangerEvaluator()
        let assessment = await evaluator.evaluate(
            toolName: "mcp/filesystem/read",
            arguments: .object(["path": .string("/tmp")]),
            cache: nil
        )
        // 未命中高危规则时，MCP 工具基线应为 medium
        #expect(assessment.level == .medium)
    }

    @Test func llmSupplementUpgradesDangerToHigh() async {
        let evaluator = DangerEvaluator(
            llmSupplementEnabled: true,
            llmAssessor: { _, _ in DangerAssessment(level: .high, reason: "语义确认：删库") }
        )
        // read 基线为 low，LLM 补充判为 high → 取较高者
        let assessment = await evaluator.evaluate(
            toolName: "read",
            arguments: .object(["path": .string("secrets.json")]),
            cache: nil
        )
        #expect(assessment.level == .high)
    }

    @Test func llmSupplementFallsBackToBaselineWhenAssessorNil() async {
        let evaluator = DangerEvaluator(
            llmSupplementEnabled: true,
            llmAssessor: { _, _ in nil }   // LLM 评估失败
        )
        // write 基线 medium，失败降级为 medium，绝不降为 low
        let assessment = await evaluator.evaluate(
            toolName: "write",
            arguments: .object(["path": .string("r.txt"), "content": .string("x")]),
            cache: nil
        )
        #expect(assessment.level == .medium)
    }

    // MARK: - 授权追踪 / 持久化边界

    @Test func onceScopeIsNotRecorded() async {
        let tracker = ToolApprovalTracker(persistentStore: PersistentApprovalStore())
        await tracker.record(scope: .once, toolName: "bash", fingerprint: "abc", dangerLevel: .medium)
        let authorized = await tracker.isAuthorized(
            toolName: "bash", fingerprint: "abc", dangerLevel: .medium
        )
        // once 只放行本次，不写入 session/forever → 再次调用仍需审批
        #expect(!authorized)
    }

    @Test func highRiskRejectedEvenWhenForeverRecordExists() async {
        let store = PersistentApprovalStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
        )
        let record = ApprovalRecord(toolName: "bash", parametersFingerprint: "abc", scope: .forever)
        store.saveForever(record)

        let tracker = ToolApprovalTracker(persistentStore: store)
        // 即便已有匹配的 forever 记录，high 仍必须重新提示（安全兜底）
        let authorized = await tracker.isAuthorized(
            toolName: "bash", fingerprint: "abc", dangerLevel: .high
        )
        #expect(!authorized)
    }

    @Test func persistentStoreDedupesSameFingerprint() {
        let store = PersistentApprovalStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
        )
        store.saveForever(ApprovalRecord(toolName: "bash", parametersFingerprint: "abc", scope: .forever))
        store.saveForever(ApprovalRecord(toolName: "bash", parametersFingerprint: "abc", scope: .forever))
        #expect(store.foreverRecords().count == 1)
    }

    @Test func persistentStoreRemovesForever() {
        let store = PersistentApprovalStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
        )
        store.saveForever(ApprovalRecord(toolName: "bash", parametersFingerprint: "abc", scope: .forever))
        store.saveForever(ApprovalRecord(toolName: "write", parametersFingerprint: "def", scope: .forever))
        store.removeForever(toolName: "bash", fingerprint: "abc")
        #expect(store.foreverRecords().count == 1)
        #expect(store.foreverRecords().first?.toolName == "write")
    }

    // MARK: - 指纹稳定性

    @Test func fingerprintStableForNestedStructures() {
        let a = ToolApprovalFingerprint.make(arguments: .object([
            "a": .int(1),
            "b": .array([
                .object(["x": .int(1), "y": .int(2)]),
                .string("z"),
            ]),
        ]))
        let b = ToolApprovalFingerprint.make(arguments: .object([
            "b": .array([
                .object(["y": .int(2), "x": .int(1)]),
                .string("z"),
            ]),
            "a": .int(1),
        ]))
        // 嵌套字典键排序 + 数组顺序不变 → 指纹一致
        #expect(a == b)
    }

    // MARK: - 匹配语义

    @Test func approvalRecordWholeClassMatches() {
        let wholeClass = ApprovalRecord(toolName: "bash", parametersFingerprint: nil, scope: .forever)
        #expect(wholeClass.matches(toolName: "bash", fingerprint: "anything"))
        #expect(!wholeClass.matches(toolName: "read", fingerprint: "anything"))
    }
}
