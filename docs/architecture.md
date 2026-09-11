# NewPi architecture

## Naming

| Item | Value |
|---|---|
| Repository | `new-pi` |
| Swift module | `NewPiCore` |
| macOS app | `NewPi` |
| CLI binary | `new-pi` |
| User config | `~/.new-pi/agent/` |
| Project config | `.new-pi/` |

## Layers

```
NewPi.app (SwiftUI, custom UI)
    └── AgentViewModel
            └── AgentSession (actor)
                    └── AgentLoop
                            ├── LLMProvider
                            └── AgentTool[]
                    └── SessionStore (JSONL, Phase 4)
```

## Event contract

UI binds to `AgentEvent` only:

1. `agentStart`
2. `turnStart`
3. `messageStart` / `textDelta` / `toolExecution*` / `messageEnd`
4. `turnEnd`
5. `contextSnapshot`
6. `agentEnd`

This mirrors Pi `pi-agent-core` sequencing without copying its TUI.

## Session format (planned)

JSONL tree entries with `id` and `parentID`, stored under:

`~/.new-pi/agent/sessions/<project-hash>/<timestamp>_<uuid>.jsonl`

## Extension model (planned)

Swift protocol `NewPiExtension` for tools, slash commands, and lifecycle hooks. No TypeScript/jiti compatibility.

## 编辑前文件备份

内置 `edit` 工具在唯一匹配检查通过后、写入修改前，通过
[`EditSnapshotStore`](../Packages/NewPiCore/Sources/NewPiCore/Tools/EditSnapshotStore.swift)
保存完整原文件。`write` 和 `bash` 不经过此机制；它不是项目级撤销或 Git 提交，
目前也没有快照管理/一键恢复 UI。工具结果返回可直接定位的备份完整路径。

2026-09-11 起，新备份格式为：

```text
<项目>/.new-pi/snapshots/
  v2-<规范化源文件绝对路径的 SHA256>/
    source-path.txt
    <UTC 时间戳>-<UUID>.snapshot
```

- `source-path.txt` 记录原文件完整路径，`.snapshot` 文件本身是未经包装的原文件内容。
  按路径而非 basename 隔离配额，不同目录的同名文件不会互相淘汰。
  路径先标准化并解析符号链接；同一源文件的路径别名归入同组。
- 默认每个源文件最多 20 份、最长保留 30 天；每次成功创建备份后触发清理。
  同秒重复编辑使用 UUID 避免重名；创建顺序依据备份修改时间，复制后显式更新该时间，
  不沿用源文件可能很旧的修改时间。时间相同时按文件名确定顺序，当次新备份始终优先保留。
- `RetentionPolicy` 的单项 `nil` 表示不限制，`.unlimited` 完全关闭清理；
  非正数配置会阻止新备份创建并抛错，显式 `prune` 则记录错误且不删除。
  备份创建失败会阻止这次 edit；清理失败会记录日志，但不让已成功备份的编辑因此失败。
- 清理只处理有匹配源路径元数据的 v2 目录内、命名合法的普通快照文件；
  不跟随符号链接，不递归删除子目录。旧平铺格式缺少路径归属，**既不迁移，也不自动删除**。
- 创建和清理通过同进程锁串行化；这不是跨进程文件锁，不提供 App 与 CLI 同时修改同一文件的事务保证。
  项目移动/文件改名后的新路径会形成新组，旧备份仍按原身份保留。

回归覆盖同名文件隔离、路径别名、连续及并发备份、数量/年龄边界、旧格式保留、
非法策略、元数据异常、非普通文件跳过和 `edit` 返回路径可读取。

## Credentials (Phase 2)

Resolution order for Anthropic:

1. `ANTHROPIC_API_KEY` environment variable
2. Keychain account `anthropic-api-key` in service `com.new-pi.credentials`

App UI: **Settings → NewPi**

## Provider configuration (Phase 3.5)

Profiles stored in `~/.new-pi/agent/providers.json`. API keys in Keychain as `provider:<profile-id>:apiKey`.

Supported presets (v1):

| Preset | Implementation |
|---|---|
| anthropic | `AnthropicProvider` |
| openai / openaiCompatible / openRouter / ollama | `OpenAICompatibleProvider` |

Quick-add templates: Anthropic, OpenAI, DeepSeek, OpenRouter, Ollama, custom OpenAI-compatible.

Legacy `anthropic-api-key` migrates to profile `anthropic-default` on first load.

App UI: **Settings → Providers**

## Project instructions (Phase 5a)

Search order for `AGENTS.md`:

1. `<project>/.new-pi/AGENTS.md`
2. `<project>/AGENTS.md`

Merged into the agent system prompt via `AgentsMarkdownLoader`.

## Skills (Phase 5b)

Markdown skills discovered from:

1. `~/.new-pi/agent/skills/<id>/SKILL.md` (user)
2. `<project>/.new-pi/skills/<id>/SKILL.md` (project overrides same id)

Optional YAML frontmatter: `name`, `description`, `enabled`. Composed via `SystemPromptComposer`.

Extension protocol: `NewPiExtension` / `NewPiMarkdownSkill` for future native tools and hooks.

## Context compaction (Phase 5c)

When estimated input tokens exceed `CompactionConfig.triggerTokenCount` (default 75% of 96k), `CompactionService` summarizes older messages via the active LLM and replaces them with a single `compactionSummary` message. Recent messages (default last 8) are kept verbatim. Tool-call pairs are not split. JSONL sessions persist compaction as `.compaction` entry type.

## Debug logs (Phase 7b)

`NewPiLogger` in NewPiCore records LLM requests/responses (secrets redacted), tool execution, and agent events. The macOS app exposes an in-memory log sheet (**View Logs**, `Cmd+Shift+L`) with Copy/Clear and Console.app shortcut.

## Markdown rendering (Phase 6b)

Assistant, compaction summary, and tool result bubbles use markdown rendering:

```
NewPiApp/MarkdownRenderer/  → bundled JS/CSS (markdown-it, highlight.js)
NewPiMarkdownWebRenderer.swift  → HTML shell, CSP, evaluateJS (completed messages)
NewPiMarkdownText.swift  → native Text while streaming; WebView on flush
NewPiChatView.swift  → chat layout, scroll pinning, composer + status bar
```

- **Streaming:** native `Text` / `AttributedString` (intrinsic height, no WebView mount jump)
- **Completed:** WKWebView markdown-it + highlight.js (`flushRendering: true` on agentEnd)
- **Chat scroll/layout:** see [`docs/dev-notes/chat-scroll-layout.md`](dev-notes/chat-scroll-layout.md) (Agent 必读)
- **Multi-modal (图片) 支持:** see [`docs/multi-modal-vision-plan.md`](multi-modal-vision-plan.md) (规划中，未执行)

## MCP plugins (Phase 7a)

External tools via [Model Context Protocol](https://modelcontextprotocol.io/) stdio servers.

```
~/.new-pi/agent/mcp.json
        └── MCPPluginManager (actor, singleton)
                └── MCPConnection per server
                        └── MCPStdioTransport (JSON-RPC framing)
                                └── MCPAgentTool → AgentSession tools[]
```

- **Config:** `mcpServers` map with `command`, `args`, optional `env`, `disabled`
- **Secrets:** `${VAR}` env substitution; `env:account` Keychain refs (service `com.newpi.mcp`)
- **Tool naming:** `mcp/{serverId}/{toolName}` — merged at session start via `MCPToolLoader`
- **Policy:** MCP tools always require approval (`ToolPolicy`)
- **UI:** Settings → MCP Plugins; consent alert on first enable; server status + restart
- **Lifecycle:** `MCPPluginManager.shared.shutdownAll()` on app terminate

Enable via Settings or `NEW_PI_MCP=1`. Per-server toggles persist in UserDefaults.

## Session persistence (Phase 4)

JSONL files under `~/.new-pi/agent/sessions/<project-hash>/`.

- `JSONLSessionStore` — encode/decode header + tree entries
- `SessionManager` — create, list, rebuild messages from branch
- `AgentSession.attachPersistence` — saves on each `contextSnapshot`
- App sidebar — session list + resume
- CLI — `new-pi sessions list/show [--project PATH]`

Resume restores provider profile from session header.

## Session branching (Phase 8 / P4-BRANCH)

JSONL entries form a tree via `id` / `parentID`. `SessionManager.syncMessages` incrementally appends new messages without destroying sibling branches. App UI exposes **Fork from here** on transcript rows; `AgentSession.fork(atMessageIndex:)` rewinds the active branch.

## Session export (Phase 8 / P8-EXPORT)

`SessionExporter` produces Markdown, plain text, or JSONL (via `JSONLSessionCodec`). App: toolbar Export menu. CLI: `new-pi sessions export <id> [--format markdown|json|text]`.

## Sub-agents (Phase 8 / P8-SUBAGENT)

`SubAgentTool` runs a nested `AgentLoop` with read + bash tools (no recursion). Registered in `AgentSessionFactory.codingSession`. Requires user approval like bash/write.

## Phase roadmap

| Phase | Scope | Status |
|---|---|---|
| 0–1 | Types, AgentLoop, tests | Done |
| 2 | AnthropicProvider + Keychain | Done |
| 3 | read/write/edit/bash + ToolPolicy | Done |
| 3.5 | Provider profiles + BYOK + multi-vendor | Done |
| 4 | JSONL session persistence + resume UI | Done |
| 5 | AGENTS.md, Skills, Compaction | Done |
| 6 | NewPi SwiftUI polish + WebView Markdown | Done |
| 7 | Debug logs, Chat UX, MCP client | Done |
| 8 | Session branch, export, sub-agent | Done |
