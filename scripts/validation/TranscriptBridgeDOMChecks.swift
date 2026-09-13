import Foundation
import NewPiCore
import WebKit

extension TranscriptColdLoadChecks {
    /// 真实 Coordinator → JSON → WKWebView → WKScriptMessage；只使用合成条目。
    @MainActor static func checkMetadataAndRetryBridge() async throws {
        FileHandle.standardError.write(Data("Bridge probe: start\n".utf8))
        let page = ColdPage()
        let copyProbe = TranscriptCopyBridgeProbe(page: page)
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
        // 真实 Coordinator 写入确认；合成 sink 不触碰系统剪贴板。
        _ = try await js("document.querySelector('.ti-action-copy').click(); return true;")
        try await settle()
        precondition(copyProbe.writes == [source])
        let copied = try await js("return document.querySelector('.ti-action-copy').dataset.copyStatus;") as? String
        precondition(copied == "success")
        guard let validCopy = copyProbe.payloads.last else { preconditionFailure("缺少真实复制请求") }
        let copyCount = copyProbe.writes.count
        var forgedCopy = validCopy
        forgedCopy["capability"] = UUID().uuidString
        _ = try await js("window.webkit.messageHandlers.copyText.postMessage(payload); return true;", arguments: ["payload": forgedCopy])
        try await settle()
        precondition(copyProbe.writes.count == copyCount, "错误复制能力不能写入剪贴板")
        page.coordinator.setVisible(false)
        _ = try await js("window.webkit.messageHandlers.copyText.postMessage(payload); return true;", arguments: ["payload": validCopy])
        try await settle()
        precondition(copyProbe.writes.count == copyCount, "隐藏页面不能利用旧能力写入")
        page.coordinator.setVisible(true)
        // 暂存真实 native ack，以便验证 JS 不接受错误 requestID/capability 或旧按钮回执。
        _ = try await js("window.copyAcks=[]; window.copyApply=window.transcriptDoc.apply; window.transcriptDoc.apply=json=>{const ops=JSON.parse(json);copyAcks.push(...ops.filter(o=>o.op==='copyResult'));copyApply(JSON.stringify(ops.filter(o=>o.op!=='copyResult')));}; document.querySelector('.ti-action-copy').click(); return true;")
        try await settle()
        let pendingCopy = try await js("return document.querySelector('.ti-action-copy').dataset.copyStatus==='pending' && copyAcks.length===1;") as? Bool
        precondition(pendingCopy == true, "原生响应前不能显示已复制")
        let ignoresForged = try await js("const ack=copyAcks[0]; copyApply(JSON.stringify([{...ack,requestID:'wrong'}, {...ack,capability:'wrong'}])); return document.querySelector('.ti-action-copy').dataset.copyStatus==='pending';") as? Bool
        precondition(ignoresForged == true)
        let confirmedCopy = try await js("copyApply(JSON.stringify(copyAcks)); window.transcriptDoc.apply=copyApply; return document.querySelector('.ti-action-copy').dataset.copyStatus==='success';") as? Bool
        precondition(confirmedCopy == true)
        _ = try await js("window.webkit.messageHandlers.copyText.postMessage('legacy raw <>&'); return true;")
        try await settle()
        precondition(copyProbe.writes.last == "legacy raw <>&", "旧字符串协议必须保留")
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
        // 直接使用脚本提取的生产模型：新增字段不能只在手写 JS payload 中通过。
        let plan = ProgressReport(steps: [
            .init(id: "read", title: "读取", status: .completed),
            .init(id: "verify", title: "验证", status: .inProgress)
        ])
        let report = TestReport(path: "synthetic-results.xml", passed: 4, failed: 1, skipped: 2)
        let planID = UUID(), reportID = UUID()
        let group = NewPiTranscriptItem(kind: .detailGroup(collapsed: false), body: "", detailTurnID: "report-turn")
        func reportRows(_ plan: ProgressReport?, _ report: TestReport?) -> [NewPiTranscriptItem] {
            [group,
             NewPiTranscriptItem(id: planID, kind: .tool(name: "update_plan", state: .completed(isError: false)),
                body: "固定计划正文", detailTurnID: "report-turn", progressReport: plan),
             NewPiTranscriptItem(id: reportID, kind: .tool(name: "read_test_report", state: .completed(isError: false)),
                body: "固定报告正文", detailTurnID: "report-turn", testReport: report),
             currentAnswer.copying(answerState: .some("final"))]
        }
        apply(reportRows(nil, nil))
        try await settle()
        for (nextPlan, nextReport, expectedPlan, expectedReport) in [
            (plan as ProgressReport?, nil as TestReport?, "Agent计划（自报） · 1/2", ""),
            (plan, report, "Agent计划（自报） · 1/2", "JUnit 报告汇总：通过 4 · 失败 1 · 跳过 2"),
            (nil, report, "Agent计划（自报） · 未提供计划", "JUnit 报告汇总：通过 4 · 失败 1 · 跳过 2"),
            (nil, nil, "Agent计划（自报） · 未提供计划", "")
        ] {
            let batches = page.applyCount
            apply(reportRows(nextPlan, nextReport))
            try await settle()
            precondition(page.applyCount == batches + 1, "每次只改一个报告字段也必须触发一批真实 JSON 更新")
            let valid = try await js("""
                return document.querySelector('.plan-summary').textContent===plan &&
                  (document.querySelector('.result-test-summary')?.textContent || '')===report &&
                  (report!=='' || !document.querySelector('.result-test-summary, .result-test-notice, .result-test-source')) &&
                  bridgeArticle===document.querySelector('article') && bridgeCode===document.querySelector('code');
                """, arguments: ["plan": expectedPlan, "report": expectedReport]) as? Bool
            precondition(valid == true, "计划/报告新增与撤回必须更新 DOM，保留正文与代码节点")
        }
        let copiedRows = reportRows(plan, report).map { $0.copying() }
        precondition(copiedRows[1].progressReport == plan && copiedRows[2].testReport == report,
            "生产 copying 必须保留结构化计划/报告")
        let replayPage = ColdPage()
        replayPage.load(copiedRows, hues: [:], restore: nil)
        for _ in 0..<300 {
            if replayPage.loaded && replayPage.applyCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(replayPage.loaded && replayPage.applyCount == 1)
        let replayed = try await replayPage.webView.callAsyncJavaScript("""
            return document.querySelector('.plan-summary').textContent==='Agent计划（自报） · 1/2' &&
              document.querySelectorAll('.plan-row').length===2 &&
              document.querySelector('.result-test-summary').textContent==='JUnit 报告汇总：通过 4 · 失败 1 · 跳过 2' &&
              document.querySelector('.result-test-source').textContent.includes('JUnit · synthetic-results.xml') &&
              document.querySelector('.result-test-notice').textContent.includes('不保证报告新鲜度');
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        replayPage.close()
        precondition(replayed == true, "全新文档冷重放不能丢失生产模型中的计划/报告及来源限制")
        FileHandle.standardError.write(Data("PASS: extracted production report fields/copying/metadata-only signatures/withdrawal/stable Markdown/fresh-page replay\n".utf8))
        apply([currentAnswer, error(title: "自定义标题")])
        try await settle()
        let title = try await js("return document.querySelector('.error-title').textContent;") as? String
        precondition(title == "自定义标题")
        // 相同 tool body/kind，仅全局 snapshot.isStreaming 变化也必须发送 interrupted 差异。
        let pendingTool = NewPiTranscriptItem(kind: .tool(name: "read", state: .running), body: "", toolCommand: "file.swift")
        let failedTool = NewPiTranscriptItem(kind: .tool(name: "bash", state: .completed(isError: true)), body: "failed")
        apply([pendingTool, failedTool, currentAnswer, error()], running: true)
        try await settle()
        let running = try await js("return document.querySelector('.ti-tool .card').dataset.status==='running';") as? Bool
        precondition(running == true)
        apply([pendingTool, failedTool, currentAnswer, error()])
        try await settle()
        let stopped = try await js("const cards=[...document.querySelectorAll('.ti-tool .card')]; return cards[0].dataset.status==='stopped' && cards[1].dataset.status==='error';") as? Bool
        precondition(stopped == true, "未完成调用变 stopped，实际 failed 保留 error")
        let nextTool = NewPiTranscriptItem(kind: .tool(name: "read", state: .running), body: "", toolCommand: "next.swift")
        apply([pendingTool, failedTool, currentAnswer, error(), nextTool], running: true)
        try await settle()
        let notRevived = try await js("const cards=[...document.querySelectorAll('.ti-tool .card')];return cards[0].dataset.status==='stopped' && cards[1].dataset.status==='error' && cards[2].dataset.status==='running';") as? Bool
        precondition(notRevived == true, "下一轮运行不能复活已中断调用")
        let lateResult = NewPiTranscriptItem(id: pendingTool.id, kind: .tool(name: "read", state: .completed(isError: false)), body: "late result")
        apply([lateResult, failedTool, currentAnswer, error(), nextTool], running: true)
        try await settle()
        let resolved = try await js("return document.querySelector('.ti-tool .card').dataset.status==='done';") as? Bool
        precondition(resolved == true, "迟到的真实结果可以替代中断展示")
        apply([currentAnswer, error()])
        try await settle()
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
        let beforeSubframeCopy = copyProbe.writes.count
        _ = try await js("const f=document.createElement('iframe'); f.srcdoc='<script>window.webkit.messageHandlers.copyText.postMessage('+JSON.stringify(payload)+')</script>'; document.body.append(f); await new Promise(r=>f.onload=r); return true;", arguments: ["payload": validCopy])
        try await settle()
        precondition(copyProbe.writes.count == beforeSubframeCopy, "即使合法能力也拒绝子 frame 写入")
        page.coordinator.detach()
        try await post(errorID.uuidString, expectedCalls: 2)
        try await postFork(7, expectedCalls: 2)
        FileHandle.standardError.write(Data("PASS: actual fork button/WeakMap/fake class/index/kind/running/hidden/stale DOM/latest snapshot/mainframe/detached guards\n".utf8))
        FileHandle.standardError.write(Data("PASS: actual Coordinator epoch/signature/root/code + retry button/callback/UUID/kind/states/running/hidden/stale DOM/latest snapshot/mainframe/detached guards\n".utf8))
    }
}