# NewPi Development TODOs

Tracked blockers and follow-ups discovered during autonomous development.

## Phase 4 — Session persistence

| ID | Item | Status | Notes |
|---|---|---|---|
| P4-UI | Sidebar session list + resume | done | Phase 4b/c |
| P4-BRANCH | Branch/fork UI for tree sessions | done | Fork from transcript row |
| P4-RESUME-PROVIDER | Restore provider profile from session header on resume | done |
| P4-CLI | CLI session commands | done | `new-pi sessions list/show/export` |

## Phase 8 — Advanced session & agent

| ID | Item | Notes |
|---|---|---|
| P8-EXPORT | Export transcript/session | done | Markdown/JSON/text; App + CLI |
| P8-SUBAGENT | Sub-agent / parallel tasks | done | `subagent` tool with approval |

## Phase 5 — Deferred

| ID | Item | Notes |
|---|---|---|
| P5-AGENTS | AGENTS.md loader | done | `.new-pi/AGENTS.md` then project root |
| P5-SKILLS | Swift Skills protocol + SKILL.md loader | done | `~/.new-pi/agent/skills/`, `.new-pi/skills/` |
| P5-COMPACT | Context compaction | done | `CompactionService` before each turn |

## Phase 6 — UI polish

| ID | Item | Notes |
|---|---|---|
| P6-PROVIDER-PICKER | In-chat provider switch | done | Sidebar picker, preserves session |
| P6-TEST-CONN | Settings "Test provider" button | done |
| P6-MARKDOWN | Transcript markdown rendering | done | AttributedString baseline |
| P6-MARKDOWN-WEB | WKWebView markdown + streaming | in progress | unified WebView + throttle; **换行/布局跳动未解决** — see dev-notes |

## Phase 6c — Streaming markdown / scroll UX (open)

See [`dev-notes/2026-08-26-streaming-markdown-scroll-ux.md`](dev-notes/2026-08-26-streaming-markdown-scroll-ux.md) for full context.

| ID | Item | Priority | Notes |
|---|---|---|---|
| UX-REBUILD-ID | Preserve transcript row UUID on `rebuildTranscript` | P0 | `agentEnd` remounts all WebViews → flash |
| UX-HEIGHT-CLIP | Fix streaming height clipping (threshold vs fixed frame) | P0 | Latest tokens invisible until height catches up |
| UX-SCROLL-MONITOR | Single shared scroll-wheel monitor for embedded WebViews | P1 | N monitors for N bubbles |
| UX-FLUSH-HEIGHT-RACE | Cancel `heightWorkItem` on flush | P1 | Stale streaming height after `agentEnd` |
| UX-FLUSH-SHRINK | Avoid bubble height snap-down on flush | P2 | Monotonic stream height vs final measure |
| UX-SCROLL-BODY | Scroll follow when height debounce blocks | P2 | Only height notification today |
| UX-THINKING-LAYOUT | Thinking indicator vs scroll stability | P2 | Product: always visible vs hide on output |
| UX-NC-COUPLING | Replace NotificationCenter scroll coupling | P3 | Prefer callback/`ObservableObject` |

## Credentials / debug

| ID | Item | Status | Notes |
|---|---|---|---|
| CRED-DEBUG-STORE | UserDefaults-first API key storage | done | AIChatMac-style; Keychain opt-in via Settings |
| CRED-DEV-ENV | Development `.env` loader | done | `NEW_PI_ENV_FILE` or repo-root `.env` |

## Phase 7 — From AIChatMac learnings

| ID | Item | Notes |
|---|---|---|
| P7-LOGS | In-app debug logs | done | `NewPiLogger` + Logs sheet |
| P7-UX | Chat UX polish | done | empty state, auto-scroll, copy, bubbles |
| P7-MCP | MCP client | done | stdio MCP + Settings UI |

## Backlog — 待实现功能

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-TOKEN-BAR | 状态栏显示当前对话的 token 用量 | P1 | 在 app 状态栏/工具栏展示当前会话累计的 input/output token。数据源：LLM 流式响应中的 `UsageStats`（见 `ModelTypes.swift`）与会话事件（`AgentSession.events()`）。需累计本回合/整个会话的总量，可同时显示本次与累计值；考虑与 `NewPiViewModel` 的统计状态集成。 |
| BACKLOG-SESSION-HOVER-GLASS | Session 列表鼠标悬浮玻璃高亮效果 | P2 | 鼠标移动到右侧（侧边栏）Session 列表项时，给出玻璃（glass / 毛玻璃）高亮效果。可参考 SwiftUI 的 `.glassEffect` 或自定义 `NSVisualEffectView` / `.background(.thinMaterial)`，实现悬浮态 hover 高亮。目标文件：`NewPiApp/NewPiApp.swift` 中的 `SessionRow`。 |
| BACKLOG-BUBBLE-BG | 对话气泡背景色（Agent 输出气泡 + 同对话同色 + 跨对话异色） | P2 | 对话气泡需要有背景色。用户输入气泡已有背景色，Agent（NewPi）输出气泡也需要有；**同一对话内**输入/输出气泡背景色需一致；**不同对话**之间的背景色需不一样，以方便区分。背景色随机生成，以浅色为主、视觉柔和。注意：是**气泡**的背景色，不是整个对话窗口的背景色。目标文件：`NewPiApp/NewPiChatView.swift` 与气泡渲染逻辑（用户输入气泡、`NewPiMarkdownText` / `NewPiMarkdownWebRenderer` 的 Agent 气泡）。 |
| BACKLOG-THINKING-COLLAPSE | 思考过程默认折叠，提供按钮手动展开查看 | P2 | 思考（thinking / reasoning）过程占据过多版面，考虑默认隐藏/折叠，提供按钮供用户手动点击展开查看。涉及 Agent 输出的 reasoning/thinking 内容在气泡中的展示逻辑，相关文件：`NewPiChatView.swift`、`NewPiMarkdownText.swift`（streaming 时 thinking 显示）、以及 `NewPiViewModel` 的思考增量处理。折叠态默认收起，展开后保持可再次收起。 |
| BACKLOG-SESSION-MANUAL-CREATE | 新 Session 只能由用户手动点击 New Session 按钮创建，系统不自动创建 Session | P1 | 当前 `NewPiViewModel.startNewSession()` 会在多个「自动」场景被触发，违背「仅用户手动建会话」的预期：`openProject(at:)`（打开项目后自动建）、`reloadProviders()`（`projectURL != nil` 时自动建）、`setDefaultProvider` / `saveProfile` / `deleteProfile`（切换/保存/删除 provider 后自动建新会话）、`archiveSession`（归档当前会话后自动新建），以及 `NewPiApp.swift` 里 `openProject` 相关路径。目标：让「New Session」成为唯一入口（按钮或快捷键），移除上述自动建会话行为；若某场景确实需要中断当前会话，改用「结束/停止当前运行」而非新建会话。涉及 `NewPiApp/NewPiViewModel.swift`（`startNewSession` 调用点）、`NewPiApp/NewPiApp.swift`。改动前确认 `resetSession`（重置会话）与 `startNewSession` 的语义需保留手动触发。 |

## Backlog — 对话流滚动

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-SCROLL-LAG | 对话流滑动不跟手 | P1 | 聊天列表滚动有滞后/不跟手手感。当前实现为「手动窗口化 + 高度表占位」（`TranscriptHeightMap`）+ `ScrollView` + `scrollPosition($jumpPosition)` + `ScrollViewReader.scrollTo` 多机制叠加，见 `docs/dev-notes/chat-scroll-layout.md`。需要：① 排查多种滚动机制是否互相干扰（dev-notes 明确警告「一种 scroll 机制」）；② 检查手动窗口化下滚动跟随全由 `onGeometryChange` 写回 `scrollOffset` 驱动是否造成每帧重算/卡顿；③ 优化滚动顺滑度（惯性、跟手度、无跳变）。涉及 `NewPiChatView.swift`、`NewPiChatScrollHelper.swift`、`NewPiTranscriptHeightMap.swift`。改前先读 `docs/dev-notes/chat-scroll-layout.md` 与 `2026-08-28-streaming-markdown-rendering-context.md`。 |

## Backlog — 输入框

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-HISTORY-COUNT | 历史记录展示条数由 5 条改为 7 条 | P2 | 当前某处展示 5 条历史记录，需改为展示 7 条。定位具体实现位置（可参考 `NewPiChatView.swift` 的可视范围窗口化 `TranscriptHeightMap.window` 逻辑或相关历史/最近记录展示处），确认无其它耦合后再调整。 |
| BACKLOG-SHOWALL-INCREMENT | 点击 Show all 按钮时每次只多显示 5 条（增量展开） | P2 | 当前 `NewPiApp.swift` 的 Session 列表里，"Show all / Show less" 是布尔开关（`showsAllSessions`），点击后要么全量显示、要么回到默认 5 条（`recentSessionLimit = 5`）。需求：改为「每次点击 Show all 只多显示 5 条」的增量加载，即维护一个已显示数量计数器，点击时 `+5`（封顶到 `savedSessions.count`），而非一次性全量展开。涉及 `NewPiApp.swift:107-113`（`recentSessionLimit`、`displayedSessions`）、`:159-166`（按钮逻辑）。注意保留默认首屏 5 条与最终全部显示的能力，并考虑与 `showsAllSessions` 现有状态的兼容。 |
| BACKLOG-COMPOSER-MULTILINE | 输入框多行（当前仅一行） | P1 | `NewPiChatView.swift` 的 `chatComposer` 当前是 `TextField(axis: .vertical)` + `.lineLimit(1 ... 6)`，用户体验上仍近似单行。建议换为基于 `NSTextView` 的自定义多行输入框：支持真实多行输入、自动增高、`Return` 发送 / `Shift+Return` 换行，并保留 `.disabled(runtime.isStreaming)` 逻辑。需注意与现有 `composerHeight` 滚动监听、`Send`/`Stop` 按钮布局的兼容。 |

## Backlog — 思考过程 / 工具输出折叠

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-FOLD-THINKING-TOOL | 思考过程与工具输出统一折叠，折叠后显示执行过程预览 | P1 | 当前状态：工具输出已在 `NewPiToolTranscriptView` 里有 `isExpanded` 折叠（摘要见 `collapsedSummary`）；但**思考过程（thinking/reasoning）并未真实渲染到 transcript**，`NewPiViewModel.handle` 对 `thinkingDelta` 仅打日志（`UI: reasoning delta`）。目标：把 thinking 与工具输出都用统一的折叠组件呈现，默认收起，折叠态展示执行过程预览（如 "Thinking… N steps" / 工具摘要），点击展开查看全文。涉及 `NewPiToolTranscriptView.swift`、`NewPiTranscriptRow.swift`、`NewPiMarkdownText.swift` 以及 `NewPiViewModel` 的 thinking 增量处理（需先让 thinking 进 transcript / 持久化）。 |

## Code review 2026-08-27 — 待修复问题

See [`dev-notes/2026-08-27-code-review-findings.md`](dev-notes/2026-08-27-code-review-findings.md) for full details (证据 + 修复方向).

| ID | Item | Priority | Notes |
|---|---|---|---|
| REV-CORE-1 | AgentLoop catch 分支引用初始 context，出错时回滚整个会话 | P0 | `AgentLoop.swift:17` — `var context` 移出 do 块 |
| REV-CORE-2 | Anthropic 流式解析跨块状态丢失，工具调用不工作 | P0 | `AnthropicProvider.swift:163-166` — decoder/parser 需有状态化 |
| REV-CORE-3 | MCP stdio 读循环在 actor 上同步阻塞，握手死锁 | P0 | `MCPStdioTransport.swift:143` — 改 detached/通知式 IO |
| REV-CORE-4 | SubAgentTool 硬编码 `.allowAll` 绕过审批与危险评估 | P0 | `SubAgentTool.swift:78-84` — 透传审批链 |
| REV-CORE-5 | Compaction 后 JSONL 持久化静默失效（数据丢失） | P0 | `JSONLSessionStore.swift:427-428` — compaction 需追加 `.compaction` entry |
| REV-CORE-6 | `JSONValueDecoder` 把 JSON 0/1 解析为 Bool | P1 | `JSONValue+Codable.swift:49-52` — 分支顺序/CFBoolean 判定 |
| REV-CORE-7 | 编辑 Provider 留空 API key 静默删除已存凭据 | P1 | `NewPiViewModel.swift:382` |
| REV-CORE-8 | Bash 输出无内存上限（OOM） | P1 | `BuiltInTools.swift:377-381` — 增量读取 |
| REV-SEC | 危险规则正则错误 / 参数别名绕过审批摘要 / 审批取消复活 | P1 | SEC-1..SEC-8，见 dev-notes |
| REV-PROV | env key 发给任意端点 / Keychain 明文副本 / 无流式超时 / thinking 400 | P1 | PROV-1..9，见 dev-notes |
| REV-MCP | 协议版本与分帧不自洽 / 通知错位 / 环境继承 / reload 不清理 | P1 | MCP-1..7，见 dev-notes |
| REV-UI | 切项目竞态 / runtimes 泄漏 / 截断提示被擦除 / Stop 显示红色错误 | P2 | UI-1..9，见 dev-notes |
| REV-TEST | 测试污染真实 ~/.new-pi 与 Keychain / 危险规则仅测 2/14 / MCP 零覆盖 | P2 | TEST-1..6，见 dev-notes |

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
