import AppKit
import NewPiCore
import SwiftUI
import WebKit

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

    func jumpTo(_ id: UUID) {
        coordinator?.jumpTo(id)
    }

    func scrollToBottom() {
        coordinator?.scrollToBottom()
    }

    fileprivate func updateScrollState(nearBottom: Bool, anchorID: String?, anchorDelta: CGFloat, scrollTop: CGFloat) {
        isNearBottom = nearBottom
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
        markerPositions = positions
    }
}

/// 单文档 transcript 视图：整条会话渲染进一个 WKWebView。
/// SwiftUI 侧只做 transcript diff → ops → JS；高度表/窗口化/预热在此路径下全部不参与。
struct NewPiTranscriptDocumentView: NSViewRepresentable {
    @ObservedObject var runtime: SessionRuntime
    let controller: TranscriptDocumentController
    /// 轮对话色调：itemID → 色相度数（面板层按最近 user 锚点算好传入）。
    var tintHues: [UUID: Int] = [:]
    /// 冷启动/切回时要恢复的滚动锚点（nil = 落底）。仅首个内容批次应用一次。
    var restoreEntry: ScrollPositionStore.Entry?

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "copyText")
        configuration.userContentController.add(context.coordinator, name: "rendererError")
        configuration.userContentController.add(context.coordinator, name: "scrollState")
        configuration.userContentController.add(context.coordinator, name: "turnOffsets")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView)
        context.coordinator.sessionID = runtime.sessionID
        context.coordinator.pendingRestoreEntry = restoreEntry
        context.coordinator.loadShell()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(
            transcript: runtime.transcript,
            isStreaming: runtime.isStreaming,
            streamingBubbleComplete: runtime.streamingBubbleComplete,
            tintHues: tintHues
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rendererError")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scrollState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "turnOffsets")
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        private weak var controller: TranscriptDocumentController?
        private var isPageLoaded = false
        /// 页面未就绪时暂存最近一次 transcript，didFinish 后一次性应用。
        private var pendingSnapshot: TranscriptSnapshot?
        /// 上一次已应用的条目签名（id → 签名）与顺序，用于增量 diff。
        private var lastSignatures: [UUID: String] = [:]
        private var lastOrder: [UUID] = []
        /// 会话标识（供控制器持久化滚动锚点）。
        var sessionID: UUID?
        /// 待恢复的滚动锚点：首个内容批次应用后随批下发一次（nil = 落底）。
        var pendingRestoreEntry: ScrollPositionStore.Entry?
        private var didApplyRestore = false

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
                  let scriptURL = NewPiMarkdownWebDocument.rendererScriptURL() else { return }
            isPageLoaded = false
            webView.loadHTMLString(
                NewPiMarkdownWebDocument.transcriptDocumentHTML(rendererScriptURL: scriptURL),
                baseURL: scriptURL.deletingLastPathComponent()
            )
        }

        // MARK: - 意图（原生 → JS）

        func jumpTo(_ id: UUID) {
            send(ops: [["op": "jumpTo", "id": id.uuidString]])
        }

        func scrollToBottom() {
            send(ops: [["op": "scrollToBottom"]])
        }

        // MARK: - transcript 应用（diff → ops）

        private struct TranscriptSnapshot {
            let items: [NewPiTranscriptItem]
            let isStreaming: Bool
            let streamingBubbleComplete: Bool
            let tintHues: [UUID: Int]
        }

        func apply(
            transcript: [NewPiTranscriptItem],
            isStreaming: Bool,
            streamingBubbleComplete: Bool,
            tintHues: [UUID: Int]
        ) {
            let snapshot = TranscriptSnapshot(
                items: transcript,
                isStreaming: isStreaming,
                streamingBubbleComplete: streamingBubbleComplete,
                tintHues: tintHues
            )
            guard isPageLoaded else {
                pendingSnapshot = snapshot
                return
            }
            applyLoaded(snapshot)
        }

        private func applyLoaded(_ snapshot: TranscriptSnapshot) {
            var ops: [[String: Any]] = []
            var newOrder: [UUID] = []
            var newSignatures: [UUID: String] = [:]

            let lastItemID = snapshot.items.last?.id
            for item in snapshot.items {
                newOrder.append(item.id)
                let streaming = isStreamingItem(item, snapshot: snapshot, lastItemID: lastItemID)
                let signature = Self.signature(of: item, streaming: streaming, tint: snapshot.tintHues[item.id])
                newSignatures[item.id] = signature
                guard lastSignatures[item.id] != signature else { continue }
                ops.append(Self.upsertOp(for: item, streaming: streaming, tint: snapshot.tintHues[item.id]))
            }

            // 删除已不存在的条目（fork 回退等）
            let currentIDs = Set(newOrder)
            for oldID in lastOrder where !currentIDs.contains(oldID) {
                ops.append(["op": "remove", "id": oldID.uuidString])
            }

            // 顺序变化（fork 重建）时整体重排
            if newOrder != lastOrder, !lastOrder.isEmpty {
                ops.append(["op": "order", "ids": newOrder.map { $0.uuidString }])
            }

            lastSignatures = newSignatures
            lastOrder = newOrder

            guard !ops.isEmpty else { return }
            // 首个内容批次末尾附带滚动位置恢复（同批同步执行：upsert 完即锚定，
            // 无「高度未回」中间态）；无保存位置则落底。
            if !didApplyRestore {
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
            send(ops: ops)
        }

        /// 与遗留面板一致的活跃流式条目判定：最后一条 assistant/summary 且正文未落定。
        private func isStreamingItem(
            _ item: NewPiTranscriptItem,
            snapshot: TranscriptSnapshot,
            lastItemID: UUID?
        ) -> Bool {
            if case .thinking(let streaming) = item.kind {
                return streaming
            }
            return snapshot.isStreaming
                && !snapshot.streamingBubbleComplete
                && item.id == lastItemID
                && item.isAssistantMarkdown
        }

        private static func signature(of item: NewPiTranscriptItem, streaming: Bool, tint: Int?) -> String {
            var kindTag: String
            var extra = ""
            switch item.kind {
            case .user: kindTag = "user"
            case .assistant: kindTag = "assistant"
            case .summary: kindTag = "summary"
            case .system: kindTag = "system"
            case .error: kindTag = "error"
            case .thinking(let s): kindTag = "thinking"; extra = s ? "1" : "0"
            case .tool(let name, let state):
                switch state {
                case .running: kindTag = "tool"; extra = "run|" + name
                case .completed(let isError): kindTag = "tool"; extra = (isError ? "err|" : "ok|") + name
                }
            }
            return "\(kindTag)|\(extra)|\(streaming ? 1 : 0)|\(tint ?? -1)|\(item.body)"
        }

        private static func upsertOp(for item: NewPiTranscriptItem, streaming: Bool, tint: Int?) -> [String: Any] {
            var op: [String: Any] = [
                "op": "upsert",
                "id": item.id.uuidString,
                "body": item.body,
                "streaming": streaming,
            ]
            if let tint { op["tint"] = tint }
            switch item.kind {
            case .user: op["kind"] = "user"
            case .assistant: op["kind"] = "assistant"
            case .summary: op["kind"] = "summary"
            case .system: op["kind"] = "system"
            case .error: op["kind"] = "error"
            case .thinking: op["kind"] = "thinking"
            case .tool(let name, let state):
                op["kind"] = "tool"
                op["toolName"] = name
                switch state {
                case .running: op["toolRunning"] = true
                case .completed(let isError): op["toolError"] = isError
                }
            }
            return op
        }

        // MARK: - JS 通道

        private func send(ops: [[String: Any]]) {
            guard let webView, isPageLoaded,
                  let data = try? JSONSerialization.data(withJSONObject: ops),
                  let json = String(data: data, encoding: .utf8) else { return }
            // 双重编码：ops 内含模型输出的任意字符，防止 </script> 类内容破坏 JS 字符串边界。
            // apply 接收 JSON 字符串并自行 JSON.parse——不要在外层再 parse 一次。
            guard let literalData = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]),
                  var literal = String(data: literalData, encoding: .utf8) else { return }
            literal = literal.replacingOccurrences(of: "</", with: "<\\/")
            webView.evaluateJavaScript("window.transcriptDoc && window.transcriptDoc.apply(\(literal));") { _, error in
                if let error {
                    // 完整打印 NSError（含 WKJavaScriptException* userInfo），localizedDescription 会丢行号。
                    NewPiLogger.error(category: "app", message: "Transcript doc apply failed", details: "\(error)")
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            if let pending = pendingSnapshot {
                pendingSnapshot = nil
                applyLoaded(pending)
            }
        }

        // 单点故障对策（BACKLOG-SINGLE-DOC 风险表）：内容进程终止 = 整条 transcript 白屏。
        // 重建外壳 + 全量重放（签名表已重置，所有条目重新 upsert）。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NewPiLogger.error(category: "app", message: "Transcript document process terminated, rebuilding")
            lastSignatures = [:]
            lastOrder = []
            // 重建后按当前会话的保存位置再恢复一次（白屏重建前刚存下的位置）。
            if let sessionID {
                pendingRestoreEntry = ScrollPositionStore.shared.entry(for: sessionID)
                didApplyRestore = false
            }
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
            case "copyText":
                guard let text = message.body as? String else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
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
                controller?.updateScrollState(
                    nearBottom: nearBottom,
                    anchorID: anchorID,
                    anchorDelta: anchorDelta,
                    scrollTop: scrollTop
                )
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
            default:
                break
            }
        }
    }
}
