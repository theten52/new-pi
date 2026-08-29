# NewPi Development TODOs

Tracked blockers and follow-ups discovered during autonomous development.

## Phase 4 — Session persistence

| ID | Item | Status | Notes |
|---|---|---|---|
| P4-UI | Sidebar session list + resume | done | Phase 4b/c |
| P4-BRANCH | Branch/fork UI for tree sessions | done | Fork from transcript row |
| P4-RESUME-PROVIDER | Restore provider profile from session header on resume | done |
| P4-CLI | CLI session commands | done | `new-pi sessions list/show/export` |
| P4-AUTO-RESUME | 打开 App / 项目时自动恢复上次离开时的 Session | done | `NewPiLastSessionStore` 按项目记录最后活跃会话；`openProject` 后 `restoreLastSessionIfPossible` 恢复；归档当前会话时清除记录 |

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

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-TOKEN-BAR | 状态栏显示当前对话的 token 用量 | done | P1 | 已实现：`SessionRuntime` 新增 `totalUsage`/`lastTurnUsage`（@Published），`messageEnd(.assistant)` 时累计；冷恢复由历史消息的 usage 重建（`accumulateUsage`）；输入框上方状态栏右侧显示累计 `↑输入 ↓输出`（紧凑格式，tooltip 含最近一轮明细）+ 缓存命中率（⚡xx%，`UsageStats` 新增 cacheRead/cacheCreation 字段，Anthropic/OpenAI 兼容/Responses 三个 provider 均已解析，含 DeepSeek `prompt_cache_hit_tokens` 变体；旧 JSONL 解码兼容缺省 0）。另：状态栏与输入框间的 Divider 移到状态栏上方。注意：OpenAI 兼容 provider 流式原本不报 usage（REV-PROV-6），需端点支持才显示。 |
| BACKLOG-SESSION-HOVER-GLASS | Session 列表鼠标悬浮玻璃高亮效果 | open | P2 | 鼠标移动到右侧（侧边栏）Session 列表项时，给出玻璃（glass / 毛玻璃）高亮效果。可参考 SwiftUI 的 `.glassEffect` 或自定义 `NSVisualEffectView` / `.background(.thinMaterial)`，实现悬浮态 hover 高亮。目标文件：`NewPiApp/NewPiApp.swift` 中的 `SessionRow`。 |
| BACKLOG-BUBBLE-BG | 对话气泡背景色（Agent 输出气泡 + 同对话同色 + 跨对话异色） | open | P2 | 对话气泡需要有背景色。用户输入气泡已有背景色，Agent（NewPi）输出气泡也需要有；**同一对话内**输入/输出气泡背景色需一致；**不同对话**之间的背景色需不一样，以方便区分。背景色随机生成，以浅色为主、视觉柔和。注意：是**气泡**的背景色，不是整个对话窗口的背景色。目标文件：`NewPiApp/NewPiChatView.swift` 与气泡渲染逻辑（用户输入气泡、`NewPiMarkdownText` / `NewPiMarkdownWebRenderer` 的 Agent 气泡）。 |
| BACKLOG-THINKING-COLLAPSE | 思考过程默认折叠，提供按钮手动展开查看 | open | P2 | 思考（thinking / reasoning）过程占据过多版面，考虑默认隐藏/折叠，提供按钮供用户手动点击展开查看。涉及 Agent 输出的 reasoning/thinking 内容在气泡中的展示逻辑，相关文件：`NewPiChatView.swift`、`NewPiMarkdownText.swift`（streaming 时 thinking 显示）、以及 `NewPiViewModel` 的思考增量处理。折叠态默认收起，展开后保持可再次收起。 |
| BACKLOG-SESSION-AUTO-SELECT | 存档/删除 session 后自动切换到下一个 session | done | P2 | 已实现：`archiveSession` 归档当前会话后自动切到同项目列表中的下一条（优先下面一条，末条则回退到最新一条）；同项目无更多会话时保持空态。「下一个项目」暂未实现（App 是单项目模型，无项目列表概念）。 |
| BACKLOG-SESSION-RELOAD-SCROLL-JUMP | 重新加载 Session 时 loading 结束后滚动条跳动 | open | P2 | 重新加载 Session 时，loading 页面结束后，页面仍在加载，导致滚动条跳动。需确保内容完全加载并稳定后再结束 loading / 稳定滚动位置，避免结束后滚动条抖动。目标文件：`NewPiChatView.swift`、`NewPiViewModel.swift` 的 session 切换 / loading / 滚动相关逻辑。 |
| BACKLOG-SESSION-MANUAL-CREATE | 新 Session 只能由用户手动点击 New Session 按钮创建，系统不自动创建 Session | done | P1 | 已移除 `openProject` / `reloadProviders` / `setDefaultProvider` / `saveProfile` / `deleteProfile` 中的自动建会话；`archiveSession` 归档当前会话改为 `closeActiveSession()`（结束当前会话、回到无活跃会话状态）而非新建。`startNewSession`（按钮 / ⇧⌘N）与 `resetSession` 保留为手动入口。 |
| BACKLOG-DEFAULT-PROVIDER | 新增默认 Provider 设置，新建 Session 默认使用该 Provider | done | P1 | 已实现：Settings「Default Provider」picker 语义改为「Default for new sessions」并加说明（只影响新建会话）；侧边栏 Provider 区新增「Set as Default」快捷入口（当前会话 provider ≠ 默认时显示）；默认 provider 不影响已有会话，会话内切换随 header 逐会话记忆并立即落盘。 |

## Backlog — 对话流滚动

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-SCROLL-LAG | 对话流滑动不跟手 | P1 | 聊天列表滚动有滞后/不跟手手感。当前实现为「手动窗口化 + 高度表占位」（`TranscriptHeightMap`）+ `ScrollView` + `scrollPosition($jumpPosition)` + `ScrollViewReader.scrollTo` 多机制叠加，见 `docs/dev-notes/chat-scroll-layout.md`。需要：① 排查多种滚动机制是否互相干扰（dev-notes 明确警告「一种 scroll 机制」）；② 检查手动窗口化下滚动跟随全由 `onGeometryChange` 写回 `scrollOffset` 驱动是否造成每帧重算/卡顿；③ 优化滚动顺滑度（惯性、跟手度、无跳变）。涉及 `NewPiChatView.swift`、`NewPiChatScrollHelper.swift`、`NewPiTranscriptHeightMap.swift`。改前先读 `docs/dev-notes/chat-scroll-layout.md` 与 `2026-08-28-streaming-markdown-rendering-context.md`。 |

## Backlog — 输入框

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-HISTORY-COUNT | ~~历史记录展示条数由 5 条改为 7 条~~ | ~~cancelled~~ | P2 | ~~当前某处展示 5 条历史记录，需改为展示 7 条。定位具体实现位置（可参考 `NewPiChatView.swift` 的可视范围窗口化 `TranscriptHeightMap.window` 逻辑或相关历史/最近记录展示处），确认无其它耦合后再调整。~~ 决定不做。 |
| BACKLOG-SHOWALL-INCREMENT | 点击 Show all 按钮时每次只多显示 5 条（增量展开） | done | P2 | 已实现：`showsAllSessions` 布尔开关改为 `sessionDisplayLimit` 计数器（默认 5，点击 Show all 每次 +5 封顶，Show less 收回默认；切项目重置）。见 `NewPiApp.swift`。 |
| BACKLOG-COMPOSER-MULTILINE | 输入框多行（当前仅一行） | done | P1 | 已实现：`chatComposer` 的 `TextField` 换成 NSTextView 封装 `NewPiComposerTextView`（`NewPiChatView.swift`）：真实多行、自动增高（上限 4 行后滚动）、Return 发送 / Shift+Return 换行（含 IME 组词保护）、保留 streaming 禁用；Send 按钮的 Return 快捷键已移除避免双重触发。 |
| BACKLOG-STATUS-BAR | 将 "NewPi is ready" 状态移出气泡框，放到输入框上方，规划为输入框上方的状态栏 | done | P2 | 核实完成：`NewPiAgentStatusBar` 全工程仅在 `NewPiChatView.swift` 的 `chatComposer`（输入框上方、Divider 之下）渲染一处；transcript 无任何状态类行。该条状态栏（图标 + 文本 + 分隔线）即未来「输入框上方状态栏」的基座，后续 token 用量（BACKLOG-TOKEN-BAR）等可在此扩展。 |
| BACKLOG-HOVER-BUTTON-DISAPPEAR | 鼠标放到 Copy / Fork 按钮上时这 2 个按钮会消失 | done | P1 | 已修复（`NewPiMarkdownText.swift` `NewPiTranscriptRow`）：① hover 滞回去抖——退出时延迟 180ms 隐藏，期间重新进入即取消（`hoverExitTask`）；② action 按钮自身也挂 `onHover`，移上按钮即保持显示，不再依赖整行 hover 时序。消除了「opacity 归 0 → 不可命中 → 再触发 exit」的抖动循环。 |
| BACKLOG-IMAGE-INPUT | 图片输入：支持选择、粘贴图片，且已添加的图片可移除 | open | P1 | 多模态输入能力，三个子需求：① **选择图片输入**——输入框提供添加图片入口（`NSOpenPanel` / SwiftUI `fileImporter`，过滤图片类型），选中后在输入框内/上方以缩略图形式展示；② **粘贴图片输入**——输入框支持 `Cmd+V` 从剪贴板粘贴图片（`NSPasteboard` 读取 `.tiff`/`.png` 等图片 data）；③ **移除已添加图片**——每张缩略图带「×」按钮，点击移除并更新待发送附件列表。发送时图片需作为多模态 content 附加到用户消息（`ModelTypes.swift` 消息构造需支持 image content），并贯穿 provider 序列化层（当前 DeepSeek/GLM 等 provider 的多模态支持需确认）。涉及 `NewPiChatView.swift`（composer + 缩略图区）、`NewPiViewModel.swift`（消息构造/发送）、`ModelTypes.swift`（多模态 content 类型）、provider 消息序列化。 |

## Backlog — 思考过程 / 工具输出折叠

| ID | Item | Priority | Notes |
|---|---|---|---|
| BACKLOG-FOLD-THINKING-TOOL | 思考过程与工具输出统一折叠，折叠后显示执行过程预览 | P1 | 当前状态：工具输出已在 `NewPiToolTranscriptView` 里有 `isExpanded` 折叠（摘要见 `collapsedSummary`）；但**思考过程（thinking/reasoning）并未真实渲染到 transcript**，`NewPiViewModel.handle` 对 `thinkingDelta` 仅打日志（`UI: reasoning delta`）。目标：把 thinking 与工具输出都用统一的折叠组件呈现，默认收起，折叠态展示执行过程预览（如 "Thinking… N steps" / 工具摘要），点击展开查看全文。涉及 `NewPiToolTranscriptView.swift`、`NewPiTranscriptRow.swift`、`NewPiMarkdownText.swift` 以及 `NewPiViewModel` 的 thinking 增量处理（需先让 thinking 进 transcript / 持久化）。 |

## Code review 2026-08-27 — 待修复问题

See [`dev-notes/2026-08-27-code-review-findings.md`](dev-notes/2026-08-27-code-review-findings.md) for full details (证据 + 修复方向).

| ID | Item | Priority | Notes |
|---|---|---|---|
| REV-CORE-1 | AgentLoop catch 分支引用初始 context，出错时回滚整个会话 | done | `AgentLoop.swift` — `var context` 已在 Task 闭包顶层、do 块之前声明（本次核实无需再改） |
| REV-CORE-2 | Anthropic 流式解析跨块状态丢失，工具调用不工作 | P0 | `AnthropicProvider.swift:163-166` — decoder/parser 需有状态化 |
| REV-CORE-3 | MCP stdio 读循环在 actor 上同步阻塞，握手死锁 | P0 | `MCPStdioTransport.swift:143` — 改 detached/通知式 IO |
| REV-CORE-4 | SubAgentTool 硬编码 `.allowAll` 绕过审批与危险评估 | P0 | `SubAgentTool.swift:78-84` — 透传审批链 |
| REV-CORE-5 | Compaction 后 JSONL 持久化静默失效（数据丢失） | P0 | `JSONLSessionStore.swift:427-428` — compaction 需追加 `.compaction` entry |
| REV-CORE-6 | `JSONValueDecoder` 把 JSON 0/1 解析为 Bool | P1 | `JSONValue+Codable.swift:49-52` — 分支顺序/CFBoolean 判定 |
| REV-CORE-7 | 编辑 Provider 留空 API key 静默删除已存凭据 | done | `NewPiViewModel.saveProfile` 已对空 key 跳过 `saveAPIKey`（本次核实） |
| REV-CORE-8 | Bash 输出无内存上限（OOM） | P1 | `BuiltInTools.swift:377-381` — 增量读取 |
| REV-SEC | 危险规则正则错误 / 参数别名绕过审批摘要 / 审批取消复活 | P1 | SEC-1..SEC-8，见 dev-notes |
| REV-PROV | env key 发给任意端点 / Keychain 明文副本 / 无流式超时 / thinking 400 | P1 | PROV-1..9，见 dev-notes |
| REV-MCP | 协议版本与分帧不自洽 / 通知错位 / 环境继承 / reload 不清理 | P1 | MCP-1..7，见 dev-notes |
| REV-UI | 切项目竞态 / runtimes 泄漏 / 截断提示被擦除 / Stop 显示红色错误 | P2 | UI-1..9，见 dev-notes |
| REV-TEST | 测试污染真实 ~/.new-pi 与 Keychain / 危险规则仅测 2/14 / MCP 零覆盖 | P2 | TEST-1..6，见 dev-notes |

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
