import AppKit
import Foundation
import NewPiCore
import WebKit

/// 不改旧 ColdPage 宿主；在本组测试中捕获新协议并仍交给真实 Coordinator。
/// sink 是隔离的内存剪贴板，生产默认 sink 仍为 NSPasteboard.general。
@MainActor
final class TranscriptCopyBridgeProbe: NSObject, WKScriptMessageHandler {
    weak var page: ColdPage?
    var writes: [String] = []
    var payloads: [[String: Any]] = []
    var succeeds = true

    init(page: ColdPage) {
        self.page = page
        super.init()
        page.coordinator.writeClipboard = { [weak self] text in
            guard let self else { return false }
            self.writes.append(text)
            return self.succeeds
        }
        let controller = page.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "copyText")
        controller.add(self, name: "copyText")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let page else { return }
        if let body = message.body as? [String: Any] { payloads.append(body) }
        let before = writes.count
        page.coordinator.userContentController(controller, didReceive: message)
        if writes.count > before, let text = writes.last { page.copiedTexts.append(text) }
    }
}

extension TranscriptColdLoadChecks {
    /// 实际 Coordinator → 本地 CSP 页面 → WK 消息；仅合成文件，不调用审批 gate 执行工具。
    @MainActor static func checkTranscriptActionsBridge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let page = ColdPage()
        let copyProbe = TranscriptCopyBridgeProbe(page: page)
        defer { page.close() }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        page.window.styleMask = [.titled, .closable]
        page.window.setContentSize(NSSize(width: 900, height: 650))
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { previousApplication?.activate(options: []) }
        var decisions: [(String, ApprovalDecision)] = []
        var current = true
        page.coordinator.onApprovalAccepted = { decisions.append(($0, $1)); return true }
        page.coordinator.approvalIsCurrent = { current }

        func js(_ source: String, _ args: [String: Any] = [:]) async throws -> Any? {
            try await page.webView.callAsyncJavaScript(source, arguments: args, in: nil, contentWorld: .page)
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(80))
            _ = try await js("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))); return true;")
        }
        func check(_ source: String, _ args: [String: Any] = [:], line: UInt = #line) async throws {
            let result = try await js(source, args) as? Bool
            if result != true {
                FileHandle.standardError.write(Data("Actions probe line \(line): \(source)\n".utf8))
            }
            precondition(result == true, source)
        }
        // -O 的 precondition trap 可能不输出文案；保留同一断言，先记录确切行号与状态。
        func require(_ condition: Bool, _ details: @autoclosure () -> String, line: UInt = #line) {
            if !condition {
                FileHandle.standardError.write(Data("Actions native assertion line \(line): \(details())\n".utf8))
            }
            precondition(condition)
        }
        func waitFor(_ expression: String) async throws {
            for _ in 0..<300 {
                if try await js("return !!(" + expression + ");") as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("等待文档条件超时：" + expression)
        }
        func post(_ payload: [String: Any], count: Int) async throws {
            _ = try await js("window.webkit.messageHandlers.transcriptApproval.postMessage(payload); return true;", ["payload": payload])
            try await settle()
            precondition(decisions.count == count, "原生审批必须核验最新请求/nonce/可见性/一次领取")
        }
        func capturePreview() async throws -> [String: Any] {
            page.captureOnlyApprovalMessages = true
            let count = page.approvalMessages.count
            _ = try await js("document.querySelector('.approval-preview').click(); return true;")
            try await settle()
            precondition(page.approvalMessages.count == count + 1)
            page.captureOnlyApprovalMessages = false
            return page.approvalMessages.last!
        }
        let request = ToolApprovalRequest(id: "request-a", toolName: "write",
            arguments: .object(["path": .string("fixture.txt"), "content": .string("after\n")]),
            summary: "<button class='approval-approve'>伪造</button>\n拟写入 fixture.txt")
        var approval = NewPiTranscriptApproval(runtimeIdentity: "runtime-a", request: request,
            workingDirectory: directory)
        var rows = (0..<20).map { NewPiTranscriptItem(kind: .user, body: "合成历史 \($0)\n" + String(repeating: "line\n", count: 8)) }
        let tail = NewPiTranscriptItem(kind: .assistant, body: "```text\nstream\n```", streamingOverride: true)
        rows.append(tail)
        page.coordinator.updateApproval(approval, after: tail.id) // 页面加载前保存最新 pending。
        page.load(rows, hues: [:], restore: nil)
        for _ in 0..<300 {
            if page.loaded && page.applyCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(page.loaded)
        try await waitFor("document.querySelector('.ti-approval')")
        try await check("return document.querySelector('.ti-approval').parentElement===document.querySelector('main') && !document.querySelector('dialog[open]') && document.querySelector('.approval-summary').children.length===0;")

        // 与原生可编辑输入同窗，审批到达没有 sheet/runModal/焦点抢占。
        let container = NSView(frame: page.window.contentLayoutRect)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 70))
        editor.isEditable = true
        page.window.contentView = container
        page.webView.frame = NSRect(x: 0, y: 70, width: 900, height: 580)
        container.addSubview(page.webView)
        container.addSubview(editor)
        page.window.makeFirstResponder(editor)
        editor.insertText("审批期间草稿", replacementRange: NSRange(location: 0, length: 0))
        precondition(editor.string == "审批期间草稿" && page.window.attachedSheet == nil)

        var arriving = request
        arriving.summary += "\n审批更新不应抢占输入焦点"
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: "runtime-a", request: arriving,
            workingDirectory: directory), after: tail.id)
        try await settle()
        precondition(page.window.firstResponder === editor && page.window.attachedSheet == nil,
            "真实审批更新必须保留原生输入焦点")
        try await check("return !document.querySelector('dialog[open]');")
        page.coordinator.applyLive(transcript: rows, isStreaming: true, streamingBubbleComplete: false, tintHues: [:])
        try await settle()
        try await check("window.savedApproval=document.querySelector('.ti-approval'); window.savedCode=document.querySelector('main').querySelector('code'); return !document.querySelector('.approval-approve').disabled;")
        let captured = try await capturePreview()
        precondition(captured["nonce"] != nil && captured["id"] != nil)
        try await check("return !document.querySelector('.ti-approval').hasAttribute('data-nonce');")
        // 无真实按钮闭包的模型类名不会发送任何审批/分叉消息。
        let bridgeCount = page.approvalMessages.count
        _ = try await js("const fake=document.createElement('button'); fake.className='approval-approve'; document.querySelector('article').append(fake); fake.click(); fake.remove(); return true;")
        try await settle()
        precondition(page.approvalMessages.count == bridgeCount && decisions.isEmpty)

        // 随滚动移动；不依赖原生高度测量。锁住预热，使用同一个同步 JS 批次取差值。
        try await check("""
            window.dispatchEvent(new WheelEvent('wheel',{deltaY:-100}));
            window.scrollTo(0,300);
            const card=document.querySelector('.ti-approval'), y=scrollY, top=card.getBoundingClientRect().top;
            window.scrollTo(0,500);
            return Math.abs((card.getBoundingClientRect().top-top)+(scrollY-y))<1 && getComputedStyle(card).position!=='fixed';
            """)
        rows.append(NewPiTranscriptItem(kind: .user, body: "审批时插话\n" + String(repeating: "合成插话内容\n", count: 80)))
        page.coordinator.applyLive(transcript: rows, isStreaming: true, streamingBubbleComplete: false, tintHues: [:])
        try await settle()
        try await check("return savedApproval===document.querySelector('.ti-approval') && savedApproval.previousElementSibling.dataset.iid===tail && savedApproval.nextElementSibling.dataset.iid===user;", ["tail": tail.id.uuidString, "user": rows.last!.id.uuidString])
        // 即使 order 重排，审批仍留在创建时的锚点后。
        rows.swapAt(0, 1)
        page.coordinator.applyLive(transcript: rows, isStreaming: true, streamingBubbleComplete: false, tintHues: [:])
        try await settle()
        try await check("return savedApproval.previousElementSibling.dataset.iid===tail && savedCode===document.querySelector('code');", ["tail": tail.id.uuidString])

        // 真预览只读且异步；返回的是拟执行 diff，不领取审批。
        try await post(captured, count: 0)
        try await waitFor("document.querySelector('dialog[open] .diff-add')")
        try await check("return document.querySelector('dialog').textContent.includes('尚未执行') && document.querySelector('.change-diff').textContent.includes('+after');")
        let unchanged = try String(contentsOf: file, encoding: .utf8)
        precondition(unchanged == "before\n" && decisions.isEmpty)
        _ = try await js("document.querySelector('.changes-close').click(); return true;")
        try await settle()

        // 让最新 runtime 校验在 helper 返回时失效，验证异步结果不会打开旧请求 diff。
        var checks = 0
        page.coordinator.approvalIsCurrent = { checks += 1; return checks == 1 }
        try await post(captured, count: 0)
        for _ in 0..<100 {
            if checks >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(checks >= 2)
        try await check("return !document.querySelector('dialog[open]');")
        page.coordinator.approvalIsCurrent = { current }

        // 最新 runtime 已撤销、但 SwiftUI 尚未投递的窗口也不能获得权限。
        var allow = captured
        allow["action"] = "approve"; allow["scope"] = "once"
        current = false
        try await post(allow, count: 0)
        current = true
                // CV 在跨帧滚动后会更正占位高；不能假定此前 scrollTo 的落点仍是目标条目。
                // 在真实 apply 的同一同步边界定位并检查前置条件，不用后续 RAF 修正掩盖跳动。
        _ = try await js("""
            const anchor=document.querySelector('[data-iid="'+id+'"]');
            window.dispatchEvent(new WheelEvent('wheel',{deltaY:100}));
            window.scrollTo(0,anchor.getBoundingClientRect().top+scrollY+40);
            return true;
            """, ["id": rows.last!.id.uuidString])
        try await settle()
        try await waitFor("document.querySelector('main').lastElementChild.offsetHeight > innerHeight + 40")
                _ = try await js("""
                        const anchor=document.querySelector('[data-iid="'+id+'"]');
                        const original=window.transcriptDoc.apply;
                        window.transcriptDoc.apply=json=>{
                                const removing=JSON.parse(json).some(op=>op.op==='approval'&&!op.id);
                                if(removing) {
                                        window.dispatchEvent(new WheelEvent('wheel',{deltaY:100}));
                                        window.scrollTo(0,anchor.getBoundingClientRect().top+scrollY+40);
                                }
                                const geometry=()=>({top:anchor.getBoundingClientRect().top,y:scrollY,height:document.documentElement.scrollHeight,
                                    viewport:innerHeight,first:[...document.querySelector('main').children].find(el=>el.getBoundingClientRect().bottom>0)?.dataset.iid});
                                const before=geometry();
                                original(json);
                                if(removing) {
                                        window.approvalRemovalAnchorDelta=anchor.getBoundingClientRect().top-before.top;
                                        window.approvalRemovalGeometry={before,after:geometry(),id};
                                }
                        };
                        return true;
                        """, ["id": rows.last!.id.uuidString])
        page.coordinator.setVisible(false)
        try await post(allow, count: 0)
        page.coordinator.updateApproval(nil, after: nil) // liveDriven 不得吞掉撤销。
        page.coordinator.setVisible(true)
        try await settle()
        try await check("return !document.querySelector('.ti-approval');")
        try await check("return document.querySelector('.ti-approval-receipt[data-outcome=cancelled]')?.textContent.includes('取消') && !document.querySelector('.ti-approval-receipt[data-outcome=denied]');")
        let geometry = try await js("return JSON.stringify(window.approvalRemovalGeometry);") as? String ?? "missing"
        FileHandle.standardError.write(Data("Approval removal geometry: \(geometry)\n".utf8))
        try await check("const g=window.approvalRemovalGeometry; return g.before.first===g.id && Math.abs(g.before.top+40)<1;")
        try await check("return Math.abs(window.approvalRemovalAnchorDelta)<1;")
        try await post(allow, count: 0)

        // 同 requestID、不同 runtime 产生新能力；旧页面消息拒绝。
        approval = NewPiTranscriptApproval(runtimeIdentity: "runtime-b", request: request, workingDirectory: directory, isRoom: true)
        page.coordinator.updateApproval(approval, after: rows.last!.id)
        try await settle()
        let roomPayload = try await capturePreview()
        try await post(allow, count: 0)
        try await check("return [...document.querySelectorAll('.approval-approve')].length===2 && !document.querySelector('.ti-approval').textContent.includes('一直允许');")
        var invalidScope = roomPayload
        invalidScope["action"] = "approve"; invalidScope["scope"] = "forever"
        try await post(invalidScope, count: 0)
        var high = request
        high.dangerLevel = .high
        approval = NewPiTranscriptApproval(runtimeIdentity: "runtime-b", request: high, workingDirectory: directory, isRoom: true)
        page.coordinator.updateApproval(approval, after: rows.last!.id)
        try await settle()
        let highPayload = try await capturePreview()
        try await check("return document.querySelectorAll('.approval-approve').length===1 && document.querySelector('.approval-approve').textContent==='允许一次';")
        invalidScope = highPayload; invalidScope["action"] = "approve"; invalidScope["scope"] = "session"
        try await post(invalidScope, count: 0)

        // 内容进程恢复走实际生产回调（不杀系统进程），稳定 UUID、新 nonce、隐藏延迟重放。
        let oldID = highPayload["id"] as! String
        page.coordinator.setVisible(false)
        page.loaded = false
        page.coordinator.webViewWebContentProcessDidTerminate(page.webView)
        for _ in 0..<300 {
            if page.loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await check("return !document.querySelector('.ti-approval');")
        page.coordinator.setVisible(true)
        try await waitFor("document.querySelector('.ti-approval')")
        let recovered = try await capturePreview()
        precondition(recovered["id"] as? String == oldID && recovered["nonce"] as? String != highPayload["nonce"] as? String)
        var oldAllow = highPayload; oldAllow["action"] = "approve"; oldAllow["scope"] = "once"
        try await post(oldAllow, count: 0)
        var freshAllow = recovered; freshAllow["action"] = "approve"; freshAllow["scope"] = "once"
        _ = try await js("document.querySelector('.approval-approve').click(); return true;")
        try await settle()
        precondition(decisions.count == 1, "真实审批按钮必须经 WK 桥回传且只领取一次")
        try await post(freshAllow, count: 1)
        precondition(decisions.first?.1 == .allowOnce)
        try await check("return document.querySelectorAll('.ti-approval-receipt[data-outcome=approved]').length===1 && document.querySelector('.ti-approval-receipt[data-outcome=approved]').textContent.includes('仅授权本次操作');")
        page.coordinator.updateApproval(nil, after: nil)
        page.coordinator.endLiveApply()

        // 工具快照经真实 JSON 编码到正文；重复 path 统计一次，但每次编辑记录仍保留。
        let change = ToolFileChange(path: file.path, before: "before\n", after: "after\n",
            diff: "--- a/fixture.txt\n+++ b/fixture.txt\n@@ -1 +1 @@\n-before\n+after <script>evil()</script>\n",
            isTruncated: false, beforeExists: true)
        let userA = NewPiTranscriptItem(kind: .user, body: "第一轮")
        let toolA = NewPiTranscriptItem(kind: .tool(name: "write", state: .completed(isError: false)), body: "ok", fileChanges: [change], durationSeconds: 1.25)
        let toolB = NewPiTranscriptItem(kind: .tool(name: "edit", state: .completed(isError: false)), body: "ok", fileChanges: [change], durationSeconds: 0.75)
        let failed = NewPiTranscriptItem(kind: .tool(name: "bash", state: .completed(isError: true)), body: "failed", durationSeconds: 0.5)
        let rawAnswer = "**最终原始回答**\n\n```text\nraw only\n```"
        let answerA = NewPiTranscriptItem(kind: .assistant, body: rawAnswer, answerState: "final")
        let partial = NewPiTranscriptItem(kind: .assistant, body: "历史中断输出", answerState: "incomplete")
        let userB = NewPiTranscriptItem(kind: .user, body: "第二轮")
        let answerB = NewPiTranscriptItem(kind: .assistant, body: "没有快照的历史回答", answerState: "final")
        let fixtures = [userA, toolA, toolB, failed, partial, answerA, userB, answerB]
        precondition(toolA.copying(body: "copied").fileChanges == [change] && toolA.copying().durationSeconds == 1.25)
        page.coordinator.apply(transcript: fixtures, isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        try await settle()
                // 真实 Coordinator 的初始/metadata-only 批次都必须只有一个消息复制入口；不含代码块复制。
                func checkMessageCopies() async throws {
                        try await check("""
                                return [...document.querySelectorAll('.ti-user, .ti-answer')].every(row => {
                                    const copies=[...row.querySelectorAll('button.ti-action-copy, button.answer-copy')];
                                    const interactive=copies.filter(b=>b.isConnected && !b.disabled && b.tabIndex>=0 &&
                                        !b.closest('[hidden], [inert], [aria-hidden="true"]') &&
                                        getComputedStyle(b).display!=='none' && getComputedStyle(b).visibility==='visible');
                                    const footer=row.querySelector('.answer-footer');
                                    return copies.length===1 && interactive.length===1 &&
                                        row.querySelectorAll('.ti-action-copy').length===(footer?0:1) &&
                                        row.querySelectorAll('.answer-copy').length===(footer?1:0);
                                });
                                """)
                }
                try await checkMessageCopies()
        try await check("""
            const a=document.querySelector('[data-iid="'+aID+'"]'), b=document.querySelector('[data-iid="'+bID+'"]');
            window.answerCopy=a.querySelector('.answer-copy'); window.answerChanges=a.querySelector('.answer-changes');
            return document.querySelectorAll('.answer-footer').length===2 &&
              a.querySelector('.result-strip').textContent.includes('工具成功 2 · 失败 1') &&
              a.querySelector('.result-strip').textContent.includes('2 次 / 1 个路径') &&
              a.querySelector('.result-strip').textContent.includes('2.50 秒') &&
              b.querySelector('.result-strip').textContent.includes('本轮未记录文件编辑快照') &&
              !b.querySelector('.result-strip').textContent.includes('2 次');
            """, ["aID": answerA.id.uuidString, "bID": answerB.id.uuidString])
        _ = try await js("answerCopy.click(); answerChanges.click(); return true;")
        try await settle()
        precondition(page.copiedTexts.last == rawAnswer)
        precondition(copyProbe.writes.last == rawAnswer && copyProbe.payloads.last?["requestID"] != nil)
        try await check("return answerCopy.dataset.copyStatus==='success' && answerCopy.querySelector('.copy-state-icon svg') && document.querySelector('.answer-actions').nextElementSibling.classList.contains('result-strip');")
        copyProbe.succeeds = false
        _ = try await js("answerCopy.click(); return true;")
        try await settle()
        try await check("return answerCopy.dataset.copyStatus==='failure' && !answerCopy.classList.contains('copied');")
        copyProbe.succeeds = true
        try "external current change\n".write(to: file, atomically: true, encoding: .utf8)
        try await check("return document.querySelector('dialog').textContent.includes('after <script>evil()</script>') && !document.querySelector('dialog script') && !document.querySelector('dialog').textContent.includes('external current change');")
        // Escape 的 cancel 路由（不派发给审批决策/输入发送）；焦点回原按钮。
        _ = try await js("document.querySelector('dialog').dispatchEvent(new Event('cancel',{cancelable:true})); return true;")
        try await settle()
        try await check("return !document.querySelector('dialog[open]') && document.activeElement===answerChanges;")

        // 真正的 WebKit Escape keyDown，而非只测试 cancel 回调；事件仅投递合成测试窗口。
        _ = try await js("answerChanges.click(); return true;")
        try await settle()
        page.window.makeFirstResponder(page.webView)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: page.window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        page.window.sendEvent(escape)
        try await settle()
        try await check("return !document.querySelector('dialog[open]') && document.activeElement===answerChanges;")
        precondition(decisions.count == 1 && editor.string == "审批期间草稿")

        // 各字段独立变化，正文/UUID 不变；不能靠同时变更 body 掩盖 signature/dirty 漏项。
        _ = try await js("window.metadataArticle=document.querySelector('[data-iid=\"'+id+'\"] article'); window.metadataCode=metadataArticle.querySelector('code'); return true;", ["id": answerA.id.uuidString])
        var metadataRows = fixtures
        func metadataOnly(_ index: Int, _ item: NewPiTranscriptItem) async throws {
            let batches = page.applyCount
            metadataRows[index] = item
            page.coordinator.apply(transcript: metadataRows, isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
            try await settle()
            precondition(page.applyCount == batches + 1, "新增 metadata-only signature 必须下发且只应用一批")
            try await check("return metadataArticle===document.querySelector('[data-iid=\"'+id+'\"] article') && metadataCode===metadataArticle.querySelector('code');", ["id": answerA.id.uuidString])
            try await checkMessageCopies()
        }
        let strip = "document.querySelector('[data-iid=\"' + id + '\"] .result-strip')"
        try await metadataOnly(1, NewPiTranscriptItem(id: toolA.id, kind: .tool(name: "write", state: .running),
            body: toolA.body, fileChanges: [change], durationSeconds: 1.25))
        try await check("return \(strip).textContent.includes('工具成功 1 · 失败 1 · 未完成 1') && \(strip).textContent.includes('1 次 / 1 个路径');", ["id": answerA.id.uuidString])
        try await check("const t=document.querySelector('[data-iid=\"'+id+'\"]'); return t.querySelector('.card').dataset.status==='stopped' && t.querySelector('.card-badge').textContent==='已停止';", ["id": toolA.id.uuidString])
        try await metadataOnly(1, toolA)
        try await check("return \(strip).textContent.includes('工具成功 2 · 失败 1 · 未完成 0');", ["id": answerA.id.uuidString])
        try await metadataOnly(1, NewPiTranscriptItem(id: toolA.id, kind: toolA.kind, body: toolA.body,
            fileChanges: [], durationSeconds: 1.25))
        try await check("return \(strip).textContent.includes('1 次 / 1 个路径');", ["id": answerA.id.uuidString])
        try await metadataOnly(1, toolA)
        try await check("return \(strip).textContent.includes('2 次 / 1 个路径');", ["id": answerA.id.uuidString])
        try await metadataOnly(1, NewPiTranscriptItem(id: toolA.id, kind: toolA.kind, body: toolA.body,
            fileChanges: [change], durationSeconds: 2.25))
        try await check("return \(strip).textContent.includes('3.50 秒');", ["id": answerA.id.uuidString])
        try await metadataOnly(1, toolA)
        try await check("return \(strip).textContent.includes('2.50 秒');", ["id": answerA.id.uuidString])
        try await metadataOnly(5, NewPiTranscriptItem(id: answerA.id, kind: .assistant, body: rawAnswer, answerState: "incomplete"))
        try await check("return !\(strip) && document.querySelectorAll('.answer-footer').length===1;", ["id": answerA.id.uuidString])
        let incompleteCopies = page.copiedTexts.count
        _ = try await js("document.querySelector('[data-iid=\"'+id+'\"] .ti-action-copy').click(); answerCopy.click(); return true;", ["id": answerA.id.uuidString])
        try await settle()
        precondition(page.copiedTexts.count == incompleteCopies + 1 && page.copiedTexts.last == rawAnswer,
            "撤销 footer 后顶部恢复原文复制；旧 footer 的闭包不能回传")
        try await metadataOnly(5, answerA)
        let finalCopies = page.copiedTexts.count
        _ = try await js("document.querySelector('[data-iid=\"'+id+'\"] .answer-copy').click(); return true;", ["id": answerA.id.uuidString])
        try await settle()
        precondition(page.copiedTexts.count == finalCopies + 1 && page.copiedTexts.last == rawAnswer,
            "恢复 final 后只保留底部原文复制")
        try await metadataOnly(5, NewPiTranscriptItem(id: answerA.id, kind: .assistant, body: rawAnswer,
            answerState: "final", resultScopeID: "isolated-speech"))
        try await check("return \(strip).textContent.includes('本轮未调用工具') && !\(strip).textContent.includes('2 次');", ["id": answerA.id.uuidString])
        try await metadataOnly(5, answerA)
        try await check("return \(strip).textContent.includes('2 次 / 1 个路径');", ["id": answerA.id.uuidString])
        FileHandle.standardError.write(Data("PASS: metadata-only toolRunning/fileChanges/durationSeconds/answerState/resultScopeID signatures and footer dirty; article/code identity retained\n".utf8))

        // 更新真实 snapshot 才更新 diff；长内容保留 +/- 安全文本、限高，不执行命令。
        let long = ToolFileChange(path: "<img src=x>", before: nil, after: nil,
            diff: String(repeating: "+long <>&\n", count: 10000), isTruncated: true, note: "合成长 diff")
        let longTool = NewPiTranscriptItem(id: toolA.id, kind: toolA.kind, body: toolA.body, fileChanges: [long])
        page.coordinator.apply(transcript: [userA, longTool, answerA], isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        try await settle()
        _ = try await js("document.querySelector('.answer-changes').click(); return true;")
        try await settle()
        try await check("const d=document.querySelector('dialog'); return d.getBoundingClientRect().height<=innerHeight*.8+1 && d.getBoundingClientRect().width<=600 && !d.querySelector('img') && d.textContent.includes('展示已截断');")
        _ = try await js("document.querySelector('.changes-close').click(); return true;")
        try await settle()

        // 角色隔离：同用户下不同 speechID 不能借用彼此工具结果。
        let roomTool = NewPiTranscriptItem(kind: toolA.kind, body: "ok", fileChanges: [change], resultScopeID: "role-a:speech-a")
        let roomA = NewPiTranscriptItem(kind: .assistant, body: "A", speaker: "A", answerState: "final", resultScopeID: "role-a:speech-a")
        let roomB = NewPiTranscriptItem(kind: .assistant, body: "B", speaker: "B", answerState: "final", resultScopeID: "role-b:speech-b")
        page.coordinator.apply(transcript: [userA, roomTool, userB, roomA, roomB], isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        try await settle()
        try await check("const strips=[...document.querySelectorAll('.result-strip')]; return strips.length===2 && strips[0].textContent.includes('1 个路径') && strips[1].textContent.includes('本轮未记录文件编辑快照');")

        var unsupported = request
        unsupported.id = "preview-bash"
        unsupported.toolName = "bash"
        unsupported.arguments = .object(["command": .string("never execute this fixture")])
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: "preview-runtime",
            request: unsupported, workingDirectory: directory), after: roomB.id)
        try await settle()
        _ = try await js("document.querySelector('.approval-preview').click(); return true;")
        try await waitFor("document.querySelector('dialog[open]')")
        try await check("return document.querySelector('dialog').textContent.includes('不支持文件 diff 预览');")
        require(decisions.count == 1, "unsupported preview decisions=\(decisions.count), expected 1")
        _ = try await js("document.querySelector('.changes-close').click(); return true;")
        try await settle()

        // 点击不等于接受；拒收的原生回调和旧 void 回调都不能产生允许/拒绝成功回执。
        var rejectedCalls = 0
        page.coordinator.onApprovalAccepted = { _, _ in rejectedCalls += 1; return false }
        var rejectedRequest = request
        rejectedRequest.id = "native-rejected"
        let rejectedApproval = NewPiTranscriptApproval(runtimeIdentity: "rejected-runtime", request: rejectedRequest, workingDirectory: directory)
        page.coordinator.updateApproval(rejectedApproval, after: roomB.id)
        try await settle()
        let rejectedPayload = try await capturePreview()
        _ = try await js("const b=document.querySelector('.approval-primary');b.click();b.click();return true;")
        try await settle()
        require(rejectedCalls == 1, "单个审批真实按钮不能重复提交：rejectedCalls=\(rejectedCalls)")
        try await check("const r=document.querySelector('[data-iid=\"'+id+'\"]'); return r.dataset.outcome==='cancelled' && r.textContent.includes('未收到可确认') && !r.querySelector('button');", ["id": rejectedPayload["id"] as! String])
        var changedRequest = rejectedRequest
        changedRequest.summary += "同一请求的新展示字段"
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: "rejected-runtime", request: changedRequest, workingDirectory: directory), after: roomB.id)
        try await settle()
        try await check("return !document.querySelector('.ti-approval');")
        var replayDecision = rejectedPayload
        replayDecision["action"] = "approve"; replayDecision["scope"] = "once"
        _ = try await js("window.webkit.messageHandlers.transcriptApproval.postMessage(payload);return true;", ["payload": replayDecision])
        try await settle()
        require(rejectedCalls == 1, "已领取身份即使 metadata/nonce 更新也不能再次 approve：rejectedCalls=\(rejectedCalls)")
        page.coordinator.onApprovalAccepted = nil
        var legacyCalls = 0
        page.coordinator.onApproval = { _, _ in legacyCalls += 1 }
        var legacyRequest = request
        legacyRequest.id = "legacy-void"
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: "legacy-runtime", request: legacyRequest, workingDirectory: directory), after: roomB.id)
        try await settle()
        let legacyPayload = try await capturePreview()
        _ = try await js("document.querySelector('.approval-deny').click();return true;")
        try await settle()
        require(legacyCalls == 1, "legacyCalls=\(legacyCalls), expected 1")
        try await check("const r=document.querySelector('[data-iid=\"'+id+'\"]'); return r.dataset.outcome==='cancelled' && r.textContent.includes('未收到可确认');", ["id": legacyPayload["id"] as! String])
        page.coordinator.onApproval = nil
        page.coordinator.onApprovalAccepted = { decisions.append(($0, $1)); return true }

        // 非主 frame：生产 CSP 首先禁 frame，此处独立无 CSP 合成页验证 native 第二道守卫。
        var frameRequest = request
        frameRequest.id = "frame-only-request"
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: "frame-runtime", request: frameRequest,
            workingDirectory: directory), after: roomB.id)
        try await settle()
        let framePayload = try await capturePreview()
        page.loaded = false
        page.webView.loadHTMLString("<!doctype html><html><body>frame fixture</body></html>", baseURL: nil)
        for _ in 0..<300 {
            if page.loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var frameAllow = framePayload; frameAllow["action"] = "approve"; frameAllow["scope"] = "once"
        _ = try await js("const f=document.createElement('iframe'); f.srcdoc='<script>window.webkit.messageHandlers.transcriptApproval.postMessage('+JSON.stringify(payload)+')</script>'; document.body.append(f); await new Promise(r=>f.onload=r); return true;", ["payload": frameAllow])
        try await settle()
        require(page.approvalSubframeCount == 1 && decisions.count == 1,
            "approvalSubframeCount=\(page.approvalSubframeCount), decisions=\(decisions.count); both expected 1")
        page.coordinator.detach()
        try await post(frameAllow, count: 1)
        print("PASS: transcript approval DOM/scroll/editable input/live revocation/runtime identity/scopes/preview/process callback/mainframe/once; raw footer copy/per-turn snapshots/role isolation/escaping/long diff/cancel focus")
    }
}