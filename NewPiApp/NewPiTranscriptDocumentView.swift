import AppKit
import NewPiCore
import SwiftUI
import WebKit

/// 易失展示态；不落盘、不进入模型上下文。DOM UUID 由 Coordinator 按运行身份与请求映射。
struct NewPiTranscriptApproval: Sendable, Equatable {
    let runtimeIdentity: String
    let request: ToolApprovalRequest
    let workingDirectory: URL
    var role: String? = nil
    var isRoom = false

    var scopes: [ApprovalScope] {
        request.dangerLevel == .high ? [.once] : isRoom ? [.once, .session] : [.once, .session, .forever]
    }
}

/// 单文档 transcript 的原生侧控制器（BACKLOG-SINGLE-DOC，Phase 2）。
/// 原生只发意图（jumpTo / scrollToBottom / restoreAnchor），滚动位置与布局完全由文档自持；
/// isNearBottom / 滚动锚点 / turn offsets 均由 JS 侧上报（原生不计算任何滚动几何）。
@MainActor
final class TranscriptDocumentController: ObservableObject {
    @Published private(set) var isNearBottom = true
    /// rail minimap 数据源：user 条目 id → 文档内相对位置（0-1），JS 实测上报。
    @Published private(set) var markerPositions: [UUID: Double] = [:]

    fileprivate weak var coordinator: NewPiTranscriptDocumentView.Coordinator?
    /// 滚动锚点持久化所属会话（由视图挂载时注入）。
    var sessionID: UUID?
    fileprivate var latencyTrace: RequestLatencyTrace?
    fileprivate var latencyFirstTextItemID: UUID?

    func beginLatencyTrace(_ trace: RequestLatencyTrace, firstTextItemID: UUID?) {
        latencyTrace = trace
        latencyFirstTextItemID = firstTextItemID
    }

    func jumpTo(_ id: UUID) {
        coordinator?.jumpTo(id)
    }

    func scrollToBottom() {
        coordinator?.scrollToBottom()
    }

    func setVisible(_ visible: Bool) {
        coordinator?.setVisible(visible)
    }

    // MARK: - 流式直连（STREAMING-LAYOUT-ISOLATION）

    /// 流式 flush 绕过 SwiftUI 直达 WebView：面板不再因 @Published 每 flush re-diff，
    /// WKWebView 从布局传播中隔离。由 ViewModel 在流式 flush 时调用。
    func applyLive(
        items: [NewPiTranscriptItem],
        isStreaming: Bool,
        streamingBubbleComplete: Bool,
        tintHues: [UUID: Int]
    ) {
        coordinator?.applyLive(
            transcript: items,
            isStreaming: isStreaming,
            streamingBubbleComplete: streamingBubbleComplete,
            tintHues: tintHues
        )
    }

    /// 边界提交后解除直连独占：SwiftUI 恢复为唯一驱动（下次 updateNSView 的 diff 为空操作）。
    func endLiveApply() {
        coordinator?.endLiveApply()
    }

    fileprivate func updateScrollState(nearBottom: Bool, anchorID: String?, anchorDelta: CGFloat, scrollTop: CGFloat) {
        if isNearBottom != nearBottom { isNearBottom = nearBottom }
        // 滚动锚点即改即存（内存表；磁盘写由 store 自带 2s 防抖），
        // 切换会话/冷启动恢复时的数据源。
        if let sessionID {
            ScrollPositionStore.shared.set(
                sessionID,
                rowID: anchorID.flatMap { UUID(uuidString: $0) },
                delta: anchorDelta,
                offset: scrollTop
            )
        }
    }

    fileprivate func updateMarkerPositions(_ positions: [UUID: Double]) {
        if markerPositions != positions { markerPositions = positions }
    }
}

/// 单文档 transcript 视图：整条会话渲染进一个 WKWebView。
/// SwiftUI 侧只做 transcript diff → ops → JS；高度表/窗口化/预热在此路径下全部不参与。
/// 泛化形态（CHATROOM-FLAT-MD Phase 0）：不再绑 SessionRuntime，吃显式参数，
/// session 与聊天室（消息适配为 transcript items 后）共用同一条渲染管线。
struct NewPiTranscriptDocumentView: NSViewRepresentable {
    let transcript: [NewPiTranscriptItem]
    let isStreaming: Bool
    let streamingBubbleComplete: Bool
    /// 滚动锚点持久化 key（session 用 sessionID，聊天室用 chatroom UUID；nil = 不持久化）。
    let storeKey: UUID?
    let controller: TranscriptDocumentController
    var isVisible = true
    /// 轮对话/角色色调：itemID → 色相度数（面板层算好传入）。
    var tintHues: [UUID: Int] = [:]
    /// 冷启动/切回时要恢复的滚动锚点（nil = 落底）。仅首个内容批次应用一次。
    var restoreEntry: ScrollPositionStore.Entry?
    /// 可选展示上下文；不从目录/模型正文推断项目或轮次。
    var projectName: String? = nil
    var dateContext: String? = nil
    /// 分叉意图回传（点击某条消息的 Fork 按钮时触发，参数为 messageIndex）。
    var onFork: ((Int) -> Void)?
    /// 仅表达重试意图；运行时负责重试与草稿隔离。
    var onRetry: ((UUID) -> Void)? = nil
    var approval: NewPiTranscriptApproval? = nil
    var onApproval: ((String, ApprovalDecision) -> Void)? = nil
    /// 返回 true 仅表示当前 runtime 已领取此决策，不表示工具执行成功。
    /// 新接线优先于旧 void 回调；旧回调继续可用，但不能生成“已允许/已拒绝”回执。
    var onApprovalAccepted: ((String, ApprovalDecision) -> Bool)? = nil
    /// 每次领取时重新读取真实 runtime，不能只信 SwiftUI 的上一帧。
    var approvalIsCurrent: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "copyText")
        configuration.userContentController.add(context.coordinator, name: "fork")
        configuration.userContentController.add(context.coordinator, name: "retryError")
        configuration.userContentController.add(context.coordinator, name: "transcriptApproval")
        configuration.userContentController.add(context.coordinator, name: "rendererError")
        configuration.userContentController.add(context.coordinator, name: "scrollState")
        configuration.userContentController.add(context.coordinator, name: "turnOffsets")
        configuration.userContentController.add(context.coordinator, name: "attachmentTap")
        configuration.userContentController.add(context.coordinator, name: "uiTiming")
        // 附件图片受控读取通道（BACKLOG-IMAGE-INPUT）：pi-att:// 仅经 SessionAttachments.resolve
        // 放行附件根目录内路径，WebView 不获得任意本地文件读取能力。
        configuration.setURLSchemeHandler(AttachmentSchemeHandler(), forURLScheme: AttachmentSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // 顺序敏感：attach 会把 coordinator.sessionID 注入 controller（滚动锚点持久化依赖），
        // 必须先赋值再 attach，否则 controller.sessionID 永远为 nil、位置不落盘（冷启动无法恢复）。
        context.coordinator.sessionID = storeKey
        context.coordinator.pendingRestoreEntry = restoreEntry
        context.coordinator.onFork = onFork
        context.coordinator.onRetry = onRetry
        context.coordinator.onApproval = onApproval
        context.coordinator.onApprovalAccepted = onApprovalAccepted
        context.coordinator.approvalIsCurrent = approvalIsCurrent
        context.coordinator.updateContext(projectName: projectName, dateContext: dateContext)
        context.coordinator.updateApproval(approval, after: transcript.last?.id)
        context.coordinator.attach(webView)
        context.coordinator.setVisible(isVisible)
        context.coordinator.loadShell()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFork = onFork
        context.coordinator.onRetry = onRetry
        context.coordinator.onApproval = onApproval
        context.coordinator.onApprovalAccepted = onApprovalAccepted
        context.coordinator.approvalIsCurrent = approvalIsCurrent
        context.coordinator.updateContext(projectName: projectName, dateContext: dateContext)
        // 不受 liveDriven 内容独占影响；隐藏时仍立即撤销旧权限。
        context.coordinator.setVisible(isVisible)
        context.coordinator.updateApproval(approval, after: transcript.last?.id, flushImmediately: false)
        context.coordinator.apply(
            transcript: transcript,
            isStreaming: isStreaming,
            streamingBubbleComplete: streamingBubbleComplete,
            tintHues: tintHues
        )
        context.coordinator.flushPresentation()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fork")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "retryError")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "transcriptApproval")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rendererError")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scrollState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "turnOffsets")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "attachmentTap")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "uiTiming")
        webView.navigationDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var frameProbeTrace: RequestLatencyTrace?
        private var frameProbeTimeout: Task<Void, Never>?
        private weak var webView: WKWebView?
        private weak var controller: TranscriptDocumentController?
        private var isPageLoaded = false
        /// 加载、隐藏或等待 JS 时只保留最新快照；不排队积累过时的流式帧。
        private var pendingSnapshot: TranscriptSnapshot?
        private var latestSnapshot: TranscriptSnapshot?
        private var pendingScrollIntent: [String: Any]?
        private var isVisible = true
        private var isSending = false
        private var pageGeneration = 0
        private var needsReset = false
        private var lastScrollAnchor: ScrollPositionStore.Entry?
        /// 上一次已应用的条目签名（id → 签名）与顺序，用于增量 diff。
        private var lastSignatures: [UUID: Signature] = [:]
        private var lastOrder: [UUID] = []
        /// 已观察到结束但无结果的调用；仅页面宿主内存，下一轮运行不能让旧步骤复活。
        private var interruptedToolIDs: Set<UUID> = []
        /// 会话标识（供控制器持久化滚动锚点）。
        var sessionID: UUID?
        /// 待恢复的滚动锚点：首个内容批次应用后随批下发一次（nil = 落底）。
        var pendingRestoreEntry: ScrollPositionStore.Entry?
        /// 分叉意图回传（由视图在 make/update 时注入）。
        var onFork: ((Int) -> Void)?
        var onRetry: ((UUID) -> Void)?
        var onApproval: ((String, ApprovalDecision) -> Void)?
        var onApprovalAccepted: ((String, ApprovalDecision) -> Bool)?
        var approvalIsCurrent: (() -> Bool)?
        /// 默认真正写入系统剪贴板；隔离探针可替换 sink，不绕过能力校验或确认路径。
        var writeClipboard: (String) -> Bool = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        private var latestApproval: NewPiTranscriptApproval?
        private struct ApprovalIdentity: Hashable {
            let runtime: String
            let request: String
        }
        private var approvalIDs: [ApprovalIdentity: UUID] = [:]
        private var approvalID = UUID()
        private var approvalNonce = UUID()
        private var approvalAfter: UUID?
        private var approvalDirty = false
        private var approvalClaimed = false
        private var claimedApprovalIdentities: Set<ApprovalIdentity> = []
        private var pendingPresentationEvents: [[String: Any]] = []
        private var copyCapability = UUID()
        private var copyCapabilityDirty = true
        private var projectName: String?
        private var dateContext: String?
        private var contextDirty = true

        func updateContext(projectName: String?, dateContext: String?) {
            guard self.projectName != projectName || self.dateContext != dateContext else { return }
            self.projectName = projectName
            self.dateContext = dateContext
            contextDirty = true
        }

        private func receiptOp(outcome: String, message: String) -> [String: Any] {
            ["op": "approvalReceipt", "id": approvalID.uuidString, "nonce": approvalNonce.uuidString,
             "outcome": outcome, "message": message]
        }

        private func takePresentationOps() -> [[String: Any]] {
            var ops: [[String: Any]] = []
            if copyCapabilityDirty {
                copyCapabilityDirty = false
                ops.append(["op": "copyCapability", "capability": copyCapability.uuidString])
            }
            if contextDirty {
                contextDirty = false
                ops.append(["op": "context", "projectName": projectName ?? "", "dateContext": dateContext ?? ""])
            }
            ops.append(contentsOf: pendingPresentationEvents)
            pendingPresentationEvents.removeAll()
            if approvalDirty {
                approvalDirty = false
                ops.append(approvalOp())
            }
            return ops
        }

        func updateApproval(_ approval: NewPiTranscriptApproval?, after: UUID?, flushImmediately: Bool = true) {
            guard latestApproval != approval else { return }
            let sameRequest = latestApproval?.runtimeIdentity == approval?.runtimeIdentity
                && latestApproval?.request.id == approval?.request.id
            if latestApproval != nil, !sameRequest, !approvalClaimed {
                pendingPresentationEvents.append(receiptOp(outcome: "cancelled", message: "审批已取消或撤销；未收到允许/拒绝决策。"))
            }
            latestApproval = approval
            if let approval {
                let identity = ApprovalIdentity(runtime: approval.runtimeIdentity, request: approval.request.id)
                let id = approvalIDs[identity] ?? UUID()
                approvalIDs[identity] = id
                approvalID = id
            }
            approvalNonce = UUID()
            // 固定在请求出现时的正文位置，插话不会把审批搬到新的 user 后面。
            if !sameRequest { approvalAfter = liveDriven ? latestSnapshot?.items.last?.id ?? after : after }
            approvalClaimed = approval.map {
                claimedApprovalIdentities.contains(ApprovalIdentity(runtime: $0.runtimeIdentity, request: $0.request.id))
            } ?? false
            approvalDirty = true
            if flushImmediately { flushPending() }
        }

        func flushPresentation() { flushPending() }

        private func approvalOp() -> [String: Any] {
            guard let approval = latestApproval, !approvalClaimed else { return ["op": "approval"] }
            var op: [String: Any] = ["op": "approval", "id": approvalID.uuidString,
                "nonce": approvalNonce.uuidString, "requestID": approval.request.id,
                "toolName": approval.request.toolName, "summary": approval.request.summary,
                "risk": approval.request.dangerLevel.displayName,
                "reason": approval.request.dangerReason ?? "", "role": approval.role ?? "",
                "directory": approval.workingDirectory.path,
                "scopes": approval.scopes.map(\.rawValue), "isRoom": approval.isRoom]
            if let approvalAfter { op["afterID"] = approvalAfter.uuidString }
            return op
        }
        private var didApplyRestore = false
        /// PIN-PROBE：最近一次上报的 JS 滚动意图（变化才记日志）。
        private var lastReportedIntent: String?
        /// PIN-PROBE2：最近一次记日志的 scrollTop / docHeight（≥400px 变化才记）。
        private var lastReportedScrollTop: Double = -1
        private var lastReportedDocHeight: Double = -1
        /// 上一次下发的全局 fork 锁状态（会话是否正在流式），变化时才发 forkLock op。
        private var lastForkLocked: Bool?

        init(controller: TranscriptDocumentController) {
            self.controller = controller
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            controller?.coordinator = self
            controller?.sessionID = sessionID
        }

        func loadShell() {
            guard let webView,
                  let scriptURL = NewPiMarkdownWebDocument.rendererScriptURL() else {
                NewPiLogger.error(category: "app", message: "Transcript renderer resources unavailable")
                return
            }
            pageGeneration += 1
            isSending = false
            isPageLoaded = false
            webView.loadHTMLString(
                NewPiMarkdownWebDocument.transcriptDocumentHTML(rendererScriptURL: scriptURL),
                baseURL: scriptURL.deletingLastPathComponent()
            )
        }

        // MARK: - 意图（原生 → JS）

        func jumpTo(_ id: UUID) {
            pendingScrollIntent = ["op": "jumpTo", "id": id.uuidString]
            flushPending()
        }

        func scrollToBottom() {
            pendingScrollIntent = ["op": "scrollToBottom"]
            flushPending()
        }

        func setVisible(_ visible: Bool) {
            guard isVisible != visible else { return }
            isVisible = visible
            if visible { flushPending() }
        }

        func detach() {
            cancelFrameProbe()
            approvalNonce = UUID()
            pageGeneration += 1
            isPageLoaded = false
            isSending = false
            if controller?.coordinator === self { controller?.coordinator = nil }
            webView = nil
        }

        // MARK: - transcript 应用（diff → ops）

        private struct TranscriptSnapshot {
            let items: [NewPiTranscriptItem]
            let isStreaming: Bool
            let streamingBubbleComplete: Bool
            let tintHues: [UUID: Int]
        }

        /// SwiftUI 路径（updateNSView 驱动）。直连独占期间忽略：内容已由 applyLive
        /// 投递，此路径只剩其它 @Published 变化触发的重复调用，避免陈旧快照回写。
        func apply(
            transcript: [NewPiTranscriptItem],
            isStreaming: Bool,
            streamingBubbleComplete: Bool,
            tintHues: [UUID: Int]
        ) {
            guard !liveDriven else { return }
            applyInternal(
                transcript: transcript,
                isStreaming: isStreaming,
                streamingBubbleComplete: streamingBubbleComplete,
                tintHues: tintHues
            )
        }

        /// 流式直连入口（STREAMING-LAYOUT-ISOLATION）：ViewModel 绕过 SwiftUI 直达 WebView。
        func applyLive(
            transcript: [NewPiTranscriptItem],
            isStreaming: Bool,
            streamingBubbleComplete: Bool,
            tintHues: [UUID: Int]
        ) {
            liveDriven = true
            applyInternal(
                transcript: transcript,
                isStreaming: isStreaming,
                streamingBubbleComplete: streamingBubbleComplete,
                tintHues: tintHues
            )
        }

        /// 边界提交后解除直连独占：SwiftUI 恢复为唯一驱动。
        func endLiveApply() {
            liveDriven = false
        }

        private var liveDriven = false

        private func applyInternal(
            transcript: [NewPiTranscriptItem],
            isStreaming: Bool,
            streamingBubbleComplete: Bool,
            tintHues: [UUID: Int]
        ) {
            let currentIDs = Set(transcript.map(\.id))
            interruptedToolIDs.formIntersection(currentIDs)
            for item in transcript {
                if case .tool(_, .running) = item.kind {
                    if !isStreaming { interruptedToolIDs.insert(item.id) }
                } else {
                    // 真实成功/失败结果优先于先前的中断展示。
                    interruptedToolIDs.remove(item.id)
                }
            }
            let snapshot = TranscriptSnapshot(
                items: transcript,
                isStreaming: isStreaming,
                streamingBubbleComplete: streamingBubbleComplete,
                tintHues: tintHues
            )
            latestSnapshot = snapshot
            pendingSnapshot = snapshot
            flushPending()
        }

        private func flushPending() {
            guard isPageLoaded, isVisible, !isSending else { return }
            if let snapshot = pendingSnapshot {
                pendingSnapshot = nil
                applyLoaded(snapshot)
            } else if approvalDirty || copyCapabilityDirty || contextDirty || !pendingPresentationEvents.isEmpty {
                let ops: [[String: Any]] = (needsReset ? [["op": "reset"]] : []) + takePresentationOps()
                needsReset = false
                send(ops: ops)
            } else if let intent = pendingScrollIntent {
                pendingScrollIntent = nil
                send(ops: [intent])
            }
        }

        private func applyLoaded(_ snapshot: TranscriptSnapshot) {
            let diffStart = Date()
            var ops: [[String: Any]] = []
            if needsReset {
                ops.append(["op": "reset"])
                needsReset = false
            }
            var newOrder: [UUID] = []
            var newSignatures: [UUID: Signature] = [:]

            let lastItemID = snapshot.items.last?.id
            for item in snapshot.items {
                newOrder.append(item.id)
                let streaming = isStreamingItem(item, snapshot: snapshot, lastItemID: lastItemID)
                let interrupted: Bool
                if case .tool(_, .running) = item.kind { interrupted = !snapshot.isStreaming || interruptedToolIDs.contains(item.id) }
                else { interrupted = false }
                let signature = Self.signature(of: item, streaming: streaming, tint: snapshot.tintHues[item.id], interrupted: interrupted)
                newSignatures[item.id] = signature
                guard lastSignatures[item.id] != signature else { continue }
                ops.append(Self.upsertOp(for: item, streaming: streaming, tint: snapshot.tintHues[item.id], interrupted: interrupted))
            }

            // 删除已不存在的条目（fork 回退等）
            let currentIDs = Set(newOrder)
            for oldID in lastOrder where !currentIDs.contains(oldID) {
                ops.append(["op": "remove", "id": oldID.uuidString])
            }

            // 删除保留旧节点的相对顺序，新增节点自然追加；只有这两者不能形成目标顺序才重排。
            let naturalOrder = lastOrder.filter { currentIDs.contains($0) }
                + newOrder.filter { lastSignatures[$0] == nil }
            if newOrder != naturalOrder {
                ops.append(["op": "order", "ids": newOrder.map { $0.uuidString }])
            }

            lastSignatures = newSignatures
            lastOrder = newOrder
            ops.append(contentsOf: takePresentationOps())

            // 全局 fork 锁：会话正在流式时，forkFromMessage 有 guard !isStreaming 会静默丢弃，
            // 历史条目的 Fork 按钮应在流式期间一并禁用，避免点了无反馈（FORK-LOCK-GLOBAL）。
            if lastForkLocked != snapshot.isStreaming {
                lastForkLocked = snapshot.isStreaming
                ops.append(["op": "forkLock", "locked": snapshot.isStreaming])
            }

            // UI 侧指标：diff 计算耗时（每次 flush 都会触发；transcript 越大越贵）。
            let diffDuration = Date().timeIntervalSince(diffStart)
            let diffOpsCount = ops.count
            Task { [diffDuration, diffOpsCount] in
                await LLMMetricsRecorder.shared.record(UITranscriptDiffMetric(
                    duration: diffDuration,
                    opsCount: diffOpsCount
                ))
            }

            // 首个内容批次末尾附带滚动位置恢复（同批同步执行：upsert 完即锚定，
            // 无「高度未回」中间态）；无保存位置则落底。
            if !didApplyRestore, !snapshot.items.isEmpty {
                didApplyRestore = true
                if let entry = pendingRestoreEntry {
                    var restore: [String: Any] = ["op": "restoreAnchor", "delta": entry.delta, "offset": entry.offset]
                    if let rowID = entry.rowID { restore["id"] = rowID }
                    ops.append(restore)
                } else {
                    ops.append(["op": "scrollToBottom", "smooth": false])
                }
                pendingRestoreEntry = nil
            }
            if let intent = pendingScrollIntent {
                pendingScrollIntent = nil
                ops.append(intent)
            }
            guard !ops.isEmpty else { flushPending(); return }
            send(ops: ops)
        }

        /// 聊天室使用显式条目状态，Session 保持末条 assistant/summary 的既有判定。
        private func isStreamingItem(
            _ item: NewPiTranscriptItem,
            snapshot: TranscriptSnapshot,
            lastItemID: UUID?
        ) -> Bool {
            item.isStreaming(isRunning: snapshot.isStreaming,
                bubbleComplete: snapshot.streamingBubbleComplete, lastItemID: lastItemID)
        }

        /// 保留字符串的值共享，不再每批把全部历史正文拼接成新的签名字符串。
        struct Signature: Equatable {
            let kind: NewPiTranscriptItemKind
            let streaming: Bool
            let interrupted: Bool
            let tint: Int?
            let detailTurnID: String?
            let forkIndex: Int?
            let speaker: String?
            let command: String?
            let timestamp: Date?
            let provider: String?
            let modelID: String?
            let errorTitle: String?
            let retryState: String?
            let fileChanges: [ToolFileChange]?
            let durationSeconds: Double?
            let answerState: String?
            let resultScopeID: String?
            let progressReport: ProgressReport?
            let testReport: TestReport?
            let attachments: [MessageAttachment]
            let body: String
        }

        private static func signature(of item: NewPiTranscriptItem, streaming: Bool, tint: Int?, interrupted: Bool) -> Signature {
            Signature(kind: item.kind, streaming: streaming, interrupted: interrupted, tint: tint,
                detailTurnID: item.detailTurnID, forkIndex: item.canFork ? item.messageIndex : nil,
                speaker: item.speaker, command: item.toolCommand,
                timestamp: item.timestamp, provider: item.provider, modelID: item.modelID,
                errorTitle: item.errorTitle, retryState: item.retryState,
                fileChanges: item.fileChanges, durationSeconds: item.durationSeconds,
                answerState: item.answerState, resultScopeID: item.resultScopeID,
                progressReport: item.progressReport, testReport: item.testReport,
                attachments: item.attachments, body: item.body)
        }

        private static func upsertOp(for item: NewPiTranscriptItem, streaming: Bool, tint: Int?, interrupted: Bool) -> [String: Any] {
            var op: [String: Any] = [
                "op": "upsert",
                "id": item.id.uuidString,
                "body": item.body,
                "streaming": streaming,
                "interrupted": interrupted,
            ]
            if let tint { op["tint"] = tint }
            if let command = item.toolCommand { op["command"] = command }
            if let turnID = item.detailTurnID { op["detailTurnID"] = turnID }
            // 发言者名字（CHATROOM-FLAT-MD Phase 2）：聊天室角色发言专用，session 路径不下发。
            if let speaker = item.speaker { op["speaker"] = speaker }
            // 毫秒 epoch 保留真实时间精度；缺失不填当前时间，JS 按文档固定时区展示。
            if let timestamp = item.timestamp { op["timestamp"] = timestamp.timeIntervalSince1970 * 1000 }
            if let provider = item.provider { op["provider"] = provider }
            if let modelID = item.modelID { op["modelID"] = modelID }
            if let errorTitle = item.errorTitle { op["errorTitle"] = errorTitle }
            if let retryState = item.retryState { op["retryState"] = retryState }
            if let changes = item.fileChanges { op["fileChanges"] = Self.changePayload(changes) }
            if let seconds = item.durationSeconds, seconds.isFinite, seconds >= 0 { op["durationSeconds"] = seconds }
            if let state = item.answerState { op["answerState"] = state }
            if let scope = item.resultScopeID { op["resultScopeID"] = scope }
            if let report = item.progressReport {
                op["progressReport"] = ["source": report.source.rawValue, "steps": report.steps.map {
                    ["id": $0.id, "title": $0.title, "status": $0.status.rawValue]
                }] as [String: Any]
            }
            if let report = item.testReport {
                op["testReport"] = ["source": report.source.rawValue, "path": report.path,
                    "passed": report.passed, "failed": report.failed, "skipped": report.skipped,
                    "total": report.total] as [String: Any]
            }
            op["coverageNotice"] = ToolFileChange.coverageNotice
            // 可 fork 条目的分叉能力元数据（JS 侧据此显示 Fork 按钮）。
            if item.canFork, let messageIndex = item.messageIndex {
                op["canFork"] = true
                op["messageIndex"] = messageIndex
            }
            switch item.kind {
            case .user:
                op["kind"] = "user"
                // 附件图片（BACKLOG-IMAGE-INPUT）：src 走 pi-att:// 受控通道，JS 侧 <img> 懒加载。
                if !item.attachments.isEmpty {
                    op["attachments"] = item.attachments.compactMap { attachment -> [String: Any]? in
                        guard let src = AttachmentSchemeHandler.imageURL(forRelativePath: attachment.path) else {
                            return nil
                        }
                        // path 供 JS 点击放大回传（受控解析）；alt 为展示名。
                        return ["src": src, "alt": attachment.displayName, "path": attachment.path]
                    }
                }
            case .assistant: op["kind"] = "assistant"
            case .summary: op["kind"] = "summary"
            case .system:
                op["kind"] = "system"
                // 仅适配器的显式元数据可以产生阶段线，正文碰巧含“阶段”不构成信号。
                if item.resultScopeID == "newpi:chatroom-phase" { op["phaseDivider"] = true }
            case .error: op["kind"] = "error"
            case .thinking: op["kind"] = "thinking"
            case .tool(let name, let state):
                op["kind"] = "tool"
                op["toolName"] = name
                switch state {
                case .running: op["toolRunning"] = true
                case .completed(let isError): op["toolError"] = isError
                }
            case .detailGroup(let collapsed):
                op["kind"] = "detailGroup"
                op["collapsed"] = collapsed
            }
            return op
        }

        // MARK: - JS 通道

        private static func changePayload(_ changes: [ToolFileChange]) -> Any {
            guard let data = try? JSONEncoder().encode(changes),
                  let value = try? JSONSerialization.jsonObject(with: data) else { return [] as [String] }
            return value
        }

        /// 只接收原生下发能力；模型 HTML/class/dataset 都不是授权来源。
        private func receiveApproval(_ body: [String: Any]) {
            guard let approval = latestApproval, !approvalClaimed,
                  approvalIsCurrent?() == true,
                  body["id"] as? String == approvalID.uuidString,
                  body["nonce"] as? String == approvalNonce.uuidString,
                  body["requestID"] as? String == approval.request.id,
                  let action = body["action"] as? String else { return }
            let decision: ApprovalDecision
            if action == "deny" { decision = .deny }
            else if action == "approve", let raw = body["scope"] as? String,
                    let scope = ApprovalScope(rawValue: raw), approval.scopes.contains(scope) {
                decision = ApprovalDecision(approved: true, scope: scope)
            } else { return }
            guard onApprovalAccepted != nil || onApproval != nil else { return }
            let identity = ApprovalIdentity(runtime: approval.runtimeIdentity, request: approval.request.id)
            guard !claimedApprovalIdentities.contains(identity) else { return }
            approvalClaimed = true
            claimedApprovalIdentities.insert(identity)
            approvalDirty = true
            // 保存领取时的能力；回调允许同步清空/替换当前审批，但回执仍只属于旧请求。
            let acceptedReceipt = receiptOp(outcome: decision.approved ? "approved" : "denied", message:
                decision.approved ? (decision.scope == .once ? "已允许一次 · 仅授权本次操作，执行结果见工具步骤。" :
                    decision.scope == .session ? "已允许 · 本\(approval.isRoom ? "聊天室" : "对话")内该类工具的非高危调用；高危仍需单次确认。" :
                    "已允许 · 记忆该类工具的非高危授权；高危仍需单次确认。") :
                    "已拒绝本次操作 · 未授予执行权限。")
            let unconfirmedReceipt = receiptOp(outcome: "cancelled", message: "审批请求已结束；未收到可确认的接受结果，不代表已允许或已拒绝。")
            if let onApprovalAccepted {
                // 防止同步回调中 updateApproval(nil) 抢先下发清除，再丢失回执锚点。
                let wasSending = isSending
                isSending = true
                let accepted = onApprovalAccepted(approval.request.id, decision)
                pendingPresentationEvents.append(accepted ? acceptedReceipt : unconfirmedReceipt)
                isSending = wasSending
            } else {
                let wasSending = isSending
                isSending = true
                onApproval?(approval.request.id, decision)
                pendingPresentationEvents.append(unconfirmedReceipt)
                isSending = wasSending
            }
            flushPending()
        }

        private func send(ops: [[String: Any]]) {
            guard let webView, isPageLoaded else { return }
            // 双重编码：ops 内含模型输出的任意字符，防止 </script> 类内容破坏 JS 字符串边界。
            // apply 接收 JSON 字符串并自行 JSON.parse——不要在外层再 parse 一次。
            let literalData: Data
            do {
                let data = try JSONSerialization.data(withJSONObject: ops)
                let json = String(decoding: data, as: UTF8.self)
                literalData = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
            } catch {
                NewPiLogger.error(category: "app", message: "Transcript ops encoding failed", details: "\(error)")
                invalidateAppliedState()
                return
            }
            var literal = String(decoding: literalData, as: UTF8.self)
            literal = literal.replacingOccurrences(of: "</", with: "<\\/")
            isSending = true
            let generation = pageGeneration
            var script = "window.transcriptDoc.apply(\(literal));"
            var probe: RequestLatencyTrace?
            if let trace = controller?.latencyTrace,
               let itemID = controller?.latencyFirstTextItemID,
               ops.contains(where: {
                   $0["op"] as? String == "upsert" && $0["id"] as? String == itemID.uuidString
                       && ($0["body"] as? String)?.isEmpty == false
               }), trace.mark(.firstJSDispatch) {
                probe = trace
                cancelFrameProbe()
                frameProbeTrace = trace
                // 两次 RAF 仅是浏览器帧机会，不代表 CA/WindowServer 已把像素送到显示器。
                // 参数是原生生成 UUID；模型正文仍只通过上面的 JSON 编码进入文档。
                script += """
                requestAnimationFrame(function() { requestAnimationFrame(function() {
                  window.webkit.messageHandlers.uiTiming.postMessage({
                    firstTextFrameRunID: '\(trace.id.uuidString)', documentVisible: !document.hidden
                  });
                }); }); void 0;
                """
                frameProbeTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.frameProbeTrace?.id == trace.id else { return }
                    trace.mark(.frameNotObserved)
                }
            }
            let dispatchedProbe = probe
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, self.pageGeneration == generation else { return }
                self.isSending = false
                if let error {
                    dispatchedProbe?.mark(.presentationUnavailable)
                    if dispatchedProbe != nil { self.cancelFrameProbe() }
                    // 完整打印 NSError（含 WKJavaScriptException* userInfo），localizedDescription 会丢行号。
                    NewPiLogger.error(category: "app", message: "Transcript doc apply failed", details: "\(error)")
                    self.invalidateAppliedState()
                    return
                }
                dispatchedProbe?.mark(.firstDOMAcknowledged)
                self.flushPending()
            }
            // PAINT-GATE（STREAMING-LAYOUT-ISOLATION 的回归修复）：布局隔离移除了
            // 每 flush 的 @Published → 窗口不再有原生失效 → display cycle 不跑 →
            // WKWebView 的远程图层事务无人合成、画面冻结（滚动能救活同因）。
            // 派发 ops 后主动弄脏视图，把合成调度回来。代价为标记脏，实际绘制在下一 vsync。
            webView.setNeedsDisplay(.infinite)
        }

        private func cancelFrameProbe() {
            frameProbeTimeout?.cancel()
            frameProbeTimeout = nil
            frameProbeTrace?.mark(.presentationUnavailable)
            frameProbeTrace = nil
        }

        private func invalidateAppliedState() {
            needsReset = true
            lastSignatures = [:]
            lastOrder = []
            lastForkLocked = nil
            pendingSnapshot = latestSnapshot
            approvalDirty = true
            approvalNonce = UUID()
            pendingPresentationEvents.removeAll()
            copyCapability = UUID()
            copyCapabilityDirty = true
            contextDirty = true
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            flushPending()
        }

        // 单点故障对策（BACKLOG-SINGLE-DOC 风险表）：内容进程终止 = 整条 transcript 白屏。
        // 重建外壳 + 全量重放（签名表已重置，所有条目重新 upsert）。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancelFrameProbe()
            NewPiLogger.error(category: "app", message: "Transcript document process terminated, rebuilding")
            invalidateAppliedState()
            // 重建后按当前会话的保存位置再恢复一次（白屏重建前刚存下的位置）。
            if let anchor = lastScrollAnchor {
                pendingRestoreEntry = anchor
            } else if let sessionID {
                pendingRestoreEntry = ScrollPositionStore.shared.entry(for: sessionID)
            }
            didApplyRestore = false
            loadShell()
        }

        // SECURITY-REVIEW: 仅允许本地 file/about 资源；链接点击一律取消（bindLinks 已拦截）。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(url.isFileURL || url.scheme == "about" ? .allow : .cancel)
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "transcriptApproval":
                guard message.frameInfo.isMainFrame, isVisible, isPageLoaded,
                      let webView, message.webView === webView,
                      let body = message.body as? [String: Any] else { return }
                receiveApproval(body)
            case "copyText":
                guard message.frameInfo.isMainFrame, isVisible, isPageLoaded,
                      let webView, message.webView === webView else { return }
                let text: String
                var reply: [String: Any]?
                if let legacy = message.body as? String {
                    text = legacy
                } else if let body = message.body as? [String: Any],
                          let source = body["text"] as? String,
                          let requestID = body["requestID"] as? String, !requestID.isEmpty, requestID.count <= 128,
                          body["capability"] as? String == copyCapability.uuidString {
                    text = source
                    reply = ["op": "copyResult", "requestID": requestID, "capability": copyCapability.uuidString]
                } else { return }
                let success = writeClipboard(text)
                if var reply {
                    reply["success"] = success
                    pendingPresentationEvents.append(reply)
                    flushPending()
                }
            case "fork":
                guard message.frameInfo.isMainFrame, isVisible, let webView, message.webView === webView,
                    let body = message.body as? [String: Any],
                    let index = (body["index"] as? NSNumber)?.intValue,
                    let snapshot = latestSnapshot, !snapshot.isStreaming,
                    snapshot.items.contains(where: { $0.canFork && $0.messageIndex == index }) else { return }
                onFork?(index)
            case "retryError":
                // 不信任 HTML 链接、DOM dataset 或已派发但过时的页面状态。
                // 隐藏/待投递期间也以最新运行时快照判断，而不是 lastSignatures。
                    guard message.frameInfo.isMainFrame, isVisible, let webView,
                      message.webView === webView,
                      let body = message.body as? [String: Any],
                      let rawID = body["id"] as? String, let id = UUID(uuidString: rawID),
                      let snapshot = latestSnapshot, !snapshot.isStreaming,
                      snapshot.items.contains(where: {
                          $0.id == id && $0.kind == .error && $0.retryState == "available"
                      }), let onRetry else { return }
                onRetry(id)
            case "rendererError":
                NewPiLogger.error(
                    category: "app",
                    message: "Transcript document JS error",
                    details: message.body as? String ?? "unknown"
                )
            case "scrollState":
                guard let body = message.body as? [String: Any],
                      let nearBottom = body["nearBottom"] as? Bool else { return }
                let anchorID = body["anchorID"] as? String
                let anchorDelta = (body["anchorDelta"] as? NSNumber)?.doubleValue ?? 0
                let scrollTop = (body["scrollTop"] as? NSNumber)?.doubleValue ?? 0
                lastScrollAnchor = ScrollPositionStore.Entry(rowID: anchorID, delta: anchorDelta, offset: scrollTop)
                let docHeight = (body["docHeight"] as? NSNumber)?.doubleValue ?? 0
                // PIN-PROBE：JS 滚动意图变化观测（钉底回归定位），转迁时记一条。
                let intent = body["intent"] as? String ?? "?"
                // PIN-PROBE2：scrollTop/docHeight 每变 ≥400px 记一条——区分
                // 「文档没长高」（布局/容器）与「长高了但 scrollY 没跟」（scrollTo 失效）
                // 与「都正常但画面旧」（paint/合成层滞后）。
                if abs(scrollTop - lastReportedScrollTop) >= 400 || abs(docHeight - lastReportedDocHeight) >= 400 {
                    lastReportedScrollTop = scrollTop
                    lastReportedDocHeight = docHeight
                    NewPiLogger.info(
                        category: "app",
                        message: "PROBE scroll pos",
                        details: "panel=\(sessionID?.uuidString.prefix(8) ?? "?") scrollTop=\(Int(scrollTop)) docHeight=\(Int(docHeight)) intent=\(intent) nearBottom=\(nearBottom)"
                    )
                }
                if intent != lastReportedIntent {
                    let prev = lastReportedIntent
                    lastReportedIntent = intent
                    NewPiLogger.info(
                        category: "app",
                        message: "PROBE scroll intent",
                        details: "panel=\(sessionID?.uuidString.prefix(8) ?? "?") \(prev ?? "nil") -> \(intent) nearBottom=\(nearBottom) scrollTop=\(Int(scrollTop))"
                    )
                }
                controller?.updateScrollState(
                    nearBottom: nearBottom,
                    anchorID: anchorID,
                    anchorDelta: anchorDelta,
                    scrollTop: scrollTop
                )
            case "attachmentTap":
                // 点击缩略图放大（BACKLOG-IMAGE-INPUT 二期）：只接收相对路径，
                // 经 SessionAttachments.resolve 受控解析后弹原生预览窗。
                guard let body = message.body as? [String: Any],
                      let path = body["path"] as? String, !path.isEmpty else { return }
                let title = body["alt"] as? String ?? path
                AttachmentPreviewWindowController.shared.present(relativePath: path, title: title)
            case "turnOffsets":
                guard let body = message.body as? [String: Any],
                      let offsets = body["offsets"] as? [[String: Any]] else { return }
                var positions: [UUID: Double] = [:]
                for entry in offsets {
                    if let idString = entry["id"] as? String,
                       let id = UUID(uuidString: idString),
                       let frac = (entry["frac"] as? NSNumber)?.doubleValue {
                        positions[id] = frac
                    }
                }
                controller?.updateMarkerPositions(positions)
            case "uiTiming":
                // JS applyOps 耗时（DOM 应用 + 批量提交）回传 → 上报 UI 指标。
                guard let body = message.body as? [String: Any] else { return }
                if let runID = body["firstTextFrameRunID"] as? String {
                    guard let trace = frameProbeTrace, trace.id.uuidString == runID else { return }
                    if body["documentVisible"] as? Bool == true,
                       webView?.window?.occlusionState.contains(.visible) == true {
                        trace.mark(.firstFrameCallback)
                    } else {
                        trace.mark(.presentationUnavailable)
                    }
                    frameProbeTimeout?.cancel()
                    frameProbeTimeout = nil
                    frameProbeTrace = nil
                    return
                }
                let duration = (body["durationMs"] as? NSNumber)?.doubleValue ?? 0
                let opsCount = (body["opsCount"] as? NSNumber)?.intValue ?? 0
                // PROBE（BACKLOG-STALL 定位）：JS 执行完成时刻。与「PROBE stream flush」
                // 的差值 = JS 队列等待 + 执行；此后到下一事件消费的间隔 = PAINT/表面分配阻塞。
                NewPiLogger.info(
                    category: "app",
                    message: "PROBE dom applied",
                    details: "ms=\(String(format: "%.0f", duration)) ops=\(opsCount)"
                )
                Task {
                    await LLMMetricsRecorder.shared.record(UIDomApplyMetric(
                        duration: duration / 1000,
                        opsCount: opsCount
                    ))
                }
            default:
                break
            }
        }
    }
}
