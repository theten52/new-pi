import AppKit
import Combine
import Foundation
import NewPiCore
import WebKit

// 仅隔离诊断落盘。被测 Coordinator/HTML/JS 不替换；滚动 sessionID 为 nil，不写用户位置。
actor LLMMetricsRecorder {
    static let shared = LLMMetricsRecorder()
    func record(_ metric: UITranscriptDiffMetric) {}
    func record(_ metric: UIDomApplyMetric) {}
}

enum NewPiLogger {
    static func info(category: String, message: String, details: String) {}
    static func error(category: String, message: String, details: String? = nil) {
        print("Coordinator error: \(message) \(details ?? "")")
    }
}

@MainActor
final class ColdPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let controller = TranscriptDocumentController()
    lazy var coordinator = NewPiTranscriptDocumentView.Coordinator(controller: controller)
    var webView: WKWebView!
    let window: NSWindow
    var loaded = false
    var applyCount = 0
    var domMS = 0.0
    var shellMS = 0.0
    var nativeMS = 0.0
    var started = ContinuousClock.now
    var retryMessageCount = 0
    var retrySubframeCount = 0
    var forkMessageCount = 0
    var forkSubframeCount = 0
    var approvalMessages: [[String: Any]] = []
    var approvalSubframeCount = 0
    var captureOnlyApprovalMessages = false
    var copiedTexts: [String] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for name in ["uiTiming", "scrollState", "turnOffsets", "rendererError", "retryError", "fork", "transcriptApproval", "copyText"] {
            config.userContentController.add(self, name: name)
        }
        config.userContentController.addUserScript(WKUserScript(source: """
            window.coldProbe = {heightReads:0,finalRenders:0};
            const originalRect = Element.prototype.getBoundingClientRect;
            Element.prototype.getBoundingClientRect = function() {
              if (this.classList.contains('article')) window.coldProbe.heightReads++;
              return originalRect.call(this);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: """
            const originalCreate = window.createMarkdownRenderer;
            window.createMarkdownRenderer = (...args) => {
              const renderer = originalCreate(...args), final = renderer.renderFinal;
              renderer.renderFinal = source => { window.coldProbe.finalRenders++; return final(source); };
              return renderer;
            };
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: window.contentLayoutRect, configuration: config)
        window.contentView = webView
        window.orderBack(nil)
        coordinator.attach(webView)
        // 测试代理只计时，所有导航完成/JS 消息仍交给真实 Coordinator。
        webView.navigationDelegate = self
    }

    func load(_ items: [NewPiTranscriptItem], hues: [UUID: Int], restore: UUID?) {
        if let restore {
            coordinator.pendingRestoreEntry = ScrollPositionStore.Entry(rowID: restore.uuidString, delta: 12, offset: 0)
        }
        // sessionID 为 nil：不读写用户滚动位置文件；本次恢复数据由 fixture 显式传入。
        started = .now
        coordinator.loadShell()
        for _ in 0..<2 {
            coordinator.apply(transcript: items, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellMS = ms(started.duration(to: .now))
        let start = ContinuousClock.now
        coordinator.webView(webView, didFinish: navigation)
        nativeMS = ms(start.duration(to: .now))
        loaded = true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "copyText" {
            if let text = message.body as? String { copiedTexts.append(text) }
            return // 合成复制测试不写用户剪贴板。
        }
        if message.name == "transcriptApproval" {
            if let body = message.body as? [String: Any] { approvalMessages.append(body) }
            if !message.frameInfo.isMainFrame { approvalSubframeCount += 1 }
            if captureOnlyApprovalMessages { return }
        }
        if message.name == "retryError" {
            retryMessageCount += 1
            if !message.frameInfo.isMainFrame { retrySubframeCount += 1 }
        }
        if message.name == "fork" {
            forkMessageCount += 1
            if !message.frameInfo.isMainFrame { forkSubframeCount += 1 }
        }
        if message.name == "uiTiming", let body = message.body as? [String: Any] {
            if body["firstTextFrameRunID"] != nil {
                coordinator.userContentController(userContentController, didReceive: message)
                return
            }
            applyCount += 1
            domMS += (body["durationMs"] as? NSNumber)?.doubleValue ?? 0
        }
        if message.name == "rendererError" { fatalError("JS: \(message.body)") }
        // uiTiming 写指标不参与验证，避免把合成数据写进用户 API 监控文件。
        if message.name != "uiTiming" { coordinator.userContentController(userContentController, didReceive: message) }
    }

    func close() {
        for name in ["uiTiming", "scrollState", "turnOffsets", "rendererError", "retryError", "fork", "transcriptApproval", "copyText"] {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.navigationDelegate = nil
        coordinator.detach()
        window.orderOut(nil)
        window.contentView = nil
    }
}

private func ms(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

@main
struct TranscriptColdLoadChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("FAIL: timeout"); exit(1) }
        NSApp.run()
    }

    @MainActor
    static func run() async throws {
        try await checkTranscriptApprovalEndToEnd()
        if ProcessInfo.processInfo.environment["NEWPI_APPROVAL_E2E_ONLY"] == "1" { return }
        try await checkMetadataAndRetryBridge()
        try await checkTranscriptActionsBridge()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let disk = ChatRoomStore(baseDirectory: temp)
        let room = ChatRoom(name: "cold-fixture", projectPath: temp.path)
        let role = ChatRoomRole(name: "Role A", description: "", systemPrompt: "")
        let history = (0..<500).map { i in
            ChatRoomMessage(chatroomID: room.id, roleID: role.id,
                content: "## Message \(i)\n\n" + String(repeating: "History content. ", count: 80)
                    + "\n\n```swift\nlet value = \(i)\n```", phase: .discussion)
        }
        try disk.saveMessages(history, for: room.id)
        let readStart = ContinuousClock.now
        let restored = try disk.loadMessages(for: room.id)
        let readMS = ms(readStart.duration(to: .now))
        var adapter = ChatRoomTranscriptAdapter()
        let adaptStart = ContinuousClock.now
        let roomSnapshot = adapter.adapt(messages: restored, roles: [role], liveSpeech: nil)
        let adaptMS = ms(adaptStart.duration(to: .now))
        let sessionItems = restored.map { NewPiTranscriptItem(id: UUID(uuidString: $0.id)!, kind: .assistant, body: $0.content) }
        print("fixtureReadMS=\(readMS),roomAdaptMS=\(adaptMS)")
        print("scenario,readMS,adaptMS,shellMS,nativeDiffEncodeDispatchMS,domApplyMS,throughTwoRAFms,applyBatches,rows,finalRenders,heightReads,anchorErrorPX")
        // 每次销毁并新建页面，对应聊天室切回和跨类型切换的冷恢复路径；不模拟 Session 保活命中。
        for (name, cachedItems, cachedHues, anchor) in [
            ("session-first", sessionItems, [UUID:Int](), nil as UUID?),
            ("room-A", roomSnapshot.items, roomSnapshot.tintHues, nil),
            ("room-B", Array(roomSnapshot.items.prefix(25)), roomSnapshot.tintHues, nil),
            ("room-A-return", roomSnapshot.items, roomSnapshot.tintHues, UUID(uuidString: history[250].id)),
            ("session-return", sessionItems, [UUID:Int](), UUID(uuidString: history[250].id))
        ] {
            // 聊天室运行时的历史只读一次，但切回仍走全量适配；B 使用独立的小历史。
            let adaptStart = ContinuousClock.now
            let snapshot = name.hasPrefix("room")
                ? adapter.adapt(messages: name == "room-B" ? Array(restored.prefix(24)) : restored,
                    roles: [role], liveSpeech: nil)
                : (items: cachedItems, tintHues: cachedHues)
            let adaptationMS = ms(adaptStart.duration(to: .now))
            let items = snapshot.items, hues = snapshot.tintHues
            let page = ColdPage()
            defer { page.close() }
            page.load(items, hues: hues, restore: anchor)
            for _ in 0..<3000 {
                if page.loaded && page.applyCount > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            FileHandle.standardError.write(Data("Cold check \(name): loaded=\(page.loaded), batches=\(page.applyCount)\n".utf8))
            precondition(page.loaded && page.applyCount == 1, "Pending SwiftUI snapshots must coalesce to one batch")
            _ = try await page.webView.callAsyncJavaScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;",
                arguments: [:], in: nil, contentWorld: .page)
            let elapsed = ms(page.started.duration(to: .now))
            // 让原有锚点恢复/空闲预热完成，不改其 3s 恢复窗口。
            try await Task.sleep(for: .milliseconds(3300))
            let result = try await page.webView.callAsyncJavaScript("""
                const rows = [...document.querySelectorAll('.ti')];
                const row = anchor ? rows.find(x => x.dataset.iid === anchor) : null;
                const error = row ? Math.abs(row.getBoundingClientRect().top + 12) : 0;
                return {...window.coldProbe,rows:rows.length,unique:new Set(rows.map(x=>x.dataset.iid)).size,error,anchorFound:!anchor||!!row,
                  code:!!document.querySelector('pre code'),nonblank:document.body.innerText.length>100};
                """, arguments: ["anchor": anchor?.uuidString ?? ""], in: nil, contentWorld: .page) as! [String: Any]
                        // 优化编译的 precondition trap 不保证打印文案；先输出真实结果定位失败，不放宽断言。
                        FileHandle.standardError.write(Data("Cold check \(name): expectedRows=\(items.count), expectedFinal=\(items.filter(\.isAssistantMarkdown).count), DOM=\(result)\n".utf8))
            precondition(result["rows"] as? Int == items.count && result["unique"] as? Int == items.count)
            precondition(result["nonblank"] as? Bool == true && result["code"] as? Bool == true)
            precondition(result["anchorFound"] as? Bool == true)
            precondition(result["finalRenders"] as? Int == items.filter(\.isAssistantMarkdown).count)
            precondition((result["error"] as? Double ?? 999) < 3, "Restored anchor drift")
            if ProcessInfo.processInfo.environment["NEWPI_EXPECT_NO_UNUSED_HEIGHT"] == "1" {
                precondition(result["heightReads"] as? Int == 0)
            }
            let values = [page.shellMS,page.nativeMS,page.domMS,elapsed].map { String(format:"%.2f",$0) }.joined(separator:",")
            // Session 数据由内存条目提供；其 SessionManager 读盘不在本探针计时范围。
            let diskTime = name == "room-A" ? String(format:"%.2f",readMS) : (name.hasPrefix("room") ? "0(cached)" : "not-measured")
            print("\(name),\(diskTime),\(String(format:"%.3f",adaptationMS)),\(values),\(page.applyCount),\(items.count),\(result["finalRenders"]!),\(result["heightReads"]!),\(result["error"]!)")
            // 重复提交不产生重复 DOM 或额外 JS apply。
            page.coordinator.apply(transcript: items, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
            try await Task.sleep(for: .milliseconds(50))
            precondition(page.applyCount == 1)
            if name == "session-first" {
                try await checkLifecycle(page, items: items, hues: hues)
            }
        }
    }

    @MainActor
    private static func checkLifecycle(_ page: ColdPage, items: [NewPiTranscriptItem], hues: [UUID: Int]) async throws {
        var notifications = 0
        let observation = page.controller.objectWillChange.sink {
            MainActor.assumeIsolated { notifications += 1 }
        }
        defer { observation.cancel() }
        let nearBottom = page.controller.isNearBottom
        _ = try await page.webView.callAsyncJavaScript("""
            for(let i=0;i<100;i++) {
              window.webkit.messageHandlers.scrollState.postMessage({nearBottom,scrollTop:i});
              window.webkit.messageHandlers.turnOffsets.postMessage({positions:[]});
            }
            return true;
            """, arguments: ["nearBottom":nearBottom], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(50))
        precondition(notifications == 0, "Equal UI state must not publish, even when scrollTop changes")

        _ = try await page.webView.evaluateJavaScript("""
            window.orderOps=0;
            const originalApply=window.transcriptDoc.apply;
            window.transcriptDoc.apply=json=>{
              window.orderOps+=JSON.parse(json).filter(op=>op.op==='order').length;
              return originalApply(json);
            };
            true;
            """)
        var latest = items
        let beforeBurst = page.applyCount
        for i in 0..<100 {
            latest[latest.count-1] = NewPiTranscriptItem(id: items.last!.id, kind: .assistant, body: "Latest streaming \(i)")
            page.coordinator.applyLive(transcript: latest, isStreaming: true,
                streamingBubbleComplete: false, tintHues: hues)
        }
        // 陈旧 SwiftUI 快照不得替换直连流式态。
        page.coordinator.apply(transcript: items, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
        try await wait { page.applyCount >= beforeBurst+1 }
        try await Task.sleep(for: .milliseconds(100))
        precondition(page.applyCount-beforeBurst <= 2, "One in-flight batch plus one latest snapshot, not 100 queued frames")
        let body = try await page.webView.evaluateJavaScript("document.querySelector('main').lastElementChild.textContent") as? String
        precondition(body?.contains("Latest streaming 99") == true, "Latest live text must win")

        page.controller.setVisible(false)
        let hiddenTrace = RequestLatencyTrace()
        page.controller.beginLatencyTrace(hiddenTrace, firstTextItemID: items.last!.id)
        let beforeHidden = page.applyCount
        for i in 0..<100 {
            latest[latest.count-1] = NewPiTranscriptItem(id: items.last!.id, kind: .assistant, body: "Hidden final \(i)")
            page.coordinator.applyLive(transcript: latest, isStreaming: false,
                streamingBubbleComplete: true, tintHues: hues)
        }
        page.coordinator.endLiveApply()
        try await Task.sleep(for: .milliseconds(100))
        precondition(page.applyCount == beforeHidden, "Hidden document must not receive content batches")
        precondition(!hiddenTrace.hasReached(.firstJSDispatch), "Hidden content must not be logged as displayed")
        page.controller.setVisible(true)
        try await wait { page.applyCount == beforeHidden+1 }
        let resumed = try await page.webView.evaluateJavaScript("document.querySelector('main').lastElementChild.textContent") as? String
        precondition(hiddenTrace.hasReached(.firstJSDispatch), "First text probe must follow deferred latest content")
        precondition(resumed?.contains("Hidden final 99") == true, "Showing a completed background turn must replay the latest snapshot")

        let added = NewPiTranscriptItem(kind: .user, body: "Appended user", messageIndex: 20)
        latest.append(added)
        page.coordinator.apply(transcript: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
        try await wait { page.applyCount == beforeHidden+2 }
        let orderOps = try await page.webView.evaluateJavaScript("window.orderOps") as? Int
        precondition(orderOps == 0, "Normal append must not reorder every existing node")
        latest.swapAt(0, latest.count-1)
        page.coordinator.apply(transcript: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
        try await wait { page.applyCount == beforeHidden+3 }
        let firstID = try await page.webView.evaluateJavaScript("document.querySelector('main').firstElementChild.dataset.iid") as? String
        precondition(firstID == added.id.uuidString, "Actual reorder must still be applied")
        latest[0] = NewPiTranscriptItem(id: added.id, kind: .user, body: added.body, messageIndex: 21)
        page.coordinator.apply(transcript: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: hues)
        try await wait { page.applyCount == beforeHidden+4 }
        let forkIndex = try await page.webView.evaluateJavaScript("document.querySelector('.ti-action-fork').dataset.forkIndex") as? String
        precondition(forkIndex == "21", "Metadata-only changes must invalidate the signature")

        // 只调用真实恢复回调，不终止任何系统进程，也不靠新的 SwiftUI apply 掩盖快照丢失。
        page.loaded = false
        let beforeRecovery = page.applyCount
        page.coordinator.webViewWebContentProcessDidTerminate(page.webView)
        try await wait { page.loaded && page.applyCount == beforeRecovery+1 }
        let recovered = try await page.webView.callAsyncJavaScript("""
            return {rows:document.querySelectorAll('.ti').length,text:document.querySelector('main').textContent};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        precondition(recovered?["rows"] as? Int == latest.count)
        precondition((recovered?["text"] as? String)?.contains("Hidden final 99") == true)

        page.controller.setVisible(false)
        latest[latest.count-1] = NewPiTranscriptItem(id: latest.last!.id, kind: .assistant,
            body: "Live recovery </script> \"quoted\" 中文")
        page.coordinator.applyLive(transcript: latest, isStreaming: true,
            streamingBubbleComplete: false, tintHues: hues)
        page.loaded = false
        let beforeHiddenRecovery = page.applyCount
        page.coordinator.webViewWebContentProcessDidTerminate(page.webView)
        try await wait { page.loaded }
        try await Task.sleep(for: .milliseconds(100))
        precondition(page.applyCount == beforeHiddenRecovery, "Hidden recovery must defer content replay")
        page.controller.setVisible(true)
        try await wait { page.applyCount == beforeHiddenRecovery+1 }
        let liveRecovery = try await page.webView.callAsyncJavaScript("""
            return {text:document.querySelector('main').lastElementChild.textContent,
              locked:document.querySelector('.ti-action-fork').disabled};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        // typographer 会把正文里的 ASCII 引号变成弯引号；这里只验证传输没有截断或执行 HTML。
        let liveText = liveRecovery?["text"] as? String ?? ""
        precondition(liveText.contains("Live recovery </script>") && liveText.contains("quoted") && liveText.contains("中文"),
            "Live snapshot must survive JSON escaping and Markdown typography")
        precondition(liveRecovery?["locked"] as? Bool == true, "Process replay must retain live fork lock")
        // 帧未回调不能伪装呈现成功；重建取消旧探针后，迟到消息也不能归给下一次发送。
        _ = try await page.webView.evaluateJavaScript("""
            window.savedRAF = window.requestAnimationFrame;
            window.requestAnimationFrame = function() { return 0; };
            true;
            """)
        let missingFrameTrace = RequestLatencyTrace()
        page.controller.beginLatencyTrace(missingFrameTrace, firstTextItemID: latest.last!.id)
        latest[latest.count-1] = NewPiTranscriptItem(id: latest.last!.id, kind: .assistant, body: "Missing frame probe")
        page.controller.applyLive(items: latest, isStreaming: true, streamingBubbleComplete: false, tintHues: hues)
        try await wait { missingFrameTrace.hasReached(.firstDOMAcknowledged) }
        try await Task.sleep(for: .milliseconds(3200))
        precondition(missingFrameTrace.hasReached(.frameNotObserved))
        precondition(!missingFrameTrace.hasReached(.firstFrameCallback))
        page.loaded = false
        page.coordinator.webViewWebContentProcessDidTerminate(page.webView)
        try await wait { page.loaded }
        precondition(missingFrameTrace.hasReached(.presentationUnavailable))
        _ = try await page.webView.callAsyncJavaScript("""
            window.webkit.messageHandlers.uiTiming.postMessage({
              firstTextFrameRunID: oldRunID, documentVisible:true
            });
            return true;
            """, arguments: ["oldRunID": missingFrameTrace.id.uuidString], in: nil, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(50))
        precondition(!missingFrameTrace.hasReached(.firstFrameCallback))
        print("PASS: missing frame reports timeout, page replacement cancels probe, stale frame ignored")
        print("PASS: deduplicated UI notifications; single-flight/latest-only content; hidden catch-up; append/reorder/metadata; static and hidden-live process recovery")
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for document lifecycle")
    }
}
