import NewPiCore
import SwiftUI

/// API 监控面板的数据模型（MainActor 桥接 actor recorder，轮询取最新数据）。
@MainActor
final class MetricsPanelModel: ObservableObject {
    @Published var requests: [LLMRequestMetric] = []
    @Published var flushStats: FlushStats?
    @Published var diffStats: FlushStats?
    @Published var domStats: FlushStats?
    @Published var metricsPath = ""

    struct FlushStats: Sendable {
        let count: Int
        let slowCount: Int
        let avgMs: Double
        let p95Ms: Double
        let maxMs: Double
    }

    init() {
        Task { await loadMetricsPath() }
    }

    private func loadMetricsPath() async {
        let file = await LLMMetricsRecorder.shared.todayFileDescription()
        metricsPath = file
    }

    /// 刷新一次（面板 .task 轮询循环调用；视图消失 Task 自动取消，无 Timer 泄漏）。
    func refresh() async {
        let recorder = LLMMetricsRecorder.shared
        let reqs = await recorder.recentRequests(limit: 300)
        let flushes = await recorder.recentFlushes(limit: 1000)
        let diffs = await recorder.recentDiffs(limit: 1000)
        let doms = await recorder.recentDomApplies(limit: 1000)
        requests = reqs
        flushStats = Self.computeStats(flushes.map { $0.duration })
        diffStats = Self.computeStats(diffs.map { $0.duration })
        domStats = Self.computeStats(doms.map { $0.duration })
    }

    private static func computeStats(_ durations: [Double]) -> FlushStats? {
        guard !durations.isEmpty else { return nil }
        let durs = durations.map { $0 * 1000 }.sorted()
        let p95Index = max(0, Int((Double(durs.count - 1) * 0.95).rounded()))
        return FlushStats(
            count: durs.count,
            slowCount: durations.filter { $0 >= 0.05 }.count,
            avgMs: durs.reduce(0, +) / Double(durs.count),
            p95Ms: durs[p95Index],
            maxMs: durs.last ?? 0
        )
    }
}

/// API 监控面板：汇总对比（provider×model）+ 最近请求明细 + UI 渲染耗时。
struct NewPiMetricsView: View {
    @StateObject private var model = MetricsPanelModel()
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .summary

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "汇总对比"
        case requests = "最近请求"
        case ui = "UI 渲染"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 4)

            switch tab {
            case .summary: summaryView
            case .requests: requestList
            case .ui: uiFlushView
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        // 随视图生命周期轮询最新数据：面板关闭即取消（无 Timer 泄漏）。
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("API 监控").font(.headline)
            Spacer()
            Text(model.metricsPath.isEmpty ? "" : "\(model.metricsPath)（今天）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("刷新") {
                Task { await model.refresh() }
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - 汇总对比

    private var summaryView: some View {
        let summary = LLMMetricSummary(requests: model.requests)
        return VStack(alignment: .leading, spacing: 8) {
            Text("最近 \(model.requests.count) 次请求 · 总错误率 \(Self.pct(summary.totalErrorRate))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView {
                Table(summary.rows) {
                    TableColumn("Provider / Model") { Text($0.key).font(.caption) }
                    TableColumn("次数") { Text("\($0.count)") }
                    TableColumn("错误率") { Text(Self.pct($0.errorRate)).foregroundStyle($0.errorRate > 0.05 ? .red : .secondary) }
                    TableColumn("TTFT P50") { Text($0.p50TTFT.map { Self.ms($0) } ?? "—") }
                    TableColumn("TTFT P95") { Text($0.p95TTFT.map { Self.ms($0) } ?? "—") }
                    TableColumn("总耗时 P50") { Text($0.p50Total.map { Self.ms($0) } ?? "—") }
                    TableColumn("总耗时 P95") { Text($0.p95Total.map { Self.ms($0) } ?? "—") }
                    TableColumn("tok/s") { Text($0.avgTokensPerSec.map { String(format: "%.1f", $0) } ?? "—") }
                    TableColumn("in/out tok") {
                        Text("\(Self.k($0.totalInputTokens))/\(Self.k($0.totalOutputTokens))").font(.caption2)
                    }
                    TableColumn("成本") { row in
                        Text(row.totalCost.map { Self.money($0, row.costCurrency ?? "") } ?? "—")
                    }
                }
                .frame(minHeight: 200)
            }
            Text("TTFT = 首内容 token 延迟（网络+排队+prefill+思考准备）；tok/s 按端到端计。P95 反映最差情况。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
    }

    // MARK: - 最近请求明细

    private var requestList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.requests) { r in
                    RequestRow(metric: r)
                }
            }
            .padding()
        }
    }

    // MARK: - UI 渲染

    private var uiFlushView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let s = model.flushStats {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("flush（合并增量进 transcript）").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            StatLabel(title: "次数", value: "\(s.count)")
                            StatLabel(title: "≥50ms", value: "\(s.slowCount)")
                            StatLabel(title: "平均", value: Self.ms(s.avgMs))
                            StatLabel(title: "P95", value: Self.ms(s.p95Ms))
                            StatLabel(title: "最大", value: Self.ms(s.maxMs))
                        }
                    }
                }
                if let d = model.diffStats {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("diff（transcript → 遍历算 signature → ops）").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            StatLabel(title: "次数", value: "\(d.count)")
                            StatLabel(title: "≥50ms", value: "\(d.slowCount)")
                            StatLabel(title: "平均", value: Self.ms(d.avgMs))
                            StatLabel(title: "P95", value: Self.ms(d.p95Ms))
                            StatLabel(title: "最大", value: Self.ms(d.maxMs))
                        }
                    }
                }
                if let dm = model.domStats {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("JS applyOps（DOM 应用 + 批量提交，JS 回传）").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            StatLabel(title: "次数", value: "\(dm.count)")
                            StatLabel(title: "≥50ms", value: "\(dm.slowCount)")
                            StatLabel(title: "平均", value: Self.ms(dm.avgMs))
                            StatLabel(title: "P95", value: Self.ms(dm.p95Ms))
                            StatLabel(title: "最大", value: Self.ms(dm.maxMs))
                        }
                    }
                }
                if model.flushStats == nil && model.diffStats == nil && model.domStats == nil {
                    Text("暂无 UI 数据——发起一次流式对话后这里会出现。").foregroundStyle(.secondary)
                } else {
                    Text("flush = 增量合并进 transcript；diff = 遍历全部条目算签名、生成 ops（每次 flush 都触发，transcript 越大越贵）；JS applyOps = DOM 应用 + 批量提交（原生侧测不到，由 JS 回传）。三段任一 P95 高即对应卡点。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
        }
    }

    // MARK: - 格式化

    static func ms(_ v: Double) -> String {
        v >= 1 ? String(format: "%.1fs", v) : String(format: "%.0fms", v * 1000)
    }

    static func pct(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    static func k(_ v: Int) -> String {
        v >= 1000 ? String(format: "%.1fk", Double(v) / 1000) : "\(v)"
    }

    static func money(_ v: Double, _ currency: String) -> String {
        let symbol = currency == "CNY" ? "¥" : "$"
        return v >= 0.01 ? String(format: "%@%.2f", symbol, v) : String(format: "%@%.4f", symbol, v)
    }
}

struct RequestRow: View {
    let metric: LLMRequestMetric

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(metric.providerName) · \(metric.model)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(metric.startedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                    if let tl = metric.thinkingLevel { Text("思考:\(tl)").font(.caption2).foregroundStyle(.purple) }
                    if metric.hasTools { Text("工具").font(.caption2) }
                    if metric.vendor != "unknown" { Text(metric.vendor).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Group {
                Text("TTFT \(metric.timeToFirstToken.map { NewPiMetricsView.ms($0) } ?? "—")")
                if let td = metric.thinkingDuration { Text("想 \(NewPiMetricsView.ms(td))").foregroundStyle(.purple) }
                Text("总 \(metric.totalDuration.map { NewPiMetricsView.ms($0) } ?? "…")")
                if let tail = metric.textTailDuration {
                    Text("尾 \(NewPiMetricsView.ms(tail))")
                        .help(tailTimingHelp)
                }
                Text(metric.outputTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "")
                    .help("输出 token / 首正文到流结束的时间（含协议尾段），不是独立测量的正文生成速率")
                Text(metric.outputTokens.map { "out \(NewPiMetricsView.k($0))" } ?? "")
                if let td = metric.textDeltaCount {
                    // delta 事件数（正文 + 思考）：粒度假设验证——同 token 数下 Δ 越大事件越细。
                    Text("Δ \(td)\(metric.thinkingDeltaCount.map { "+\($0)" } ?? "")")
                }
            }
            .font(.caption2)
            .monospacedDigit()

            statusBadge
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(metric.isError ? Color.red.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let et = metric.errorType {
            Text(et).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red.opacity(0.2)).clipShape(Capsule())
        } else if let sc = metric.statusCode, !(200...299).contains(sc) {
            Text("HTTP \(sc)").font(.caption2).background(.red.opacity(0.2)).clipShape(Capsule())
        } else {
            Text("✓").foregroundStyle(.green).font(.caption)
        }

    }

    private var tailTimingHelp: String {
        var parts = ["末次正文到 provider 流结束；可能包含后续工具或协议事件，不是 UI 绘制耗时。"]
        if let duration = metric.textEmissionDuration {
            parts.append("正文接收跨度：\(NewPiMetricsView.ms(duration))")
        }
        if let duration = metric.textToTerminalDuration {
            parts.append("末次正文 → Responses 终态：\(NewPiMetricsView.ms(duration))")
        }
        if let duration = metric.terminalDrainDuration {
            parts.append("终态 → provider 标记结束：\(NewPiMetricsView.ms(duration))")
        }
        return parts.joined(separator: "\n")
    }
}

struct StatLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
