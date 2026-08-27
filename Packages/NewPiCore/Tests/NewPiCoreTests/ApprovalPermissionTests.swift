import Foundation
import Testing
@testable import NewPiCore

struct DangerEvaluatorTests {
    let evaluator = DangerEvaluator()

    @Test func bashHighRiskDetected() async {
        let assessment = await evaluator.evaluate(
            toolName: "bash",
            arguments: .object(["command": .string("rm -rf ~/project")]),
            cache: nil
        )
        #expect(assessment.level == .high)
        #expect(assessment.matchedRules.count > 0)
    }

    @Test func bashSudoHighRisk() async {
        let assessment = await evaluator.evaluate(
            toolName: "bash",
            arguments: .object(["command": .string("sudo apt-get update")]),
            cache: nil
        )
        #expect(assessment.level == .high)
    }

    @Test func bashNormalCommandMedium() async {
        let assessment = await evaluator.evaluate(
            toolName: "bash",
            arguments: .object(["command": .string("ls -la")]),
            cache: nil
        )
        #expect(assessment.level == .medium)
    }

    @Test func readLowRisk() async {
        let assessment = await evaluator.evaluate(
            toolName: "read",
            arguments: .object(["path": .string("README.md")]),
            cache: nil
        )
        #expect(assessment.level == .low)
    }

    @Test func cacheReusesResult() async {
        let cache = DangerAssessmentCache()
        let args = JSONValue.object(["command": .string("cat Package.swift")])
        let first = await evaluator.evaluate(toolName: "bash", arguments: args, cache: cache)
        let second = await evaluator.evaluate(toolName: "bash", arguments: args, cache: cache)
        #expect(first == second)
    }
}

struct ToolApprovalFingerprintTests {
    @Test func fingerprintStableForSameArgs() {
        let a = ToolApprovalFingerprint.make(arguments: .object(["command": .string("ls"), "path": .string(".")]))
        let b = ToolApprovalFingerprint.make(arguments: .object(["path": .string("."), "command": .string("ls")]))
        #expect(a == b)
    }

    @Test func fingerprintDiffersForDifferentArgs() {
        let a = ToolApprovalFingerprint.make(arguments: .object(["command": .string("ls")]))
        let b = ToolApprovalFingerprint.make(arguments: .object(["command": .string("rm -rf /")]))
        #expect(a != b)
    }
}

struct ToolApprovalTrackerTests {
    @Test func highRiskNeverAuthorized() async {
        let tracker = ToolApprovalTracker(persistentStore: PersistentApprovalStore())
        let authorized = await tracker.isAuthorized(
            toolName: "bash",
            fingerprint: "abc",
            dangerLevel: .high
        )
        #expect(!authorized)
    }

    @Test func sessionApprovalWorks() async {
        let tracker = ToolApprovalTracker(persistentStore: PersistentApprovalStore())
        await tracker.record(scope: .session, toolName: "bash", fingerprint: "abc", dangerLevel: .medium)
        let authorized = await tracker.isAuthorized(
            toolName: "bash",
            fingerprint: "abc",
            dangerLevel: .medium
        )
        #expect(authorized)
    }

    @Test func sessionApprovalDoesNotMatchDifferentFingerprint() async {
        let tracker = ToolApprovalTracker(persistentStore: PersistentApprovalStore())
        await tracker.record(scope: .session, toolName: "bash", fingerprint: "abc", dangerLevel: .medium)
        let authorized = await tracker.isAuthorized(
            toolName: "bash",
            fingerprint: "def",
            dangerLevel: .medium
        )
        #expect(!authorized)
    }

    @Test func foreverApprovalPersistsInStore() async {
        let store = PersistentApprovalStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
        )
        let tracker = ToolApprovalTracker(persistentStore: store)
        await tracker.record(scope: .forever, toolName: "bash", fingerprint: "abc", dangerLevel: .medium)

        let tracker2 = ToolApprovalTracker(persistentStore: store)
        let authorized = await tracker2.isAuthorized(
            toolName: "bash",
            fingerprint: "abc",
            dangerLevel: .medium
        )
        #expect(authorized)
    }

    @Test func highRiskNotStored() async {
        let store = PersistentApprovalStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-approvals-\(UUID().uuidString).json")
        )
        let tracker = ToolApprovalTracker(persistentStore: store)
        await tracker.record(scope: .forever, toolName: "bash", fingerprint: "abc", dangerLevel: .high)

        #expect(store.foreverRecords().isEmpty)
    }
}
