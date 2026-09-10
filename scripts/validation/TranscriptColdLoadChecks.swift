import AppKit
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

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for name in ["uiTiming", "scrollState", "turnOffsets", "rendererError"] {
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
        if message.name == "uiTiming", let body = message.body as? [String: Any] {
            applyCount += 1
            domMS += (body["durationMs"] as? NSNumber)?.doubleValue ?? 0
        }
        if message.name == "rendererError" { fatalError("JS: \(message.body)") }
        // uiTiming 写指标不参与验证，避免把合成数据写进用户 API 监控文件。
        if message.name != "uiTiming" { coordinator.userContentController(userContentController, didReceive: message) }
    }

    func close() {
        for name in ["uiTiming", "scrollState", "turnOffsets", "rendererError"] {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.navigationDelegate = nil
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
        }
    }
}
