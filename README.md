# new-pi

Pi-inspired native macOS coding agent harness, implemented in Swift.

- **Product name:** NewPi
- **Core library:** `NewPiCore`
- **CLI:** `new-pi`
- **Config root:** `~/.new-pi/agent/`
- **Project config:** `.new-pi/`

## Status

| Phase | Scope | Status |
|---|---|---|
| 0–1 | AgentLoop, tests, AgentSession | Done |
| 2 | AnthropicProvider, Keychain credentials | Done |
| 3 | read/write/edit/bash + ToolPolicy | Done |
| 3.5 | Provider profiles + BYOK (Anthropic, OpenAI-compatible, OpenRouter, Ollama) | Done |
| 4a | JSONL SessionStore + SessionManager | Done |
| 4b/c | Session persistence + sidebar resume UI | Done |
| 5a | AGENTS.md loader | Done |
| 5b | Skills loader + NewPiExtension | Done |
| 5c | Context compaction | Done |
| 6 | NewPi SwiftUI polish | Done |

Phase 3.5 adds:

- `ProviderConfigStore` — profiles in `~/.new-pi/agent/providers.json`
- BYOK via Keychain (`provider:<id>:apiKey`) with env override
- Presets: Anthropic, OpenAI, DeepSeek (compatible), OpenRouter, Ollama
- Settings UI for multi-provider management

Phase 2 adds:

- `AnthropicProvider` (Messages API streaming + tool_use)
- `CredentialResolver` (env `ANTHROPIC_API_KEY` → Keychain)
- NewPi Settings window for API key entry

## Structure

```
new-pi/
├── Packages/NewPiCore/     # SwiftPM library + CLI
├── NewPiApp/               # SwiftUI macOS app sources
└── docs/                   # architecture notes
```

## Develop

```bash
cd Packages/NewPiCore
swift test
swift run new-pi
swift run new-pi sessions list --project /path/to/project
swift run new-pi sessions show <session-id> --project /path/to/project
```

## NewPi macOS app

Create an Xcode macOS App project named **NewPi**, then add a local package dependency on `Packages/NewPiCore` and include sources from `NewPiApp/`.

The app subscribes to `AgentSession.events()` and renders your custom UI. No terminal TUI is included by design.

## License

MIT (scaffold only; confirm before release)
