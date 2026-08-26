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

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
