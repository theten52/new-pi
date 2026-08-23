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

## Phase roadmap

| Phase | Scope | Status |
|---|---|---|
| 0–1 | Types, AgentLoop, tests | Done |
| 2 | AnthropicProvider + Keychain | Done |
| 3 | read/write/edit/bash + ToolPolicy | Done |
| 3.5 | Provider profiles + BYOK + multi-vendor | Done |
| 4a | JSONL SessionStore + SessionManager | Done |
| 4 | SessionManager App wiring + UI | In progress |
| 5 | AGENTS.md, Skills, Compaction | Planned |
| 6 | NewPi SwiftUI polish | In progress |
