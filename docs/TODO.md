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
