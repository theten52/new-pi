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
| 6b | WKWebView Markdown (streaming) | Done |
| 7b | Debug logs | Done |
| 7c | Chat UX polish | Done |
| 7a | MCP client (stdio + Settings UI) | Done |
| 8 | Session branch, export, sub-agent | Done |

Phase 6b adds WKWebView Markdown rendering for assistant, summary, and tool messages:

- **Engine:** markdown-it + highlight.js (bundled in `NewPiApp/MarkdownRenderer/`)
- **Streaming:** 150ms throttled `evaluateJavaScript` updates; flush on agentEnd
- **Fallback:** native `AttributedString` if WebView or bundle fails
- **Security:** CSP, no raw HTML, no images, link navigation blocked

Phase 8 adds session branching, export, and sub-agents:

- **P4-BRANCH:** Fork from any message in the transcript (branch icon); tree JSONL preserved
- **P8-EXPORT:** Toolbar Export menu (Markdown/Text/JSON); CLI `new-pi sessions export <id>`
- **P8-SUBAGENT:** `subagent` tool spawns a focused child agent (read + bash); requires approval

Phase 7a adds MCP (Model Context Protocol) plugin support:

- Config: `~/.new-pi/agent/mcp.json` (same shape as Claude Desktop / Cursor)
- Stdio JSON-RPC transport; tools exposed as `mcp/{serverId}/{toolName}`
- Settings → **MCP Plugins** with consent gate, per-server enable/restart
- MCP tool calls require user approval (unlike built-in read-only tools)
- Env override: `NEW_PI_MCP=1` to enable without UI consent

Example `mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"]
    }
  }
}
```

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
swift run new-pi sessions export <session-id> --format markdown [--output file.jsonl]
```

## Session branch & export (Phase 8)

- **Fork:** Click the branch icon on a transcript message to continue from that point; sibling branches are preserved in JSONL
- **Export:** Toolbar → Export (Markdown / Text / JSON)
- **Sub-agent:** Main agent can call `subagent` tool for delegated parallel work (requires approval)

## NewPi macOS app

Create an Xcode macOS App project named **NewPi**, then add a local package dependency on `Packages/NewPiCore` and include sources from `NewPiApp/`.

The app subscribes to `AgentSession.events()` and renders your custom UI. No terminal TUI is included by design.

## License

MIT (scaffold only; confirm before release)
