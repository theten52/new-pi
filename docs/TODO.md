# NewPi Development TODOs

当前待办与已完成项索引。2026-09-12 清理历史状态；`open` / `deferred` 表示仍需处理，
`待验收` 表示已有实现但未确认满足原始体验要求，`待复核` 不等于问题仍存在。
旧设计和审查证据保留在链接文档中，不能直接当作当前 backlog；分类入口见 [文档索引](README.md)。

## UI 后续 — 2026-09-12 A 文档工作台

### BACKLOG-DOCUMENT-WORKBENCH-ACCEPTANCE — 生产 UI 人工验收与最终验证回填

- **状态**：已实施 / 待验收；用户已选择 A。阅读列、共用输入区、静态状态与真实可空用量 popover 已调整，不重写模型/权限逻辑或单文档架构。
- **验证边界**：WK 19 语义、4 final geometry 零差与浅深 × 900/701/700/480 的 8 组样式/对比度检查、composer marked text、完整 Debug build 已报告通过；统一横向 24 后最终 WK/Debug 复跑结果待主 agent 回填。
- **真实组件 probe**：900/620 × 浅深四张合成截图；结果 **PARTIAL，9 项 AX SKIP**。键盘与 DOM 独立 PASS，不能称发送/停止按钮或用量 popover 点击通过；strict 下 SKIP 会失败。
- **仍需**：实际 App 侧边栏/聊天室切换、手动 phase、插话/停止、popover、模型、附件与焦点验收；Web 高对比未完整验收。本轮 cold/performance 结果待主 agent 填写，不预写全部通过。
- **范围**：侧边栏与设置导航未全面重写，真实 diff 面板未实现，原型仅作设计对照。详见 [实施与验收记录](dev-notes/2026-09-12-document-workbench-ui.md)。

## 渲染后续 — 2026-09-11 Markdown 结束时小幅跳动

### BACKLOG-MARKDOWN-FINAL-REFLOW — 流式与最终 Markdown 结构不一致

- **状态（2026-09-12）**：语义分块导致的已复现问题已修复；用户原始场景仍待验收。
- **用户反馈**：提示“输出一个 markdown，我在测试 markdown 渲染，不要使用代码围栏包围”时，
  结束阶段必现约一行的小幅跳动。与上一轮正文/工具交替的 160px 人工占位问题分开跟踪。
  反馈时仓库为 `f88a5b1`；尚未核实运行中 App 的版本和该次生成正文的精确内容。
- **修复前证据（保留）**：旧 `splitBlocks` 按空行切分，可能把同一个松散列表拆成多个独立列表；
  `renderFinal` 再全文解析为单个含 `li > p` 的列表，触发不同的边距和高度。
  真实 WKWebView 对相同 source 的检查中，三项空行分隔有序列表结束时正文高度 **77 → 103px**；
  收尾钉底使 `scrollY` **701 → 727px**，实际形成 **26px** 的滚动位移。
- **边界**：14 个合成样例中，普通段落、标题、紧凑列表、简单表格、单围栏代码等没有高度差；
  因而不能推断“所有非围栏 Markdown 都必现”，也未证明用户该次输出一定是同一原因。
- **已修复**：流式全文 `markdown.parse` 后按 `nesting` 分顶层 token，直接 `renderer.render`；
  保留 DOM 冻结前缀与单围栏 Text 追加，reference 环境变化时失效；源片段保留尾换行，
  repair 仅限末尾有 `map` 的 inline 叶子，EOF 围栏交给 parser。不改 CSS、滚动或原生布局，不接入 HTML replay。
- **已运行验证**：真实 WKWebView 19 个语义用例全部通过，含字符级与一次性流式对照；
  松散有序/无序列表、嵌套列表、引用四类收尾 `heightDelta=0`、`scrollDelta=0`，32px 尾距与上翻锚点保持。
  100 块仍为 199 次插入、200 行单围栏仍为 0 次子树重建；原生 200 行三轮对照无该场景明显退化，
  500 条历史首载/切回、聊天室 A/B/A 及进程恢复回归通过。不是严密性能统计，也不代表完整 App 验收。
- **剩余边界**：用户原始那次精确正文与运行版本未保存，仍待原场景验收；全文 parse 每次 O(n)，
  连续增长的累计成本需大型样本观察。嵌套围栏 DOM 细粒度优化、未闭合 inline 最终还原产生的重排不在本次保证内。
- **详细记录**：[2026-09-12 修复与验证](dev-notes/2026-09-12-markdown-final-reflow.md)；
  原始证据与最小复现保留于 [性能复核 §16](dev-notes/2026-09-11-long-session-rendering-review.md#16-非围栏-markdown-结束时约一行跳动待修复)。

## 性能后续 — 2026-09-11 多轮测试（暂缓实施）

用户要求先记录，后续再处理。以下证据来自 09:11–09:25 的测试与同机对照，不表示已修复。

### BACKLOG-SHELL-STARTUP — 优化登录 shell 的重复启动成本

- **状态**：open / deferred；优先于下面的工具参数打点。
- **现象与证据**：23 次 bash 调用累计 13.03s，单次多数为 0.48–0.75s。
  使用无操作命令 `:` 各测 5 次，`zsh -lc ':'` 中位数 512ms，
  `zsh -c ':'` 为 10ms，`zsh -fc ':'` 为 9ms。最后一轮任务的 9 次 bash 调用累计约 5s。
- **代码入口**：[BashTool](../Packages/NewPiCore/Sources/NewPiCore/Tools/BuiltInTools.swift)
  每次执行都会新建 `/bin/zsh -lc`。对照支持“当前机器的登录 shell 初始化有明显固定成本”，
  不代表所有机器都有同样耗时，也尚未定位具体启动配置。
- **后续方向**：评估如何减少重复环境初始化，同时保留 PATH、版本管理器、工具查找、
  工作目录与环境覆盖行为；不能直接删除 `-l` 后就认定等价，也不预先决定复用常驻 shell。
- **验收**：相同环境下对照空命令与真实多工具任务的启动/总耗时；验证命令可用性、
  超时/取消、退出码与输出捕获，避免环境或命令状态跨调用意外泄漏。

### BACKLOG-TOOL-ARGUMENT-TIMING — 补工具参数生成阶段打点

- **状态**：open / deferred。
- **现象与证据**：09:23:54 发起的一次 Responses 请求，正文停止后约 4.4s 才结束；
  终态为 `toolUse`，包含一个 `write` 调用，正文仅 85 字符但总输出为 1392 tokens。
  这段时间可能在生成工具参数，**不能仅凭无正文就判定为服务端静默或 UI 卡顿**。
- **已有能力**：发送到首字的 runID 时间线、正文末次 delta、text done 和请求终态已经记录，
  见 [API 指标设计](api-metrics-design.md)。不重做这些已有打点。
- **待补充**：按 API 请求及工具调用标识关联参数首个 delta、最后 delta、arguments done，
  并记录事件数/长度；与正文、请求终态和实际工具执行边界分开。
  入口：[ResponsesSSEDecoder](../Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesSSEDecoder.swift)、
  [ResponsesAPIProvider](../Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesAPIProvider.swift)、
  [RequestLatencyTrace](../Packages/NewPiCore/Sources/NewPiCore/Diagnostics/RequestLatencyTrace.swift)。
- **边界与验收**：日志不记录参数正文、文件内容或凭据，不逐 token 写日志；覆盖多个工具调用、
  多轮请求、子 Agent、无 delta 直接 done、错误与取消。已有 run 级阶段只记首次，
  不能将后续请求的工具参数时间混入首个请求；不得改变完成语义或提前执行不完整参数。

## Phase 4 — Session persistence

| ID | Item | Status | Notes |
|---|---|---|---|
| P4-UI | Sidebar session list + resume | done | Phase 4b/c |
| P4-BRANCH | Branch/fork UI for tree sessions | done | Fork from transcript row |
| P4-RESUME-PROVIDER | Restore provider profile from session header on resume | done | 恢复会话时读取 header 中的 profile |
| P4-CLI | CLI session commands | done | `new-pi sessions list/show/export` |
| P4-AUTO-RESUME | 打开 App / 项目时自动恢复上次离开时的 Session | done | `NewPiLastSessionStore` 按项目记录最后活跃会话；`openProject` 后 `restoreLastSessionIfPossible` 恢复；归档当前会话时清除记录 |

## Phase 8 — Advanced session & agent

| ID | Item | Status | Notes |
|---|---|---|---|
| P8-EXPORT | Export transcript/session | done | Markdown/JSON/text; App + CLI |
| P8-SUBAGENT | 子 agent 任务委派 | done | `subagent` 继承审批链；工具批次当前逐个执行，真实并行调度未实现 |

## Phase 5 — 已完成

| ID | Item | Status | Notes |
|---|---|---|---|
| P5-AGENTS | AGENTS.md loader | done | `.new-pi/AGENTS.md` then project root |
| P5-SKILLS | Swift Skills protocol + SKILL.md loader | done | `~/.new-pi/agent/skills/`, `.new-pi/skills/` |
| P5-COMPACT | Context compaction | done | `CompactionService` before each turn |

## Phase 6 — UI polish

| ID | Item | Status | Notes |
|---|---|---|---|
| P6-PROVIDER-PICKER | In-chat provider switch | done | Sidebar picker, preserves session |
| P6-TEST-CONN | Settings "Test provider" button | done | Provider 设置中测试连接 |
| P6-MARKDOWN | Transcript markdown rendering | done | 当前正文统一使用单文档 WebView，AttributedString 仅为早期里程碑 |
| P6-MARKDOWN-WEB | WKWebView markdown + streaming | done | 单文档迁移已完成；结束时重排问题单独跟踪 `BACKLOG-MARKDOWN-FINAL-REFLOW` |

## Phase 6c — 旧 per-message 滚动待办（已归档）

`UX-REBUILD-ID`、`UX-HEIGHT-CLIP`、`UX-SCROLL-MONITOR`、`UX-FLUSH-HEIGHT-RACE`、
`UX-FLUSH-SHRINK`、`UX-SCROLL-BODY`、`UX-THINKING-LAYOUT`、`UX-NC-COUPLING`
来自旧原生列表与逐消息 WebView 路径，不再按原方案排期。
历史问题与证据见 [2026-08-26 记录](dev-notes/2026-08-26-streaming-markdown-scroll-ux.md)，
当前滚动边界见 [UI 架构 ADR](ui-architecture-decision.md)。这不表示所有新架构视觉问题都已解决，
仍需跟踪本文的 final reflow 与冷恢复体验条目。

## Credentials / debug

| ID | Item | Status | Notes |
|---|---|---|---|
| CRED-DEBUG-STORE | UserDefaults-first API key storage | done | AIChatMac-style; Keychain opt-in via Settings |
| CRED-DEV-ENV | Development `.env` loader | done | `NEW_PI_ENV_FILE` or repo-root `.env` |

## Phase 7 — From AIChatMac learnings

| ID | Item | Status | Notes |
|---|---|---|---|
| P7-LOGS | In-app debug logs | done | `NewPiLogger` + Logs sheet |
| P7-UX | Chat UX polish | done | empty state, auto-scroll, copy, bubbles |
| P7-MCP | MCP client | done | stdio MCP + Settings UI |

## 功能状态 — 待办与已完成项

> 2026-09-12 展示更新：下表 `BACKLOG-TOKEN-BAR` 的内联用量/tooltip/Divider 描述保留为历史实施记录；当前为静态主状态与五项可空用量 popover，数据逻辑未改，交互待验收见上方工作台条目。

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-TOKEN-BAR | 状态栏显示当前对话的 token 用量 | done | P1 | 已实现：`SessionRuntime` 新增 `totalUsage`/`lastTurnUsage`（@Published），`messageEnd(.assistant)` 时累计；冷恢复由历史消息的 usage 重建（`accumulateUsage`）；输入框上方状态栏右侧显示累计 `↑输入 ↓输出`（紧凑格式，tooltip 含最近一轮明细）+ 缓存命中率（⚡xx%，`UsageStats` 新增 cacheRead/cacheCreation 字段，Anthropic/OpenAI 兼容/Responses 三个 provider 均已解析，含 DeepSeek `prompt_cache_hit_tokens` 变体；旧 JSONL 解码兼容缺省 0）。另：状态栏与输入框间的 Divider 移到状态栏上方。注意：OpenAI 兼容 provider 流式原本不报 usage（REV-PROV-6），需端点支持才显示。 |
| BACKLOG-SESSION-HOVER-GLASS | Session 列表鼠标悬浮玻璃高亮效果 | 待验收 | P2 | `NewPiApp.swift` 的 `SessionRow` 已有 `onHover`、`thinMaterial` 与描边；不再作为缺失功能，剩余工作为确认视觉效果符合要求。 |
| BACKLOG-BUBBLE-BG | 输入/输出气泡背景色一致并可区分 | superseded by A | P2 | 2026-09-12 用户选择 A 文档工作台：assistant 无彩色底、user 左对齐中性底；旧按 turn 分色要求被取代，保留 ID，不再按彩色气泡验收。tint 数据通道保留不等于仍以彩色底板展示；见 [实施记录](dev-notes/2026-09-12-document-workbench-ui.md)。 |
| BACKLOG-THINKING-COLLAPSE | 思考过程默认折叠，提供按钮手动展开查看 | done | P2 | 已实现并归并到 `BACKLOG-FOLD-THINKING-TOOL`；JS 卡片保留手动展开状态，不再重复排期。 |
| BACKLOG-SESSION-AUTO-SELECT | 存档/删除 session 后自动切换到下一个 session | done | P2 | 已实现：`archiveSession` 归档当前会话后自动切到同项目列表中的下一条（优先下面一条，末条则回退到最新一条）；同项目无更多会话时保持空态。「下一个项目」暂未实现（App 是单项目模型，无项目列表概念）。 |
| BACKLOG-SESSION-RELOAD-SCROLL-JUMP | 重新加载 Session 时 loading 结束后滚动条跳动 | open | P2 | 已有后台恢复、generation 防竞态、首批 `restoreAnchor` 和文档内逐帧校正；不能再按“缺少锚点恢复”处理。仍需复验冷加载遮罩消失后的稳定性，代码存在不代表体验问题已关闭。入口：`NewPiViewModel.swift`、`NewPiTranscriptDocumentView.swift`、`transcript-document.js`；见 [冷加载记录](dev-notes/2026-09-11-transcript-cold-load.md)。 |
| BACKLOG-SESSION-MANUAL-CREATE | 新 Session 由用户手动创建，系统不自动新建 | done | P1 | 打开项目和更改 provider 不自动新建会话；恢复已有会话不属于新建。归档后的选择行为见 `BACKLOG-SESSION-AUTO-SELECT`，无剩余会话时回到空态。 |
| BACKLOG-DEFAULT-PROVIDER | 新增默认 Provider 设置，新建 Session 默认使用该 Provider | done | P1 | 已实现：Settings「Default Provider」picker 语义改为「Default for new sessions」并加说明（只影响新建会话）；侧边栏 Provider 区新增「Set as Default」快捷入口（当前会话 provider ≠ 默认时显示）；默认 provider 不影响已有会话，会话内切换随 header 逐会话记忆并立即落盘。 |
| BACKLOG-FORK-COMPACT-HISTORY | fork + compaction 叠加时，被压缩历史无法在 fork 后恢复 | open | P2 | **已知限制（方案 A 已接受）**：对话先触发 compaction（历史被 summary 取代，`context.messages` 只剩 `[summary] + 最近8条`），随后用户 fork。fork 路径保留 `rebuildTranscript` 全量重建，但此时 `context.messages` 已不含被压缩的完整历史，重建后那段历史只剩 summary 占位、无法恢复。根治需把完整 transcript 独立落盘（不依赖 `context.messages`），或 fork 时合并 `runtime.transcript` 的存量完整历史。当前主流程（单分支长对话）已由方案 A 修复（agentEnd 就地校准、不再清空重建），本条仅针对罕见的 fork+compaction 叠加。 |

## Backlog — 对话流滚动

| ID | Item | Status | Notes |
|---|---|---|---|
| BACKLOG-SCROLL-LAG | 旧原生列表滑动不跟手 | closed / obsolete | 旧窗口化、高度表与多个原生滚动机制已删除；历史分析见 [旧滚动笔记](dev-notes/chat-scroll-layout.md)。新单文档路径的性能问题应按新证据单列，不恢复旧路径。 |

## Backlog — 状态栏

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-STATUS-READY-LAG | 状态栏从 working/writing 翻回 ready 比正文完成晚数秒 | done | P2 | 现象：正文输出完毕、气泡光标已提前消失（streamingBubbleComplete）后，状态栏仍等 `agentEnd` 才翻回 ready；agentEnd 排在流式积压与收尾事件（messageStart/messageEnd/contextSnapshot×2/persist）之后，每一步主线程渲染提交 ~1s，累计晚 2-6s。**已实现（feat/agent-output-optimization）**：`SessionRuntime.finalAnswerComplete` —— messageEnd 且该 assistant 消息无工具调用时置位（有工具调用则后续还有 turn，不置位；textDelta/toolExecutionStart/agentStart 复位），`agentStatusPresentation` 在 `isStreaming && !finalAnswerComplete` 时才展示进行态。保守边界：只影响状态栏展示，isStreaming（Stop/composer/钉底）仍跟 agentEnd，无并发风险。原分析：方向：状态跟 messageEnd 走（「正文完成即 finishing」，工具调用/多轮场景需区分）。涉及 `NewPiViewModel.handle`、`agentStatusPresentation`。 |

## Backlog — 输入框

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-HISTORY-COUNT | 历史记录展示条数由 5 条改为 7 条 | cancelled | P2 | 已决定不做，保留编号备查。 |
| BACKLOG-SHOWALL-INCREMENT | 点击 Show all 按钮时每次只多显示 5 条（增量展开） | done | P2 | 已实现：`showsAllSessions` 布尔开关改为 `sessionDisplayLimit` 计数器（默认 5，点击 Show all 每次 +5 封顶，Show less 收回默认；切项目重置）。见 `NewPiApp.swift`。 |
| BACKLOG-COMPOSER-MULTILINE | 多行输入框 | done | P1 | `NewPiComposerTextView` 使用 NSTextView，支持内部滚动、Return 发送、Shift+Return 换行及 IME 组词保护；后续输入法与流式交互核验见 [composer 记录](dev-notes/2026-09-11-composer-marked-text.md)。 |
| BACKLOG-STATUS-BAR | 状态栏位于输入框上方、正文之外 | done | P2 | `NewPiAgentStatusBar` 位于原生 composer 区域，已显示状态及 token 用量，不再作为未来扩展计划。 |
| BACKLOG-HOVER-BUTTON-DISAPPEAR | 鼠标放到 Copy / Fork 按钮上时消失 | done | P1 | 原生 `NewPiTranscriptRow` 的历史修复已随旧路径退出；当前操作按钮由单文档 JS/CSS 管理，不应再修改已删除的逐消息 hover 机制。 |
| BACKLOG-IMAGE-INPUT | 图片选择、拖拽、粘贴与移除 | done | P1 | 已实现草稿缩略图、预处理、会话附件落盘、三类 provider 编码和原生预览；发送前要求模型标记为支持图片。后续验证与限制见 [图片设计记录](multi-modal-vision-plan.md)，Snipaste 历史修复见 [粘贴记录](dev-notes/2026-08-31-snipaste-paste-fix.md)。 |

## Backlog — 思考过程 / 工具输出折叠

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-FOLD-THINKING-TOOL | 思考过程与工具输出统一折叠及预览 | done | P1 | thinking 已经由增量缓冲进入 transcript，冷恢复从 `reasoningContent` 重建；JS 的 thinking/tool 卡片默认折叠并保留手动展开状态。更高层的详情分组见 [详情折叠记录](detail-collapse-plan.md)。 |

## Code review 2026-08-27 — 历史审查索引

原始发现与当时行号见 [审查记录](dev-notes/2026-08-27-code-review-findings.md)。
以下核心条目于 2026-09-12 对照源码确认已有修复；本次为文档核对，未重跑测试，也不是完整安全审计。

| ID | 原问题 | 当前状态 | 源码依据 |
|---|---|---|---|
| REV-CORE-1 | 错误路径回滚上下文 | done | `AgentLoop.run` 在 do 外保留运行中的可变 context |
| REV-CORE-2 | Anthropic 跨块解析状态丢失 | done | `AnthropicSSEDecoder` / `AnthropicStreamParser` 持有事件、工具参数与终态状态 |
| REV-CORE-3 | MCP actor 同步读取死锁 | done | `MCPStdioTransport.startReadLoop` 使用 readabilityHandler + AsyncStream |
| REV-CORE-4 | SubAgent 绕过审批 | done | `SubAgentTool` 透传 policy、审批回调、危险评估、tracker 和审计 |
| REV-CORE-5 | Compaction 后持久化失效 | done | `SessionManager.syncMessages` 写入 `.compaction` 屏障并挂载保留消息 |
| REV-CORE-6 | JSON 数字 0/1 被当作 Bool | done | `JSONValueDecoder.parse` 先通过 CFBoolean 类型判定 |
| REV-CORE-7 | 留空 API key 删除已存凭据 | done | `NewPiViewModel.saveProfile` 对空 key 跳过保存 |
| REV-CORE-8 | Bash 输出无限累积 | done | `BashTool.readPipe` 限制保留字节，超限后继续排空管道 |

以下分组尚未逐项重审，保留原优先级用于后续复核，不能笼统称为“仍未修复”或“全部关闭”：

| ID | 范围 | 状态 | 原优先级 |
|---|---|---|---|
| REV-SEC | SEC-1..8：危险规则、参数摘要、取消与授权 | 待复核 | P1 |
| REV-PROV | PROV-1..9：凭据边界、存储、超时与 thinking 兼容 | 待复核 | P1 |
| REV-MCP | MCP-1..7：协议、分帧、通知、环境与生命周期 | 待复核 | P1 |
| REV-UI | UI-1..9：项目切换、runtime 生命周期和状态展示 | 待复核 | P2 |
| REV-TEST | TEST-1..6：测试隔离与覆盖范围 | 待复核 | P2 |

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
