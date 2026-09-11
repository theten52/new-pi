# new-pi

受 Pi 启发、以 Swift 实现的原生 macOS 编码 Agent 应用。

- **Product name:** NewPi
- **Core library:** `NewPiCore`
- **CLI:** `new-pi`
- **Config root:** `~/.new-pi/agent/`
- **Project config:** `.new-pi/`

## Status

下表保留早期里程碑；当前架构见 [架构总览](docs/architecture.md)，
文档分类与历史状态见 [文档索引](docs/README.md)，未完成事项见 [TODO](docs/TODO.md)。

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

## 当前渲染与协作能力

- **单文档渲染：** 每条会话使用一个 WKWebView；Markdown 与代码高亮使用本地打包的 markdown-it + highlight.js。
- **流式更新：** delta 先合并到易失渲染态，再直达文档；消息边界提交正式 transcript。流式与完成态使用同一文档路径，不切换原生 Text/WebView。
- **滚动：** 原生侧发送 transcript diff 与滚动意图；布局、虚拟化和锚点恢复由文档内 JS 管理，不向原生回传正文高度。
- **安全与图片：** CSP 禁止网络连接，Markdown 原始 HTML 与图片语法禁用；用户图片附件由受控 `pi-att://` 本地加载，并支持原生预览。
- **多模型聊天室：** 角色共享讨论历史，主路径复用 AgentLoop；支持实时发言、工具审批、用户插话及讨论/投票/执行/Review 阶段管理。详见 [聊天室设计](docs/chatroom-design.md)。

Phase 8 adds session branching, export, and sub-agents:

- **P4-BRANCH:** 普通会话中带 Fork 操作的条目可创建分支，保留树形 JSONL；聊天室不提供该操作
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
- 凭据由 `ProviderCredentialResolver` 解析：环境变量优先，随后是本地凭据存储；默认写入 UserDefaults，可选同时写入 Keychain（`provider:<id>:apiKey`），不是默认 Keychain-only
- Presets: Anthropic, OpenAI, DeepSeek (compatible), OpenRouter, Ollama
- Settings UI for multi-provider management

三类 API 协议由 Anthropic、OpenAI-compatible 和 Responses provider 适配；
API key 在 Settings → Providers 中配置。模型是否支持图片需在 profile 中明确标记，不能仅凭厂商名推断。

## Structure

```
new-pi/
├── Packages/NewPiCore/     # SwiftPM library + CLI
├── NewPiApp/               # SwiftUI macOS app sources
├── scripts/                # build/package scripts (see scripts/README.md)
└── docs/                   # architecture notes
```

## Develop

```bash
cd Packages/NewPiCore
swift test
swift run new-pi
swift run new-pi sessions list --project /path/to/project
swift run new-pi sessions show <session-id> --project /path/to/project
swift run new-pi sessions export <session-id> --format markdown --output file.md
```

CLI 当前提供 provider 状态及 session list/show/export；交互式 Agent 对话在 macOS App 中进行，没有终端 TUI。

## Package (build the macOS app)

```bash
./scripts/package.sh            # Release → dist/NewPi.app
./scripts/package.sh Debug      # Debug build
open dist/NewPi.app             # run the packaged app
```

Full usage: see [`scripts/README.md`](scripts/README.md).

## Session branch & export (Phase 8)

- **Fork:** Click the branch icon on a transcript message to continue from that point; sibling branches are preserved in JSONL
- **Export:** Toolbar → Export (Markdown / Text / JSON)
- **Sub-agent:** 主 agent 可通过 `subagent` 委派任务（需审批）；当前工具批次逐个执行，不代表已实现并行调度

## NewPi macOS app

仓库已包含 `NewPi.xcodeproj`，直接打开并选择 **NewPi / My Mac** 运行，无需另建工程。
开发环境要求 macOS 15+、Xcode 16+（Swift 6），详见 [App 运行指南](NewPiApp/README.md)。

普通会话界面订阅 `AgentSession.events()`；`NewPiCore` 作为独立 SwiftPM 包提供引擎与会话能力。

## License

MIT. See [LICENSE](LICENSE) for details.
