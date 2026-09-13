import AppKit
import Foundation
import NewPiCore
import WebKit

private struct ApprovalE2EFailure: Error, CustomStringConvertible {
    let description: String
}

/// 全部检查在 -O 下仍抛出可读错误，不使用 assert/precondition/强制解包。
private func approvalE2ERequire(_ condition: Bool, _ message: String, line: UInt = #line) throws {
    guard condition else { throw ApprovalE2EFailure(description: "审批 E2E 第 \(line) 行：\(message)") }
}

/// 只有两次内存脚本响应；不创建网络 provider，不读取凭据，不调用自动命名服务。
/// 锁只保护请求记录，供主线程核对真实 AgentLoop 第二次请求包含工具结果。
private final class ApprovalE2EProvider: LLMProvider, @unchecked Sendable {
    let call: ToolCallContent
    let approved: Bool
    let finalText: String
    private let lock = NSLock()
    private var requests: [[AgentMessage]] = []

    init(call: ToolCallContent, approved: Bool) {
        self.call = call
        self.approved = approved
        finalText = approved ? "E2E：写入完成。" : "E2E：已拒绝，未执行写入。"
    }

    var recordedRequests: [[AgentMessage]] { lock.withLock { requests } }

    func stream(model: ModelConfig, systemPrompt: String, messages: [AgentMessage],
                tools: [ToolDefinition]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let ordinal = lock.withLock { requests.append(messages); return requests.count }
        return AsyncThrowingStream { continuation in
            do {
                try approvalE2ERequire(model.provider == "approval-e2e-fake" && tools.map(\.name) == ["write"],
                    "fake provider 只能收到专用模型和真实 write 工具，不能被用作命名/风险分类器")
                try approvalE2ERequire(messages.filter { if case .user = $0 { return true }; return false }.count == 1,
                    "第 \(ordinal) 次模型请求必须恰有一条用户消息")
                if ordinal == 1 {
                    try approvalE2ERequire(messages.count == 1, "首次请求不得混入历史或工具结果")
                    continuation.yield(.textDelta("准备写入，等待审批。"))
                    continuation.yield(.toolCall(call))
                    continuation.yield(.completed(stopReason: .toolUse, usage: UsageStats()))
                } else {
                    try approvalE2ERequire(ordinal == 2, "意外的第 \(ordinal) 次模型调用")
                    let results = messages.compactMap { message -> ToolResultMessage? in
                        if case let .toolResult(result) = message { return result }; return nil
                    }
                    try approvalE2ERequire(results.count == 1 && results.first?.toolCallID == call.id
                        && results.first?.toolName == "write" && results.first?.isError == !approved,
                        "AgentLoop 必须把真实允许/拒绝结果交给第二次模型请求")
                    continuation.yield(.textDelta(finalText))
                    continuation.yield(.completed(stopReason: .stop, usage: UsageStats()))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@MainActor
private final class ApprovalE2EScenario {
    let approved: Bool
    let root: URL
    let target: URL
    let sessionFile: URL
    let auditFile: URL
    let session: AgentSession
    let provider: ApprovalE2EProvider
    lazy var page = ColdPage()
    let deadline = ContinuousClock.now + .seconds(30)
    let before = "actual-before-at-execution\n"
    let after: String
    let external = "external-current-not-history\n"
    var requests: [ToolApprovalRequest] = []
    var pending: ToolApprovalRequest?
    var snapshots: [[AgentMessage]] = []
    var started: [String] = []
    var ended: [(String, ToolResult)] = []
    var decisions: [(String, ApprovalDecision)] = []
    var failure: String?
    var finished = false
    var responseCompleted = false
    var responseTask: Task<Void, Never>?
    var itemIDs: [Int: UUID] = [:]

    init(directory: URL, approved: Bool) throws {
        let projectRoot = directory.appendingPathComponent("project", isDirectory: true)
        let auditURL = directory.appendingPathComponent("approval-audit.jsonl")
        let content = "actual-after-from-write\n"
        let fake = ApprovalE2EProvider(call: ToolCallContent(id: UUID().uuidString, name: "write",
            arguments: .object(["path": .string("fixture.txt"), "content": .string(content)])), approved: approved)
        self.approved = approved
        root = projectRoot
        target = projectRoot.appendingPathComponent("fixture.txt")
        auditFile = auditURL
        after = content
        provider = fake
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let created = try SessionManager.createSession(workingDirectory: projectRoot,
            modelID: "approval-e2e-script", label: "隔离审批探针", root: directory.appendingPathComponent("sessions"))
        sessionFile = created.fileURL
        session = AgentSession(context: AgentContext(systemPrompt: "仅用于离线审批探针。", workingDirectory: projectRoot),
            config: AgentLoopConfig(model: ModelConfig(provider: "approval-e2e-fake", modelID: "approval-e2e-script"),
                llm: fake, tools: [WriteTool()], toolPolicy: .codingAgentDefault,
                compaction: CompactionConfig(enabled: false), maxTurns: 2,
                dangerEvaluator: DangerEvaluator(llmSupplementEnabled: false),
                projectScope: ProjectScopePolicy(root: projectRoot, isEnabled: false),
                auditLogger: ToolApprovalAuditLogger(fileURL: auditURL)))
    }

    func consume(_ event: AgentEvent) {
        switch event {
        case let .toolApprovalRequired(request): requests.append(request); pending = request
        case let .contextSnapshot(context): snapshots.append(context.messages)
        case let .toolExecutionStart(id, _, _): started.append(id)
        case let .toolExecutionEnd(id, _, result): ended.append((id, result))
        case let .error(error): failure = error.localizedDescription
        case .agentEnd: finished = true
        default: break
        }
    }

    /// 显式测试适配层，不冒称生产 NewPiViewModel 的事件接线/重建方法也已覆盖。
    /// 只投影实际 context/JSONL 消息；不手工生成 ToolFileChange 或 duration。
    func project(_ messages: [AgentMessage]) -> [NewPiTranscriptItem] {
        messages.enumerated().map { index, message in
            let id = itemIDs[index] ?? UUID()
            itemIDs[index] = id
            switch message {
            case let .user(user):
                return NewPiTranscriptItem(id: id, kind: .user, body: user.content,
                    messageIndex: index, timestamp: user.timestamp)
            case let .assistant(answer):
                return NewPiTranscriptItem(id: id, kind: .assistant, body: answer.text,
                    messageIndex: index, timestamp: answer.timestamp,
                    answerState: !answer.toolCalls.isEmpty ? "intermediate" : answer.stopReason == .stop ? "final" : "incomplete")
            case let .toolResult(result):
                return NewPiTranscriptItem(id: id, kind: .tool(name: result.toolName, state: .completed(isError: result.isError)),
                    body: result.content, timestamp: result.timestamp,
                    fileChanges: result.fileChanges, durationSeconds: result.durationSeconds)
            case let .compactionSummary(text):
                return NewPiTranscriptItem(id: id, kind: .summary, body: text)
            }
        }
    }

    func js(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page)
    }

    func wait(_ description: String, _ condition: @MainActor () async throws -> Bool) async throws {
        while ContinuousClock.now < deadline {
            if let failure { throw ApprovalE2EFailure(description: "\(description)：\(failure)") }
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ApprovalE2EFailure(description: "场景 30 秒期限内未完成：\(description)")
    }

    func waitDOM(_ expression: String) async throws {
        try await wait("等待 DOM：\(expression)") { try await self.js("return !!(\(expression));") as? Bool == true }
    }

    func checkDOM(_ source: String, _ message: String, _ arguments: [String: Any] = [:], line: UInt = #line) async throws {
        let result = try await js(source, arguments)
        try approvalE2ERequire(result as? Bool == true, "\(message)；DOM 返回 \(String(describing: result))", line: line)
    }

    func click(_ selector: String, text: String? = nil) async throws {
        try await checkDOM("""
            const buttons=[...document.querySelectorAll(selector)].filter(b=>!label || b.textContent===label);
            if(buttons.length!==1 || !(buttons[0] instanceof HTMLButtonElement) || buttons[0].disabled) return false;
            buttons[0].click(); return true;
            """, "必须点击唯一、启用的生产 DOM button：\(selector) \(text ?? "")",
            ["selector": selector, "label": text ?? ""])
    }

    func run() async throws {
        let stored = try JSONLSessionStore().load(from: sessionFile)
        await session.attachPersistence(fileURL: sessionFile, context: stored)
        let stream = await session.events()
        let collector = Task { @MainActor in
            for await event in stream {
                self.consume(event)
                if self.finished { return }
            }
        }
        defer { collector.cancel(); responseTask?.cancel(); page.close() }
        page.coordinator.approvalIsCurrent = { [weak self] in self?.pending != nil && self?.finished == false }
        page.coordinator.onApprovalAccepted = { [weak self] id, decision in
            guard let self else { return false }
            self.decisions.append((id, decision))
            guard self.pending?.id == id, decision == (self.approved ? .allowOnce : .deny) else {
                self.failure = "Coordinator 返回了错误 requestID 或非预期 scope/decision"
                return false
            }
            self.pending = nil
            self.responseTask = Task { @MainActor in
                // 真正恢复 AgentSession 私有 gate；不是记录回调后伪造完成快照。
                await self.session.respondToToolApproval(requestID: id, approved: decision.approved, scope: decision.scope)
                self.responseCompleted = true
            }
            return true
        }
        do {
            await session.prompt(.user("请写入 fixture.txt，等待我的审批。"))
            try await exercise()
            await session.shutdown()
        } catch {
            // 审批 gate 的 wait 不响应普通 Task.cancel；先 abort 解锁，再 shutdown。
            await session.abort()
            await session.shutdown()
            throw error
        }
    }

    private func exercise() async throws {
        try await wait("AgentSession.toolApprovalRequired") { self.pending != nil }
        guard let request = pending, let initial = snapshots.last else {
            throw ApprovalE2EFailure(description: "审批到达时缺少真实请求或 contextSnapshot")
        }
        try approvalE2ERequire(request.id == provider.call.id && request.toolName == "write"
            && request.arguments == provider.call.arguments && request.dangerLevel == .medium,
            "项目免批关闭后，相对路径 write 必须稳定触发中风险审批")
        try approvalE2ERequire(!finished && started.isEmpty && ended.isEmpty && provider.recordedRequests.count == 1,
            "待审批时不能执行工具或请求最终回答")
        let rows = project(initial)
        page.coordinator.updateApproval(NewPiTranscriptApproval(runtimeIdentity: storedIdentity,
            request: request, workingDirectory: root), after: rows.last?.id)
        page.load(rows, hues: [:], restore: nil)
        try await wait("ColdPage 加载真实 Coordinator 外壳") { self.page.loaded && self.page.applyCount > 0 }
        try await waitDOM("document.querySelector('.ti-approval .approval-approve')")
        try await checkDOM("""
            const card=document.querySelector('.ti-approval');
            return card.parentElement===document.querySelector('main') &&
              card.querySelector('.approval-summary').textContent===summary &&
              card.querySelector('.approval-title').textContent.includes('write') &&
              card.querySelector('.approval-directory').textContent.includes(root) &&
              document.querySelectorAll('.ti-user').length===1 && !document.querySelector('.answer-footer');
            """, "文档必须显示 Core 原始审批，只有一个用户条目且无提前完成 footer", ["summary": request.summary, "root": root.path])

        try approvalE2ERequire(!FileManager.default.fileExists(atPath: target.path)
            && !FileManager.default.fileExists(atPath: target.appendingPathExtension("new-pi.tmp").path)
            && decisions.isEmpty && started.isEmpty && ended.isEmpty && !finished && provider.recordedRequests.count == 1,
            "待审批不得创建文件、领取审批、执行工具或推进 AgentLoop")
        try approvalE2ERequire(page.approvalMessages.isEmpty, "用户决策前不得发送审批消息")
        try await checkRemovedActions()

        // 模拟审批等待时外部编辑：记录必须捕获实际执行时的文件内容。
        if approved { try before.write(to: target, atomically: true, encoding: .utf8) }
        try await click(approved ? ".ti-approval .approval-approve" : ".ti-approval .approval-deny",
            text: approved ? "允许一次" : "拒绝")
        try await wait("DOM 决策实际 await respondToToolApproval，并完成 AgentLoop") { self.responseCompleted && self.finished }
        try await waitDOM("document.querySelector('.ti-approval-receipt')")
        try await checkDOM("const r=document.querySelector('.ti-approval-receipt'); return r.dataset.outcome===outcome && !r.querySelector('button') && r.textContent.includes(text);",
            "只有 runtime 领取决策后才能显示允许/拒绝原位回执", ["outcome": approved ? "approved" : "denied", "text": approved ? "仅授权本次操作" : "未授予执行权限"])
        try approvalE2ERequire(failure == nil && requests.count == 1 && decisions.count == 1
            && decisions.first?.0 == request.id && decisions.first?.1 == (approved ? .allowOnce : .deny),
            "审批必须只领取一次并完成真实 Session 响应：\(failure ?? "无 Core 错误")")
        try approvalE2ERequire(page.approvalMessages.count == 1 && page.approvalSubframeCount == 0
            && page.approvalMessages.last?["action"] as? String == (approved ? "approve" : "deny")
            && page.approvalMessages.last?["requestID"] as? String == request.id,
            "只能有一次主 frame DOM 决策消息")
        if approved {
            try approvalE2ERequire(page.approvalMessages.last?["scope"] as? String == "once", "DOM 允许一次不能扩大 scope")
        }
        try approvalE2ERequire(started == (approved ? [request.id] : []) && ended.count == 1 && ended.first?.0 == request.id,
            "允许仅执行一次真实 write；拒绝不能发 toolExecutionStart，但必须有拒绝结果")
        try approvalE2ERequire(provider.recordedRequests.count == 2, "两场景均须基于工具结果生成最终 assistant")

        // 必须在 shutdown 之前读盘：证明最终 contextSnapshot 已经触发持久化。
        let disk = try JSONLSessionStore().load(from: sessionFile)
        let messages = SessionManager.messages(from: disk)
        let results = messages.compactMap { message -> ToolResultMessage? in
            if case let .toolResult(result) = message { return result }; return nil
        }
        guard let result = results.first, let eventResult = ended.first?.1,
              let finalSnapshot = snapshots.last else {
            throw ApprovalE2EFailure(description: "缺少 JSONL 工具结果、执行事件或最终快照")
        }
        try approvalE2ERequire(results.count == 1 && result.toolCallID == request.id && result.toolName == "write"
            && result.isError == !approved && result.content == eventResult.content
            && (result.fileChanges ?? []) == eventResult.fileChanges && result.durationSeconds == eventResult.durationSeconds,
            "落盘工具结果必须保留真实执行事件的状态、fileChanges 和 duration")
        for (source, history) in [("JSONL", messages), ("contextSnapshot", finalSnapshot), ("第二次模型请求", provider.recordedRequests.last ?? [])] {
            try approvalE2ERequire(history.filter { if case .user = $0 { return true }; return false }.count == 1,
                "\(source) 不得追加合成用户 Continue 消息")
            let tool = history.compactMap { message -> ToolResultMessage? in
                if case let .toolResult(value) = message { return value }; return nil
            }
            try approvalE2ERequire(tool.count == 1 && tool.first?.fileChanges == result.fileChanges
                && tool.first?.durationSeconds == result.durationSeconds, "\(source) 工具 metadata 必须与磁盘一致")
        }
        for (source, history) in [("JSONL", messages), ("contextSnapshot", finalSnapshot)] {
            guard case let .assistant(answer) = history.last else {
                throw ApprovalE2EFailure(description: "\(source) 缺少最终 assistant")
            }
            try approvalE2ERequire(answer.stopReason == .stop && answer.toolCalls.isEmpty && answer.text == provider.finalText,
                "\(source) 必须以 fake provider 的真实最终回答结束")
        }
        if approved {
            let content = try String(contentsOf: target, encoding: .utf8)
            guard let change = result.fileChanges?.first, let duration = result.durationSeconds else {
                throw ApprovalE2EFailure(description: "真实 write 未持久化文件快照或耗时")
            }
            try approvalE2ERequire(content == after && result.fileChanges?.count == 1 && change.before == before
                && change.after == after && change.beforeExists == true && !change.isTruncated
                && URL(fileURLWithPath: change.path).resolvingSymlinksInPath() == target.resolvingSymlinksInPath()
                && change.diff?.contains("-actual-before-at-execution") == true
                && change.diff?.contains("+actual-after-from-write") == true && duration.isFinite && duration > 0,
                "必须捕获执行时实际 before/after、真实路径和正数执行耗时")
            try external.write(to: target, atomically: true, encoding: .utf8)
            let history = SessionManager.messages(from: try JSONLSessionStore().load(from: sessionFile))
            let historicalChanges = history.compactMap { message -> [ToolFileChange]? in
                if case let .toolResult(value) = message { return value.fileChanges }; return nil
            }
            try approvalE2ERequire(historicalChanges == [result.fileChanges ?? []],
                "外部编辑不能改变已落盘的历史文件记录及 patch")
        } else {
            try approvalE2ERequire(!FileManager.default.fileExists(atPath: target.path)
                && (result.fileChanges ?? []).isEmpty && result.durationSeconds == nil && eventResult.fileChanges.isEmpty,
                "拒绝不得写文件、生成文件变更或冒充执行耗时")
        }

        // 此前只显示待审批快照；现在首次把磁盘工具 metadata 投影并发给生产 Coordinator。
        page.coordinator.updateApproval(nil, after: nil)
        page.coordinator.apply(transcript: project(messages), isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
        try await waitDOM("document.querySelector('.answer-footer .answer-copy') && !document.querySelector('.ti-approval')")
        try await checkDOM("return document.querySelectorAll('.ti-approval-receipt').length===1 && document.querySelector('.ti-approval-receipt').previousElementSibling.dataset.iid===anchor;",
            "工具结果和最终回答到达后，内存回执仍保持原审批锚点", ["anchor": rows.last?.id.uuidString ?? ""])
        try await checkDOM("""
            const strips=[...document.querySelectorAll('.answer-footer .result-strip')];
            return document.querySelectorAll('.ti-user').length===1 && document.querySelectorAll('.ti-tool').length===1 &&
              strips.length===1 && strips[0].textContent.includes(expected) &&
              strips[0].closest('.ti').querySelector('article').textContent.includes(answer);
            """, "磁盘投影必须显示本轮真实成功/拒绝统计及最终回答", ["answer": provider.finalText,
                "expected": approved ? "工具成功 1 · 失败 0 · 未完成 0" : "工具成功 0 · 失败 1 · 未完成 0"])
        if let duration = result.durationSeconds {
            try await checkDOM("return document.querySelector('.result-strip').textContent.includes(seconds+' 秒') && document.querySelector('.result-strip').textContent.includes('1 次 / 1 个路径');",
                "footer 必须显示真实 metadata 耗时与一次文件编辑", ["seconds": String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), duration)])
        }
        try await checkRemovedActions()
        if !approved {
            try await checkDOM("const text=document.querySelector('.result-strip').textContent; return !text.includes('文件编辑') && !text.includes('快照') && !text.includes('已记录工具耗时');",
                "拒绝后不得虚构文件记录或执行耗时")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let audit = try Data(contentsOf: auditFile).split(separator: 10).map { try decoder.decode(ToolApprovalAuditEntry.self, from: Data($0)) }
        try approvalE2ERequire(audit.count == 1 && audit.first?.callID == request.id && audit.first?.authorization == .prompted
            && audit.first?.decisionApproved == approved && audit.first?.decisionScope == .once,
            "临时审计必须证明 Core 走 prompted gate，未自动放行或扩大授权")
    }

    private func checkRemovedActions() async throws {
        try await checkDOM("return !document.querySelector('.answer-changes, .approval-preview, .changes-dialog, .icon-diff') && ![...document.querySelectorAll('button, [role=button]')].some(el=>['改动','查看改动','查看差异'].includes(el.textContent.trim()));",
            "审批和最终回答都不能恢复已删除动作")
    }

    private var storedIdentity: String { sessionFile.path }
}

extension TranscriptColdLoadChecks {
    /// Core + Coordinator 端到端；不直接使用生产 NewPiViewModel，不验证扩 scope。
    @MainActor static func checkTranscriptApprovalEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["NEWPI_APPROVAL_E2E_HOME"] else {
            throw ApprovalE2EFailure(description: "必须经 check-transcript-cold-load.sh 启动隔离 HOME；拒绝读取用户审批数据")
        }
        let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let expectedAgent = home.appendingPathComponent(".new-pi/agent").standardizedFileURL
        // AgentSession 内部创建默认 tracker，且覆盖传入 evaluator.policy；在创建前验证实际解析目录。
        try approvalE2ERequire(home.path.hasPrefix(temporary.path.hasSuffix("/") ? temporary.path : temporary.path + "/")
            && home.lastPathComponent == "ApprovalProbeHome" && environment["HOME"] == path
            && environment["CFFIXED_USER_HOME"] == path
            && NewPiConfig.defaultAgentDirectory.standardizedFileURL.resolvingSymlinksInPath().path == expectedAgent.path,
            "Foundation/Core 默认目录未被隔离到本次临时 HOME，停止探针")
        for name in ["approval-policy.json", "approvals.json"] {
            try approvalE2ERequire(!FileManager.default.fileExists(atPath: expectedAgent.appendingPathComponent(name).path),
                "隔离 HOME 不应存在预设 \(name)，不能依赖已有策略或授权")
        }
        for approved in [true, false] {
            let name = approved ? "allow-once" : "deny"
            let directory = home.appendingPathComponent("approval-e2e-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            // 独立进程 watchdog 也覆盖不能合作取消的 WebKit/actor await；不影响正式 App。
            let watchdog = DispatchWorkItem {
                FileHandle.standardError.write(Data("FAIL: Core+Coordinator E2E \(name) 超过 30 秒（含 await/清理）\n".utf8))
                exit(1)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 30, execute: watchdog)
            defer { watchdog.cancel() }
            do { try await ApprovalE2EScenario(directory: directory, approved: approved).run() }
            catch { throw ApprovalE2EFailure(description: "Core+Coordinator E2E \(name)：\(error)") }
            for file in ["approvals.json", "approval-policy.json"] {
                try approvalE2ERequire(!FileManager.default.fileExists(atPath: expectedAgent.appendingPathComponent(file).path),
                    "\(name) 不得创建或修改持久授权/策略文件：\(file)")
            }
            print("PASS: Core+Coordinator E2E \(name)；真实 DOM/Session gate/WriteTool/JSONL/footer；user count=1；无持久授权写入")
        }
    }
}