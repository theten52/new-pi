import Foundation
import WebKit

extension TranscriptColdLoadChecks {
    /// 真实 Coordinator → JSON → WKWebView → WKScriptMessage；只使用合成条目。
    @MainActor static func checkMetadataAndRetryBridge() async throws {
        FileHandle.standardError.write(Data("Bridge probe: start\n".utf8))
        let page = ColdPage()
        defer { page.close() }
        let errorID = UUID(), answerID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_600_000_000.125)
        let raw = "<script>throw new Error('untrusted')</script>\n原始错误"
        let source = "```swift\nlet value = 1\n```"
        var calls: [UUID] = []
        page.coordinator.onRetry = { calls.append($0) }
        func error(_ state: String? = "available", kind: NewPiTranscriptItemKind = .error,
                   title: String? = nil) -> NewPiTranscriptItem {
            NewPiTranscriptItem(id: errorID, kind: kind, body: raw,
                timestamp: stamp, errorTitle: title, retryState: state)
        }
        func answer(provider: String? = "历史 provider", model: String? = "历史 model",
                timestamp: Date? = nil) -> NewPiTranscriptItem {
            NewPiTranscriptItem(id: answerID, kind: .assistant, body: source,
            speaker: "历史 speaker", timestamp: timestamp ?? stamp, provider: provider, modelID: model)
        }
        func apply(_ items: [NewPiTranscriptItem], running: Bool = false) {
            page.coordinator.apply(transcript: items, isStreaming: running,
                streamingBubbleComplete: true, tintHues: [:])
        }
        func js(_ source: String, arguments: [String: Any] = [:]) async throws -> Any? {
            try await page.webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
        }
        func settle() async throws {
            // 等待真实 evaluateJavaScript 确认与消息投递，不读取任何用户存储。
            try await Task.sleep(for: .milliseconds(80))
            _ = try await js("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))); return true;")
        }
        func post(_ id: String, expectedCalls: Int) async throws {
            let count = page.retryMessageCount
            _ = try await js("window.webkit.messageHandlers.retryError.postMessage({id}); return true;", arguments: ["id": id])
            try await settle()
            precondition(page.retryMessageCount == count + 1, "必须经过真实 WK 消息通道")
            precondition(calls.count == expectedCalls, "原生最新快照必须拒绝未授权 retry")
        }
        page.load([answer(), error()], hues: [:], restore: nil)
        for _ in 0..<300 {
            if page.loaded && page.applyCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(page.loaded && page.applyCount > 0)
        FileHandle.standardError.write(Data("Bridge probe: shell loaded\n".utf8))
        let initial = try await js("""
            const answer=document.querySelector('[data-iid="'+answerID+'"]');
            window.bridgeArticle=answer.querySelector('article');
            window.bridgeCode=answer.querySelector('code');
            return {epoch:Date.parse(answer.querySelector('time').dateTime),
              providerBadge:!!answer.querySelector('.message-provider'),
              model:answer.querySelector('.message-model').textContent,
              raw:document.querySelector('.error-raw').textContent,
              retry:!document.querySelector('.error-retry').disabled};
            """, arguments: ["answerID": answerID.uuidString]) as! [String: Any]
        precondition(abs((initial["epoch"] as! Double) - stamp.timeIntervalSince1970 * 1000) < 1)
        precondition(initial["providerBadge"] as? Bool == false && initial["model"] as? String == "历史 model")
        precondition(initial["raw"] as? String == raw && initial["retry"] as? Bool == true)
        // 逐个只改一项，防 signature 漏字段被其他变化掩盖。
        var currentAnswer = answer()
        for next in [answer(provider: "更正 provider"), answer(provider: "更正 provider", model: "更正 model"),
                     answer(provider: "更正 provider", model: "更正 model", timestamp: stamp.addingTimeInterval(86_400))] {
            let batches = page.applyCount
            currentAnswer = next
            apply([currentAnswer, error()])
            try await settle()
            precondition(page.applyCount == batches + 1, "metadata-only signature 必须下发")
            let same = try await js("return window.bridgeArticle===document.querySelector('article') && window.bridgeCode===document.querySelector('code');") as? Bool
            precondition(same == true, "metadata-only 不重建 root/code")
        }
        apply([currentAnswer, error(title: "自定义标题")])
        try await settle()
        let title = try await js("return document.querySelector('.error-title').textContent;") as? String
        precondition(title == "自定义标题")
        // 真按钮回调 id；之后直接伪造 postMessage 验证 native 守卫。
        _ = try await js("document.querySelector('.error-retry').click(); return true;")
        try await settle()
        precondition(calls == [errorID])
        try await post("invalid-uuid", expectedCalls: 1)
        try await post(UUID().uuidString, expectedCalls: 1)
        try await post(answerID.uuidString, expectedCalls: 1)
        page.coordinator.onRetry = nil
        try await post(errorID.uuidString, expectedCalls: 1)
        page.coordinator.onRetry = { calls.append($0) }
        page.coordinator.setVisible(false)
        try await post(errorID.uuidString, expectedCalls: 1)
        apply([currentAnswer, error()], running: true) // DOM 仍为 available，最新快照已锁住。
        page.coordinator.setVisible(true)
        try await post(errorID.uuidString, expectedCalls: 1)
        let locked = try await js("return document.querySelector('.error-retry').disabled;") as? Bool
        precondition(locked == true)
        for state in [nil, "unavailable", "retrying", "recovered", "unexpected"] as [String?] {
            apply([currentAnswer, error(state)])
            try await settle()
            try await post(errorID.uuidString, expectedCalls: 1)
        }
        apply([currentAnswer, error("available", kind: .system)])
        try await settle()
        try await post(errorID.uuidString, expectedCalls: 1)
        apply([currentAnswer])
        try await settle()
        try await post(errorID.uuidString, expectedCalls: 1)
        // latestSnapshot 在隐藏/等待 JS 时也立即更新：页面还是 available 不能获得权限。
        apply([currentAnswer, error()])
        try await settle()
        // 模拟 DOM 尚未应用新快照：页面仍显示 available，原生必须按最新 recovered 拒绝。
        _ = try await js("window.bridgeApply=window.transcriptDoc.apply; window.transcriptDoc.apply=()=>{}; return true;")
        apply([currentAnswer, error("recovered")])
        try await settle()
        let staleButton = try await js("return !!document.querySelector('.error-retry');") as? Bool
        precondition(staleButton == true, "必须保持旧 DOM 才能覆盖过期页面权限")
        try await post(errorID.uuidString, expectedCalls: 1)
        _ = try await js("window.transcriptDoc.apply=window.bridgeApply; return true;")
        apply([currentAnswer, error()])
        try await settle()
        page.coordinator.setVisible(false)
        apply([currentAnswer, error("recovered")])
        try await post(errorID.uuidString, expectedCalls: 1)
        page.coordinator.setVisible(true)
        try await settle()
        apply([currentAnswer, error()])
        try await settle()
        try await post(errorID.uuidString, expectedCalls: 2)
        // 新 fork 守卫独立走真实桥；DOM dataset 与模型类名不构成分叉能力。
        let forkUser = NewPiTranscriptItem(kind: .user, body: "合成分叉用户", messageIndex: 7)
        var forks: [Int] = []
        page.coordinator.onFork = { forks.append($0) }
        func postFork(_ index: Int, expectedCalls: Int) async throws {
            let count = page.forkMessageCount
            _ = try await js("window.webkit.messageHandlers.fork.postMessage({index}); return true;", arguments: ["index": index])
            try await settle()
            precondition(page.forkMessageCount == count + 1 && forks.count == expectedCalls,
                "fork 必须走真实 WK 通道并按最新快照/可见性核验")
        }
        apply([forkUser, currentAnswer, error()])
        try await settle()
        _ = try await js("const b=document.querySelector('.ti-action-fork'); b.dataset.forkIndex='999'; b.click(); return true;")
        try await settle()
        precondition(forks == [7], "真实按钮能力来自 WeakMap，不能被 DOM dataset 篡改")
        let forkMessages = page.forkMessageCount
        _ = try await js("const fake=document.createElement('button'); fake.className='ti-action-fork'; fake.dataset.forkIndex='7'; document.querySelector('article').append(fake); fake.click(); fake.remove(); return true;")
        try await settle()
        precondition(page.forkMessageCount == forkMessages && forks == [7])
        try await postFork(999, expectedCalls: 1)
        page.coordinator.onFork = nil
        try await postFork(7, expectedCalls: 1)
        page.coordinator.onFork = { forks.append($0) }
        page.coordinator.setVisible(false)
        try await postFork(7, expectedCalls: 1)
        apply([forkUser, currentAnswer, error()], running: true)
        page.coordinator.setVisible(true)
        try await postFork(7, expectedCalls: 1)
        apply([NewPiTranscriptItem(id: forkUser.id, kind: .system, body: forkUser.body, messageIndex: 7), currentAnswer, error()])
        try await settle()
        try await postFork(7, expectedCalls: 1)
        apply([forkUser, currentAnswer, error()])
        try await settle()
        _ = try await js("window.bridgeApply=window.transcriptDoc.apply; window.transcriptDoc.apply=()=>{}; return true;")
        apply([currentAnswer, error()])
        try await settle()
        let staleFork = try await js("return !!document.querySelector('.ti-action-fork');") as? Bool
        precondition(staleFork == true, "必须保留旧 fork DOM 才能检验最新快照守卫")
        try await postFork(7, expectedCalls: 1)
        _ = try await js("window.transcriptDoc.apply=window.bridgeApply; return true;")
        apply([forkUser, currentAnswer, error()])
        try await settle()
        try await postFork(7, expectedCalls: 2)
        // 生产 CSP 的 frame-src none 是第一层；此处受控无 CSP 页面独立检验 mainframe 守卫。
        FileHandle.standardError.write(Data("Bridge probe: metadata and mainframe guards checked; testing subframe\n".utf8))
        page.loaded = false
        page.webView.loadHTMLString("<!doctype html><html><body>synthetic frame test</body></html>", baseURL: nil)
        for _ in 0..<300 {
            if page.loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let subframes = page.retrySubframeCount
        _ = try await js("""
            const frame=document.createElement('iframe');
            frame.srcdoc='<script>window.webkit.messageHandlers.retryError.postMessage({id:'+JSON.stringify(id)+'});window.webkit.messageHandlers.fork.postMessage({index:7})</script>';
            document.body.appendChild(frame);
            await new Promise(resolve=>frame.onload=resolve);
            return true;
            """, arguments: ["id": errorID.uuidString])
        try await settle()
        precondition(page.retrySubframeCount == subframes + 1 && calls.count == 2, "子 frame 即使有合法 UUID 也必须拒绝")
        precondition(page.forkSubframeCount == 1 && forks == [7, 7])
        page.coordinator.detach()
        try await post(errorID.uuidString, expectedCalls: 2)
        try await postFork(7, expectedCalls: 2)
        FileHandle.standardError.write(Data("PASS: actual fork button/WeakMap/fake class/index/kind/running/hidden/stale DOM/latest snapshot/mainframe/detached guards\n".utf8))
        FileHandle.standardError.write(Data("PASS: actual Coordinator epoch/signature/root/code + retry button/callback/UUID/kind/states/running/hidden/stale DOM/latest snapshot/mainframe/detached guards\n".utf8))
    }
}