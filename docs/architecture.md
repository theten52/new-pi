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

## Session persistence (Phase 4)

JSONL files under `~/.new-pi/agent/sessions/<project-hash>/`.

- `JSONLSessionStore` — encode/decode header + tree entries
- `SessionManager` — create, list, rebuild messages from branch
- `AgentSession.attachPersistence` — saves on each `contextSnapshot`
- App sidebar — session list + resume

Resume currently uses the default provider profile; restoring the saved profile is tracked in `docs/TODO.md` (P4-RESUME-PROVIDER).

## Phase roadmap

| Phase | Scope | Status |
|---|---|---|
| 0–1 | Types, AgentLoop, tests | Done |
| 2 | AnthropicProvider + Keychain | Done |
| 3 | read/write/edit/bash + ToolPolicy | Done |
| 3.5 | Provider profiles + BYOK + multi-vendor | Done |
| 4 | JSONL session persistence + resume UI | Done |
| 5 | AGENTS.md, Skills, Compaction | Next |
| 6 | NewPi SwiftUI polish | In progress |
