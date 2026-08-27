# 2026-08-27 全仓库代码审查发现

对全部约 2.3 万行代码（`Packages/NewPiCore`、`NewPiApp`、测试）的并行人工审查结果。严重级问题均已回读源码二次确认。按领域分组，每条含位置证据与修复方向。

## 严重

### CORE-1 Agent 出错时整个会话被回滚丢失
- 位置：`Packages/NewPiCore/Sources/NewPiCore/AgentLoop.swift:17,113-134`
- `var context = context` 声明在 `do {}` 块内部，三个 `catch` 分支里的 `.contextSnapshot(context)` 引用的是 run 开始前的函数参数。LLM 失败或超 maxTurns 时，`AgentSession.prompt`（`AgentSession.swift:88-93`）无条件应用该快照并 `persistIfNeeded()`，已提交的用户消息和已完成轮次从内存和磁盘一并抹掉。
- 修复：把 `var context = context` 移到 Task 闭包顶层、`do` 之前。

### CORE-2 Anthropic 流式解析跨块状态丢失，工具调用实际不工作
- 位置：`Anthropic/AnthropicProvider.swift:163-166`（`openToolBlocks` 是 `decodeLines` 的函数局部变量）、`:334-335`（生产路径按 SSE 块逐个调用）
- `content_block_start` 与 `input_json_delta`/`content_block_stop` 永远落在不同块里，`openToolBlocks[index]` 恒为 nil → 永不发出 `.toolCall` 事件 → Anthropic 下 agent 永不执行工具。`AnthropicStreamParser.parse`（:134）每次调用都无条件发 `.completed`，末块会把 stopReason 重置为 `.stop`、usage 清零。
- 现有测试一次性喂全部行（`AnthropicProviderTests.swift:57,87`），恰好绕开此 bug。
- 修复：decoder/parser 改为跨块有状态实例；补按块喂入的集成测试。

### CORE-3 MCP stdio 传输在 actor 上同步阻塞读，实际死锁
- 位置：`MCP/MCPStdioTransport.swift:143-157`（`readTask = Task { ... stdout.availableData ... }`）
- `MCPStdioTransport` 是 actor（:33），`Task {}` 继承 actor 隔离，`availableData` 是同步阻塞调用。服务器空闲时读循环占死 actor，`send()`/`receiveResponse()` 排队 —— MCP 握手即卡死。stderr 循环（:160-179）同理且句柄未保存，`close()` 无法取消它。测试全走 `MockMCPTransport`，真实路径零覆盖。
- 配套问题：`receiveResponse`（:88-106）超时任务抛错后 task group 仍需等 waiter 子任务完成，而 waiter 挂在 continuation 上无法被 cancel —— 超时形同虚设；超时后僵尸 waiter 留在队列里消费后续响应，配对错位。
- 修复：读循环改 `Task.detached` + `readabilityHandler`/DispatchSource；超时按 id 移除 waiter 并 resume throwing。

### CORE-4 子代理完全绕过审批和危险评估
- 位置：`Tools/SubAgentTool.swift:78-84`
- 子代理的 `AgentLoopConfig` 硬编码 `toolPolicy: .allowAll`，不传 dangerEvaluator/approval tracker/审批回调。用户对 `subagent` 点一次允许（baseline 仅 `.medium`，可被 forever 持久化），子代理即可无提示执行任意 bash。工具描述写 "investigate or execute"，实际持有可写 BashTool。
- 修复：子代理 bash 调用回调主会话审批链，或至少强制接上危险评估且 high 级拒绝。

### CORE-5 Compaction 触发后会话持久化静默失效
- 位置：`Sessions/JSONLSessionStore.swift:427-428` + `Compaction/CompactionService.swift:43` + `AgentSession.swift:256`
- compaction 把消息数组换成 `[summary] + toKeep`（变短且首元素变化），`syncMessages` 的两个 guard（count 比较 + prefix 比对）从此永远失败、静默 return。压缩点之后所有新消息不再落盘，重启即丢失，无报错（`try?` 吞掉）。
- 修复：compaction 时向持久化分支追加 `.compaction` entry 并更新 leaf，而非用纯追加 diff 模型同步被改写的数组；sync 失败至少记日志。

### CORE-6 JSON 数字 0/1 被错误解析为 Bool
- 位置：`JSONValue+Codable.swift:49-52`
- `case let bool as Bool` 排在 `case let int as Int` 之前；NSNumber 桥接使 JSON `0`/`1` 永远命中 bool 分支（已用 Swift 实际验证）。工具参数、MCP 消息中取值 0/1 的字段类型被破坏，round-trip 后 JSON 内容改变。
- 修复：先用 `CFGetTypeID(number) == CFBooleanGetTypeID()` 判定真布尔（:55-57 已有此检查但到不了），把 `as Bool` 分支移到其后。

### CORE-7 编辑 Provider 留空 API Key 会删除已保存凭据
- 位置：`NewPiApp/NewPiViewModel.swift:382` + `Providers/ProviderCredentialResolver.swift:66-72`
- UI 写 "Leave blank to keep the existing key."，但 `saveProfile` 无条件调 `saveAPIKey`，resolver 对空字符串执行 `store.delete`。只想改模型名就点保存，key 被静默删除。
- 修复：空 draft 跳过 `saveAPIKey`；或 resolver 空值语义改 no-op，另提供显式删除。

### CORE-8 Bash 输出无内存上限
- 位置：`Tools/BuiltInTools.swift:377-381`
- 先 `readDataToEndOfFile()` 再 `prefix(maxBytes)` 截断。`yes`、`find /` 等可秒级产生 GB 输出，App OOM。`maxOutputBytes`（256KB）安全预期不成立。
- 修复：`readabilityHandler` 或循环 `read(upToCount:)` 增量读取，达上限后截断。

## 中等

### 安全策略（Tools/）
- **SEC-1** `ApprovalPolicy.swift:55`：`\$` 在 NSRegularExpression 中是字面美元符非行尾锚点，"删除根目录"规则永不命中（`rm -r /` 只按 medium 处理）。
- **SEC-2** `ApprovalPolicy.swift:62`：`#"(?i)\bshutdown|reboot|halt\b"#` 分组优先级错误，`\b` 不作用于 `reboot`，误报 "rebootstrapped" 等。
- **SEC-3** 参数别名绕过评估与审批摘要：bash 执行端接受 `cmd`/`script`（`BuiltInTools.swift:295`），read/write/edit 接受 `file_path`/`filePath`，但 `DangerEvaluator.swift:71,124-137` 与 `ToolPolicy.swift:57-89` 只读 `command`/`path` —— 高危命令降级为 medium 且审批弹窗显示 `?`。修复：评估/摘要/执行共用同一份参数解析。
- **SEC-4** 原文正则的危险检测对 shell 混淆天然可绕过（`r\m -rf`、`$(printf 'rm')`、变量间接等）。应在文档/注释声明为 best-effort 而非安全边界。
- **SEC-5** "一直允许"审批全局生效不区分工作目录（`PersistentApprovalStore.swift:9`，`ToolApprovalFingerprint` 不含 workingDirectory）。
- **SEC-6** session 级授权每工具只保留一条记录（`ToolPolicy.swift:97,138,145`），批准命令 B 会丢弃命令 A 的授权。
- **SEC-7** 危险评估缓存 key 不含 policy 版本（`DangerEvaluator.swift:26-37`），改策略后本次会话内不生效。
- **SEC-8** 审批等待不响应取消：`ToolPolicy.swift:186-198` 的 `wait` 无 cancellation handler，`AgentSession.prompt()`（:52-53）不像 `abort()` 那样 `cancelAll()`——已取消的 run 可被用户之后的"允许"复活并真正执行工具。修复：`prompt()` 取消旧 run 前 `cancelAll()`；execute 前加 `Task.checkCancellation()`。

### 文件工具（Tools/BuiltInTools.swift）
- **FILE-1** WriteTool 覆盖写非原子、无快照（:185-191）：remove 与 move 之间文件不存在；固定临时文件名并行互踩。建议 `write(to:atomically:)` + 覆盖前走 `EditSnapshotStore`。
- **FILE-2** WriteTool 缺 `content` 时静默写空文件（:169）。
- **FILE-3** write/edit 原子替换丢失原文件执行位与扩展属性（:185-191, :254）。
- **FILE-4** EditTool 读-改-写 TOCTOU（:242→:254），静默覆盖外部修改。
- **FILE-5** BashTool 超时只 SIGTERM 主进程不杀进程组（:331-337），孙进程成孤儿；阻塞式管道读取任务永久泄漏。
- **FILE-6** `EditSnapshotStore` 快照名秒级冲突（同秒同文件编辑第二次直接失败）且永不清理；快照写入项目内 `.new-pi/snapshots` 污染用户仓库。
- **FILE-7** `timeout_seconds` 无上限校验（:296）。

### Provider / 凭证（Providers/、Anthropic/、Credentials/）
- **PROV-1** `OPENAI_API_KEY` env 会被发给任意 openaiCompatible 端点及内置 DeepSeek 预设（`ProviderPreset.swift:118,166,185`，`ProviderCredentialResolver.swift:47-52`）。env 应只绑定原生 preset。
- **PROV-2** Keychain 开关打开后 UserDefaults 仍留明文副本（`LayeredCredentialStore.swift:40-43`）。
- **PROV-3** Anthropic thinking budget 可等于 maxTokens（默认均 8192）必 400（`AnthropicProvider.swift:283-288,377-385`）。
- **PROV-4** Anthropic 多轮回放丢弃 thinking blocks，开启 thinking 第二轮起 400（`AnthropicProvider.swift:64-87`）。
- **PROV-5** 三个 provider 流式请求无任何超时（默认 resource timeout 7 天），服务端挂起即永久卡住。
- **PROV-6** OpenAI 兼容流未发 `stream_options.include_usage` 且跳过空 choices chunk，token 用量恒为 0（`OpenAICompatibleProvider.swift:275-284,192`）。
- **PROV-7** Responses API 回放 reasoning item 类型写 `reasoning_text`（应为 `summary_text`）且无 id/encrypted_content，严格端点可能 400（`ResponsesMessageEncoder.swift:13-21`，待真实端点验证）。
- **PROV-8** 静默端点回退：缺 baseURL 时悄悄连 `api.openai.com`/`api.deepseek.com`（`OpenAICompatibleProvider.swift:24-25`、`ResponsesEndpoint.swift:19-21`）。
- **PROV-9** 工具参数 JSON 解析失败静默降级为空对象（三个 provider 各一处），无日志。

### MCP（MCP/）
- **MCP-1** 子进程清理不可靠：SIGTERM→2s 后 SIGINT（非 SIGKILL），无 wait（`MCPStdioTransport.swift:109-132`）。
- **MCP-2** 子进程全量继承宿主环境变量，架空 `MCPSecretsResolver` 的按需注入（`MCPStdioTransport.swift:54-58`）。
- **MCP-3** 帧解码失败后 buffer 不丢弃且无大小上限（:181-193），一次坏帧永久卡死。
- **MCP-4** 服务器通知/请求被 FIFO 当作响应消费，一个无关通知打挂在途请求（:195-202）。
- **MCP-5** 声明协议版本 2024-11-05 却用 Content-Length 分帧（`MCPProtocol.swift:4` vs `MCPJSONRPC.swift:69-72`），与旧规范服务器握手失败。
- **MCP-6** 全局关闭 MCP 后已连接服务器的工具仍可调用（`MCPPluginManager.swift:106-113` guard 顺序错误）。
- **MCP-7** `reloadConfiguration()` 不清理已移除/改动的服务器连接（`MCPPluginManager.swift:59-61`）。

### 会话持久化（Sessions/、SessionStore.swift）
- **SES-1** 分支树对畸形数据不健壮：重复 entry ID 直接 runtime trap，父链成环死循环（`SessionStore.swift:121-132`）；entry ID 仅 32-bit（:90）。
- **SES-2** JSONL 单行损坏即整个会话不可加载，无容错（`JSONLSessionStore.swift:97-115`）；`listSessions` 一个坏文件让全部列表失败（:304-308）。
- **SES-3** `decodeSummary` 用子串匹配统计消息数可能误计（:169-173）；报错行号与真实行号不符（:97-98）。

### Agent 核心（AgentLoop/AgentSession/Compaction）
- **AGT-1** `ToolExecutionMode.parallel` 名不副实，实际串行（`AgentLoop.swift:421-429`）；取消时已成功工具的副作用结果被丢弃。
- **AGT-2** 压缩摘要失败终止整个 run（`CompactionService.swift:34-38` → `AgentLoop.swift:57-61`），叠加 CORE-1 还会回滚 context。应捕获后跳过本次压缩。
- **AGT-3** Token 估算对中文系统性低估约 4 倍（`ContextTokenEstimator.swift:31-32` 的 `count/4`），且漏算 `reasoningContent`（:17-23）——压缩触发过晚甚至不触发。
- **AGT-4** 会话持久化失败被 `try?` 静默吞掉无日志（`AgentSession.swift:261,213`）。
- **AGT-5** steering 消息只在有工具调用的轮次被消费，否则滞留队列混入下次 run（`AgentLoop.swift:95-101`）。
- **AGT-6** 审批通过后授权记录被写入两次（`AgentLoop.swift:325-332` 与 `AgentSession.swift:115-123`）。

### App UI（NewPiApp/）
- **UI-1** "输出截断提示"追加后立刻被 `rebuildTranscript` 全量重建擦除，永不显示（`NewPiViewModel.swift:875-877,943`）。
- **UI-2** `beginSession` 与切项目竞态：旧项目 session 成为活跃会话且 runtime 泄漏（`NewPiViewModel.swift:552-655` vs :259-266）。修复：构建完成后校验 projectURL。
- **UI-3** `refreshSessionList` 竞态：在飞的旧刷新覆盖新项目列表（:283-293）。
- **UI-4** `runtimes` 字典无上限增长（:637-639），旧 runtime 常驻不释放。
- **UI-5** 日志视图缓冲达 2000 上限后 count 不再变化，`onChange` 冻结（`NewPiLogsView.swift:72` + `NewPiLogStore.swift:48-49`）。
- **UI-6** 退出时 MCP 子进程可能残留：`applicationWillTerminate` 里 Task 未被等待（`NewPiApp.swift:6-10`）。应 `applicationShouldTerminate` 返回 `.terminateLater`。
- **UI-7** 用户主动 Stop 显示红色 "Error: Agent run was aborted."（`AgentSession.swift:132` + `NewPiViewModel.swift:881-882`），应特判为中性提示。
- **UI-8** 导出写盘错误被 `try?` 吞掉（`NewPiViewModel.swift:525`）。
- **UI-9** 流式期间所有可见行每 40ms 整体重渲染；`NewPiTranscriptItem` 未遵循 Equatable（`NewPiMarkdownText.swift:7,160`）。

### 日志（Diagnostics/）
- **LOG-1** 日志轮转只在启动/切项目时检查，运行期间 5MB 上限不生效（`NewPiFileLogSink.swift:51-67`）。
- **LOG-2** 项目 debug.log 含完整 prompt 写入用户仓库 `<project>/.new-pi/`，可能被提交进版本库（:28-32 + `NewPiLogger.swift:153-175`）。
- **LOG-3** 每行 open/close FileHandle 且每个 entry 写两个文件，I/O 开销大（`NewPiFileLogSink.swift:107-123`）。

### 测试（Tests/）
- **TEST-1** `NewPiLoggerTests.swift:66` 写真实 `~/.new-pi/agent/logs/`，可能轮转用户真实日志；测试结束后 sink 仍 enabled。
- **TEST-2** `ApprovalPermissionTests.swift:91`、`ApprovalPolicyReviewTests.swift:89` 读真实 `~/.new-pi/agent/approvals.json`，结果依赖开发者机器状态。
- **TEST-3** `CredentialStorageTests.swift:10,27,43,63` 每次运行往真实 Keychain 累积永不删除的项。
- **TEST-4** `BuiltInToolsTests.swift:150,164` 依赖 50ms sleep 时序；`gate.respond` 丢响应则永久挂起。
- **TEST-5** 覆盖缺口：14 条危险规则只测 2 条（缺规则 2 会立刻暴露 SEC-1）；无 shell 混淆绕过用例；PathResolver 无 symlink 逃逸测试；MCP 传输层零覆盖；SSE 无 malformed/边界用例。
- **TEST-6** `CredentialStorageTests.swift:99-100` `removePersistentDomain(forName: defaults.description)` 传错参数，清理是死代码。

## 轻微

- `CompactionConfig.triggerRatio` 无 0–1 校验（`CompactionConfig.swift:12-22`）。
- `LLMMessageConverter` 空 assistant 文本产生带前导换行/空 content（`LLMProvider.swift:47-57`），部分端点拒绝空 content。
- `requiredString` 拒绝纯空白值，edit 无法匹配纯空白 `old_string`（`BuiltInTools.swift:7-10,226`）。
- `ApprovalRiskRule.regex` 每次评估重新编译全部正则（`ApprovalPolicy.swift:15-17`）。
- PathResolver 校验与使用间存在理论 TOCTOU 窗口（`PathResolver.swift:39-44`，本地场景窗口很窄）。
- BashTool 全量继承宿主环境（`BuiltInTools.swift:315-319`），API key 对被执行命令可读。
- 审批策略开关只对新 session 生效，UI 无提示（`AgentSession.swift:28`）。
- `.env` 加载无 DEBUG 门控（`DevelopmentEnvFile.swift:18-31`）。
- 错误响应体逐字节无上限读取（三个 provider）。
- `SessionLabelService` 只截断 assistant 文本，超长 user 消息原样进 label 请求（`SessionLabelService.swift:50-58`）。
- `SessionHeader.version` 读入后从不校验（`SessionStore.swift:48`）。
- 弱断言：`projectHashStable` 无固定期望值、`exportJSON` 只断言非空、`newlineAtEnd` 只验证不崩溃。
- `AgentSessionShutdownTests.swift:90` `gate.wait()` 无超时兜底。

## 审查确认的良性部分

- PathResolver 的 `..`/符号链接/前缀校验防护正确。
- WKWebView Markdown 渲染链路（双重 JSON 编码、`</` 转义、CSP、`validateLink`、导航拦截）未发现可利用注入点。
- `SSEByteStreamParser` 字节级累积对跨 chunk 多字节 UTF-8 处理正确。
- `AgentMessageHistoryRepair.repairOrphanedToolCalls` 逻辑经推演正确。
- `Package.swift` / `project.pbxproj` 构建配置（Swift 6、StrictConcurrency complete、macOS 15）无实质问题。
