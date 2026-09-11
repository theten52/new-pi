import Foundation

// MARK: - 指标模型
//
// 字段用短名（JSON key 同 Swift 名），与 OpenTelemetry GenAI 语义约定的对应关系
// 见 docs/api-metrics-design.md。原始时间戳保留（派生指标可复算），便于调试还原时间线。

/// 一次 LLM API 调用的性能指标（一条 = 一次 LLM 请求）。
public struct LLMRequestMetric: Codable, Sendable, Identifiable {
    public var id: UUID
    /// 请求发出时刻。
    public var startedAt: Date
    // —— 身份 ——
    public var providerName: String      // profile 显示名（如 "GLM 智谱 (Token Plan)"）
    public var preset: String            // preset rawValue（openaiCompatible / anthropic / ...）
    public var vendor: String            // 厂商嗅探：glm / mimo / deepseek / anthropic / openai / unknown
    public var model: String             // 模型 ID
    public var mode: String              // chat / responses / anthropic
    public var thinkingLevel: String?    // 配置的思考档位
    public var hasTools: Bool
    // —— 时间戳点（Date?，nil=未到达该阶段）——
    /// 收到 HTTP 响应头 / 流首字节（服务端开始响应）。
    public var responseAt: Date?
    /// 首个 thinking delta。
    public var firstThinkingAt: Date?
    /// 最后一个 thinking delta。
    public var lastThinkingAt: Date?
    /// 首个正文（text）delta。
    public var firstTextAt: Date?
    /// 最后一个正文 delta；旧记录缺失时不推算。
    public var lastTextAt: Date?
    /// Responses 最后一个 output_text.done，不代表整次请求完成。
    public var textDoneAt: Date?
    /// Responses completed/incomplete/failed 被解码的时刻。
    public var terminalAt: Date?
    /// 流结束（正常完成 / 错误抛出）。
    public var endedAt: Date?
    // —— token 用量 ——
    public var inputTokens: Int?
    public var cachedInputTokens: Int?   // prompt cache 命中
    public var cacheCreationTokens: Int? // prompt cache 写入
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var contextWindow: Int?
    // —— delta 粒度（验证「glm 比 deepseek 卡 = 事件更细」假设：事件数 × 每 flush 固定成本）——
    public var textDeltaCount: Int?      // 正文 delta 事件数（outputTokens / 此值 ≈ 每事件 token 数）
    public var thinkingDeltaCount: Int?  // 思考 delta 事件数
    // —— 结果 ——
    public var statusCode: Int?          // HTTP 状态
    public var errorType: String?        // http_error / timeout / network / llm_error / cancelled / stream_error
    public var errorMessage: String?     // 截断到 500 字符
    // —— 成本（按 ModelDefinition.pricing 估算，缺失为 nil）——
    public var costAmount: Double?
    public var costCurrency: String?     // USD / CNY

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        providerName: String,
        preset: String,
        vendor: String,
        model: String,
        mode: String,
        thinkingLevel: String? = nil,
        hasTools: Bool = false,
        responseAt: Date? = nil,
        firstThinkingAt: Date? = nil,
        lastThinkingAt: Date? = nil,
        firstTextAt: Date? = nil,
        lastTextAt: Date? = nil,
        textDoneAt: Date? = nil,
        terminalAt: Date? = nil,
        endedAt: Date? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        contextWindow: Int? = nil,
        textDeltaCount: Int? = nil,
        thinkingDeltaCount: Int? = nil,
        statusCode: Int? = nil,
        errorType: String? = nil,
        errorMessage: String? = nil,
        costAmount: Double? = nil,
        costCurrency: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.providerName = providerName
        self.preset = preset
        self.vendor = vendor
        self.model = model
        self.mode = mode
        self.thinkingLevel = thinkingLevel
        self.hasTools = hasTools
        self.responseAt = responseAt
        self.firstThinkingAt = firstThinkingAt
        self.lastThinkingAt = lastThinkingAt
        self.firstTextAt = firstTextAt
        self.lastTextAt = lastTextAt
        self.textDoneAt = textDoneAt
        self.terminalAt = terminalAt
        self.endedAt = endedAt
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.contextWindow = contextWindow
        self.textDeltaCount = textDeltaCount
        self.thinkingDeltaCount = thinkingDeltaCount
        self.statusCode = statusCode
        self.errorType = errorType
        self.errorMessage = errorMessage
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }

    // MARK: 派生指标（由时间戳/token 复算，不落盘）

    /// 首内容 token（thinking 或正文首个）延迟 = TTFT（业界 time_to_first_token）。
    public var timeToFirstToken: TimeInterval? {
        firstAnchor?.timeIntervalSince(startedAt)
    }

    /// 首个到达的 delta（thinking 或 text 先到者）。
    private var firstAnchor: Date? {
        [firstThinkingAt, firstTextAt].compactMap { $0 }.min()
    }

    /// 思考段时长（最后 thinking delta - 首 thinking delta）。
    public var thinkingDuration: TimeInterval? {
        guard let a = firstThinkingAt, let b = lastThinkingAt else { return nil }
        return b.timeIntervalSince(a)
    }

    /// 首正文到流结束的时长，保留既有速率口径（含协议尾段，不是纯正文生成时间）。
    public var textDuration: TimeInterval? {
        guard let a = firstTextAt, let b = endedAt else { return nil }
        return max(b.timeIntervalSince(a), 0)
    }

    /// 正文接收跨度；单个 delta 为 0，不能拿它当单 token 的生成耗时。
    public var textEmissionDuration: TimeInterval? {
        guard let firstTextAt, let lastTextAt else { return nil }
        return max(0, lastTextAt.timeIntervalSince(firstTextAt))
    }

    /// 正文停止到 provider 流结束；可能含后续工具/协议事件，不等同于服务端纯等待。
    public var textTailDuration: TimeInterval? {
        guard let lastTextAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(lastTextAt))
    }

    public var textToTerminalDuration: TimeInterval? {
        guard let lastTextAt, let terminalAt else { return nil }
        return max(0, terminalAt.timeIntervalSince(lastTextAt))
    }

    /// 终态解码到 provider 标记结束，不包含后续指标落盘和 UI 处理。
    public var terminalDrainDuration: TimeInterval? {
        guard let terminalAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(terminalAt))
    }

    /// 端到端总耗时（请求发出 → 结束）。
    public var totalDuration: TimeInterval? {
        endedAt?.timeIntervalSince(startedAt)
    }

    /// 既有输出速率（token/s），分母含正文之后的协议尾段。
    public var outputTokensPerSecond: Double? {
        guard let out = outputTokens, let d = textDuration, d > 0 else { return nil }
        return Double(out) / d
    }

    /// 端到端输出速率（含思考段）。
    public var endToEndTokensPerSecond: Double? {
        guard let out = outputTokens, let d = totalDuration, d > 0 else { return nil }
        return Double(out) / d
    }

    /// 思考 token 占比（reasoning / 总输出）。
    public var reasoningShare: Double? {
        guard let r = reasoningTokens, let out = outputTokens, out > 0 else { return nil }
        return Double(r) / Double(out)
    }

    /// prompt cache 命中率。
    public var cacheHitRate: Double? {
        let cached = cachedInputTokens ?? 0
        let total = (inputTokens ?? 0) + cached
        guard total > 0 else { return nil }
        return Double(cached) / Double(total)
    }

    public var isError: Bool {
        errorType != nil || (statusCode.map { !(200 ... 299).contains($0) } ?? false)
    }
}
/// 用于区分「模型慢」还是「UI 渲染堆积慢」。
/// UI 渲染侧指标：一次流式 flush（把缓冲 delta 合并进 transcript）的耗时。
/// 用于区分「模型慢」还是「UI 渲染堆积慢」。
public struct UIFlushMetric: Codable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    /// 本次 flush 实际耗时（秒）。
    public var duration: Double
    /// 本次 flush 合并的字符数。
    public var deltaLength: Int

    public init(id: UUID = UUID(), at: Date = Date(), duration: Double, deltaLength: Int) {
        self.id = id
        self.at = at
        self.duration = duration
        self.deltaLength = deltaLength
    }
}

/// UI 渲染侧指标：单文档 transcript 的一次 diff（transcript 变化 → 遍历算 signature → 生成 ops）。
/// 这一步每次 flush 都会触发；transcript 越大越贵，是「出字卡」的主要嫌疑之一。
public struct UITranscriptDiffMetric: Codable, Sendable, Identifiable {
    /// 落盘区分标记（与 UIDomApplyMetric 字段相同，靠 kind 区分）。
    public var kind: String
    public var id: UUID
    public var at: Date
    /// diff 计算耗时（秒）。
    public var duration: Double
    /// 生成的 ops 条数（0 = 内容无变化，但全量 signature 遍历仍发生了）。
    public var opsCount: Int

    public init(kind: String = "diff", id: UUID = UUID(), at: Date = Date(), duration: Double, opsCount: Int) {
        self.kind = kind
        self.id = id
        self.at = at
        self.duration = duration
        self.opsCount = opsCount
    }
}

/// UI 渲染侧指标：JS 侧 applyOps 应用（DOM 变更 + 批量提交）耗时，由 markdown-renderer.js
/// 回传（原生侧测不到 DOM 渲染完成）。这是「模型快但 UI 卡」的最后一段。
public struct UIDomApplyMetric: Codable, Sendable, Identifiable {
    /// 落盘区分标记（与 UITranscriptDiffMetric 字段相同，靠 kind 区分）。
    public var kind: String
    public var id: UUID
    public var at: Date
    /// JS applyOps 耗时（秒）。
    public var duration: Double
    /// 本批 ops 条数。
    public var opsCount: Int

    public init(kind: String = "dom", id: UUID = UUID(), at: Date = Date(), duration: Double, opsCount: Int) {
        self.kind = kind
        self.id = id
        self.at = at
        self.duration = duration
        self.opsCount = opsCount
    }
}

// MARK: - 采集器

/// LLM / UI 指标采集器（进程级单例）：内存环形缓冲（最近 N 条，供 UI 实时看最新）
/// + 日滚动 JSONL 落盘（跨会话留存，供 Agent 分析）。内容不含 prompt，仅指标。
public actor LLMMetricsRecorder {
    public static let shared = LLMMetricsRecorder()

    /// 内存环形上限。
    private let ringLimit = 500
    private var requestRing: [LLMRequestMetric] = []
    private var flushRing: [UIFlushMetric] = []
    private var diffRing: [UITranscriptDiffMetric] = []
    private var domRing: [UIDomApplyMetric] = []
    private var subscribers: [() -> Void] = []

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        self.directory = directory ?? NewPiConfig.defaultAgentDirectory.appendingPathComponent("metrics", isDirectory: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: 落盘

    /// 今天的指标文件路径（供 UI 展示存储位置）。
    public func todayFileDescription() -> String {
        todayFile().path
    }

    private func todayFile() -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return directory.appendingPathComponent("metrics-\(df.string(from: Date())).jsonl")
    }

    private func appendToDisk<T: Encodable>(_ value: T) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = try encoder.encode(value)
            var data = line
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: todayFile().path) {
                let handle = try FileHandle(forWritingTo: todayFile())
                handle.seekToEndOfFile()
                handle.write(data)
                try handle.close()
            } else {
                try data.write(to: todayFile())
            }
        } catch {
            // 指标采集失败静默（不阻塞主流程）
        }
    }

    // MARK: 记录

    public func record(_ metric: LLMRequestMetric) {
        requestRing.append(metric)
        if requestRing.count > ringLimit {
            requestRing.removeFirst(requestRing.count - ringLimit)
        }
        appendToDisk(metric)
        notify()
    }

    /// UI flush：内存全记录；落盘只写较慢的（>=50ms），控制文件量。
    public func record(_ flush: UIFlushMetric) {
        flushRing.append(flush)
        if flushRing.count > ringLimit {
            flushRing.removeFirst(flushRing.count - ringLimit)
        }
        if flush.duration >= 0.05 {
            appendToDisk(flush)
        }
        notify()
    }

    /// transcript diff：内存全记录；落盘只写较慢的（>=50ms）。
    public func record(_ diff: UITranscriptDiffMetric) {
        diffRing.append(diff)
        if diffRing.count > ringLimit {
            diffRing.removeFirst(diffRing.count - ringLimit)
        }
        if diff.duration >= 0.05 {
            appendToDisk(diff)
        }
        notify()
    }

    /// JS applyOps（DOM 应用）：内存全记录；落盘只写较慢的（>=50ms）。
    public func record(_ dom: UIDomApplyMetric) {
        domRing.append(dom)
        if domRing.count > ringLimit {
            domRing.removeFirst(domRing.count - ringLimit)
        }
        if dom.duration >= 0.05 {
            appendToDisk(dom)
        }
        notify()
    }

    // MARK: 查询（UI 展示用：最新在前）

    public func recentRequests(limit: Int = 200) -> [LLMRequestMetric] {
        Array(requestRing.suffix(limit).reversed())
    }

    public func recentFlushes(limit: Int = 200) -> [UIFlushMetric] {
        Array(flushRing.suffix(limit).reversed())
    }

    public func recentDiffs(limit: Int = 200) -> [UITranscriptDiffMetric] {
        Array(diffRing.suffix(limit).reversed())
    }

    public func recentDomApplies(limit: Int = 200) -> [UIDomApplyMetric] {
        Array(domRing.suffix(limit).reversed())
    }

    /// 汇总给定请求集（供聚合卡片）。
    public func summary(_ requests: [LLMRequestMetric]) -> LLMMetricSummary {
        LLMMetricSummary(requests: requests)
    }

    // MARK: 变更订阅（UI 刷新）

    public func onChange(_ block: @escaping @Sendable () -> Void) {
        subscribers.append(block)
    }

    private func notify() {
        for sub in subscribers { sub() }
    }

    // MARK: 启动恢复（跨会话留存 → 重启后把最近记录装回内存）

    /// 从今天的 JSONL 尾部恢复最近 ringLimit 条（按行倒序读）。
    public func loadRecentFromDisk() {
        let file = todayFile()
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let lines = try tailLines(of: file, maxBytes: 2_000_000)
            var loadedRequests: [LLMRequestMetric] = []
            var loadedFlushes: [UIFlushMetric] = []
            var loadedDiffs: [UITranscriptDiffMetric] = []
            var loadedDoms: [UIDomApplyMetric] = []
            for line in lines {
                let data = Data(line)
                // 先按 kind 区分 diff/dom（二者其余字段相同）；再按特征分流 request/flush。
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let kind = dict["kind"] as? String
                    if kind == "dom", let d = try? decoder.decode(UIDomApplyMetric.self, from: data) {
                        loadedDoms.append(d); continue
                    }
                    if kind == "diff", let d = try? decoder.decode(UITranscriptDiffMetric.self, from: data) {
                        loadedDiffs.append(d); continue
                    }
                    if dict["providerName"] != nil, let r = try? decoder.decode(LLMRequestMetric.self, from: data) {
                        loadedRequests.append(r); continue
                    }
                    if dict["deltaLength"] != nil, let f = try? decoder.decode(UIFlushMetric.self, from: data) {
                        loadedFlushes.append(f); continue
                    }
                }
            }
            requestRing = Array(loadedRequests.suffix(ringLimit))
            flushRing = Array(loadedFlushes.suffix(ringLimit))
            diffRing = Array(loadedDiffs.suffix(ringLimit))
            domRing = Array(loadedDoms.suffix(ringLimit))
        } catch {
            // 忽略：恢复失败不影响功能
        }
    }

    private func tailLines(of url: URL, maxBytes: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }
}

/// 按 provider×model 聚合的汇总（人读的对比卡数据源）。
public struct LLMMetricSummary: Sendable {
    public struct Row: Sendable, Identifiable {
        public var key: String            // "provider / model"
        public var providerName: String
        public var model: String
        public var count: Int
        public var errorCount: Int
        public var p50TTFT: Double?
        public var p95TTFT: Double?
        public var p50Total: Double?
        public var p95Total: Double?
        public var avgTokensPerSec: Double?
        public var reasoningShare: Double?
        public var cacheHitRate: Double?
        public var totalInputTokens: Int
        public var totalOutputTokens: Int
        public var totalCost: Double?
        public var costCurrency: String?

        public var id: String { key }
        public var errorRate: Double { count == 0 ? 0 : Double(errorCount) / Double(count) }
    }

    public var rows: [Row]
    public var totalRequests: Int { rows.reduce(0) { $0 + $1.count } }
    public var totalErrorRate: Double {
        totalRequests == 0 ? 0 : Double(rows.reduce(0) { $0 + $1.errorCount }) / Double(totalRequests)
    }

    public init(requests: [LLMRequestMetric]) {
        var grouped: [String: [LLMRequestMetric]] = [:]
        for r in requests {
            let key = "\(r.providerName) / \(r.model)"
            grouped[key, default: []].append(r)
        }
        rows = grouped.map { key, list in
            Row(
                key: key,
                providerName: list.first?.providerName ?? "",
                model: list.first?.model ?? "",
                count: list.count,
                errorCount: list.filter { $0.isError }.count,
                p50TTFT: Self.percentile(list.compactMap { $0.timeToFirstToken }, 0.50),
                p95TTFT: Self.percentile(list.compactMap { $0.timeToFirstToken }, 0.95),
                p50Total: Self.percentile(list.compactMap { $0.totalDuration }, 0.50),
                p95Total: Self.percentile(list.compactMap { $0.totalDuration }, 0.95),
                avgTokensPerSec: Self.average(list.compactMap { $0.endToEndTokensPerSecond }),
                reasoningShare: Self.average(list.compactMap { $0.reasoningShare }),
                cacheHitRate: Self.average(list.compactMap { $0.cacheHitRate }),
                totalInputTokens: list.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.cachedInputTokens ?? 0) },
                totalOutputTokens: list.reduce(0) { $0 + ($1.outputTokens ?? 0) },
                totalCost: list.compactMap { $0.costAmount }.isEmpty ? nil : list.compactMap { $0.costAmount }.reduce(0, +),
                costCurrency: list.first?.costCurrency
            )
        }
        .sorted { $0.count > $1.count }
    }

    private static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[idx]
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// 厂商短名 → OTel 名称对照（完整表见 docs/api-metrics-design.md）。
public enum LLMMetricVendor {
    public static func name(for preset: String, baseURL: String?, model: String) -> String {
        let model = model.lowercased()
        let base = baseURL?.lowercased() ?? ""
        if preset == "anthropic" { return "anthropic" }
        if base.contains("bigmodel.cn") || base.contains("z.ai") { return "glm" }
        if base.contains("xiaomimimo.com") { return "mimo" }
        if base.contains("deepseek.com") { return "deepseek" }
        if base.contains("openai.com") || base.contains("openrouter.ai") { return model.contains("/") ? "openrouter" : "openai" }
        return "unknown"
    }
}

/// 请求内计时累加器（provider 流式循环内使用，单请求单线程，非跨线程共享）。
/// 只记「时间戳点」，派生指标（TTFT/思考时长等）由 LLMRequestMetric 复算。
public struct LLMRequestTiming {
    public var startedAt = Date()
    public var responseAt: Date?
    public var firstThinkingAt: Date?
    public var lastThinkingAt: Date?
    public var firstTextAt: Date?
    public var lastTextAt: Date?
    public var textDoneAt: Date?
    public var terminalAt: Date?
    public var endedAt: Date?
    /// delta 事件计数（粒度假设验证：事件数 × 每 flush 固定渲染成本 ≈ 排空时长）。
    public var textDeltaCount = 0
    public var thinkingDeltaCount = 0

    public init() {}

    /// HTTP 响应头到达（流首字节）。
    public mutating func markResponse() {
        if responseAt == nil { responseAt = Date() }
    }

    public mutating func markThinking() {
        let now = Date()
        if firstThinkingAt == nil { firstThinkingAt = now }
        lastThinkingAt = now
        thinkingDeltaCount += 1
    }

    public mutating func markText(at now: Date = Date()) {
        if firstTextAt == nil { firstTextAt = now }
        lastTextAt = now
        textDeltaCount += 1
    }

    public mutating func markTextDone(at now: Date = Date()) {
        textDoneAt = now
    }

    public mutating func markTerminal(at now: Date = Date()) {
        if terminalAt == nil { terminalAt = now }
    }

    public mutating func markEnd(at now: Date = Date()) {
        if endedAt == nil { endedAt = now }
    }
}

extension LLMRequestMetric {
    /// 按 ModelDefinition.pricing 估算一次调用的费用（原币种金额；pricing 缺失返回 nil）。
    public static func estimatedCost(
        inputTokens: Int?, cachedTokens: Int?, cacheCreation: Int?, outputTokens: Int?,
        pricing: ModelPricing?
    ) -> (amount: Double, currency: String)? {
        guard let pricing else { return nil }
        // 价格单位：每 1M token。
        let input = Double(inputTokens ?? 0) / 1_000_000 * pricing.input
        let cached = Double(cachedTokens ?? 0) / 1_000_000 * (pricing.cacheRead ?? 0)
        let cacheWrite = Double(cacheCreation ?? 0) / 1_000_000 * (pricing.cacheWrite ?? 0)
        let output = Double(outputTokens ?? 0) / 1_000_000 * pricing.output
        let total = input + cached + cacheWrite + output
        if total == 0 && (inputTokens ?? 0) == 0 && (outputTokens ?? 0) == 0 { return nil }
        return (total, pricing.currency.rawValue)
    }
}
