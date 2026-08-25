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
| 6 | NewPi SwiftUI polish | Done |
| 7 | Debug logs, Chat UX, MCP client | Done |
| 8 | Session branch, export, sub-agent | Done |
