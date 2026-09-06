import Foundation
import Testing
@testable import NewPiCore

@Suite("LLMMetrics")
struct LLMMetricsTests {
    private func sample(_ n: Int, provider: String = "P") -> LLMRequestMetric {
        LLMRequestMetric(providerName: provider, preset: "openaiCompatible", vendor: "deepseek", model: "m\(n)", mode: "chat")
    }

    @Test("内存环保留最近并最新在前")
    func ringOrder() async {
        let rec = LLMMetricsRecorder(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for i in 0..<5 {
            await rec.record(sample(i))
        }
        let recent = await rec.recentRequests()
        #expect(recent.count == 5)
        // 最新在前：第 4 条应是最后写入的 m4。
        #expect(recent.first?.model == "m4")
        #expect(recent.last?.model == "m0")
    }

    @Test("环形上限 500")
    func ringLimit() async {
        let rec = LLMMetricsRecorder(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for i in 0..<520 {
            await rec.record(sample(i))
        }
        let recent = await rec.recentRequests(limit: 5000)
        #expect(recent.count == 500)
    }

    @Test("落盘后可跨实例重载恢复最近")
    func persistAndReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-test-\(UUID().uuidString)")
        let rec1 = LLMMetricsRecorder(directory: dir)
        for i in 0..<8 {
            await rec1.record(sample(i))
        }
        // 新实例（模拟重启）从磁盘恢复。
        let rec2 = LLMMetricsRecorder(directory: dir)
        await rec2.loadRecentFromDisk()
        let restored = await rec2.recentRequests()
        #expect(restored.count == 8)
        #expect(restored.first?.model == "m7")
        #expect(Set(restored.map(\.model)).count == 8)
    }

    @Test("成本估算：按每 1M token 单价")
    func costEstimate() {
        let pricing = ModelPricing(input: 1, output: 3, currency: .usd)
        let cost = LLMRequestMetric.estimatedCost(
            inputTokens: 1_000_000, cachedTokens: 0, cacheCreation: 0, outputTokens: 1_000_000,
            pricing: pricing
        )
        #expect(cost?.amount == 4.0)
        #expect(cost?.currency == "USD")
    }

    @Test("无 pricing 时成本为 nil")
    func costNilWithoutPricing() {
        let cost = LLMRequestMetric.estimatedCost(
            inputTokens: 100, cachedTokens: 0, cacheCreation: 0, outputTokens: 100,
            pricing: nil
        )
        #expect(cost == nil)
    }

    @Test("汇总 P50/P95 与错误率")
    func summaryAggregation() async {
        let rec = LLMMetricsRecorder(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        // 同 provider/model 的两条：一条正常、一条错误（429），应聚成一行。
        var ok = LLMRequestMetric(providerName: "P", preset: "openaiCompatible", vendor: "deepseek", model: "m", mode: "chat")
        ok.inputTokens = 100
        ok.outputTokens = 50
        var err = LLMRequestMetric(providerName: "P", preset: "openaiCompatible", vendor: "deepseek", model: "m", mode: "chat")
        err.errorType = "http_error"
        err.statusCode = 429
        await rec.record(ok)
        await rec.record(err)
        let recent = await rec.recentRequests()
        let summary = LLMMetricSummary(requests: recent)
        #expect(summary.rows.count == 1)
        #expect(summary.totalRequests == 2)
        #expect(summary.rows.first?.errorCount == 1)
        #expect(summary.rows.first?.errorRate == 0.5)
    }
}
