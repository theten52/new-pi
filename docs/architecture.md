# NewPi architecture

> 当前架构导航，2026-09-12 按源码核对。历史方案和复盘的阅读顺序见
> [文档索引](README.md)；已知问题与未完成事项见 [TODO](TODO.md)。

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
NewPi.app (SwiftUI + AppKit)
    ├── NewPiViewModel → SessionRuntime → AgentSession (actor)
    │                                      ├── AgentLoop → LLMProvider / AgentTool[]
    │                                      └── SessionManager → JSONLSessionStore
    ├── ChatRoomRuntimeStore → ChatRoomFlowController → ChatRoomLoop
    │                                                   ├── AgentLoop（主路径）
    │                                                   └── ChatRoomStore
    └── NewPiTranscriptDocumentView → WKWebView → transcript-document.js
```

`Packages/NewPiCore/` 是 Swift 6 / macOS 15 的 SwiftPM library + CLI；
`NewPiApp/` 由仓库内 `NewPi.xcodeproj` 构建，不属于 SwiftPM UI target。

## Event contract

普通会话通过 `AgentSession.events()` 消费 `AgentEvent`；以下是边界而非完整固定序列：

1. `agentStart` 后追加用户消息，并发出 `contextSnapshot`。
2. 每轮 `turnStart` 后，按需压缩上下文、修复孤立工具调用，再请求 provider。
3. `textDelta` / `thinkingDelta` 进入 `StreamingDeltaBuffer`，不逐字写持久模型。
4. assistant 完成时发出消息事件和快照；有工具调用则经过审批、执行工具，并进入下一轮。
5. 正常完成、取消或错误路径发出最终上下文快照和 `agentEnd`。

`AgentSession` 处理上下文与持久化；UI 将增量合并到 `liveTranscript`，
经文档控制器直达 JS，消息边界才提交正式 transcript。聊天室使用自己的发言缓冲和消息模型。

## Session format

JSONL 首行为 header，后续为带 `id` / `parentID` 的树形 entry，支持消息、模型变更、压缩和标签，存储于：

`~/.new-pi/agent/sessions/<project-hash>/<timestamp>_<uuid>.jsonl`

运行错误作为所属用户/摘要 entry 的可选 `transcriptErrors` 展示元数据保存，不进入 AgentMessage 或模型上下文。
AgentSession 在错误广播前保存，冷恢复按当前分支还原到原轮次；压缩隐藏原轮次时显示在摘要前。
旧文件兼容与失败重试边界见[错误持久化记录](dev-notes/2026-09-12-session-error-persistence.md)。

## Extension model

`NewPiExtension` 已定义，但当前仅要求 `id` 和 `displayName`；`NewPiMarkdownSkill`
通过 Markdown skill loader 向系统提示词注入指令。原生工具扩展、slash commands、
lifecycle hooks 仍是扩展方向，不是已经提供的动态插件框架，也没有 TypeScript/jiti 兼容层。

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

当前 profile 主路径使用 `ProviderCredentialResolver`，不是早期 Anthropic-only 的 `CredentialResolver`：

1. provider 对应的进程环境变量；开发环境文件仅补充未设置的变量。
2. `LayeredCredentialStore` 中的 UserDefaults。
3. 开启 Keychain 选项时，再尝试 Keychain。

保存凭据始终写 UserDefaults，启用 Keychain 时额外写入 Keychain mirror；
**默认不是 Keychain-only 存储**。App 配置入口为 **Settings → Providers**。

## Provider configuration (Phase 3.5)

Profiles 存储在 `~/.new-pi/agent/providers.json`；API key 使用独立凭据存储，
account 为 `provider:<profile-id>:apiKey`，不写入 profile JSON。

当前 API 适配层：

| 协议 | Implementation |
|---|---|
| Anthropic Messages | `AnthropicProvider` |
| OpenAI-compatible Chat Completions | `OpenAICompatibleProvider` |
| Responses API | `ResponsesAPIProvider` |

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

当前普通会话与聊天室均使用单文档 transcript：

```
NewPiViewModel / ChatRoomTranscriptAdapter → transcript items
NewPiTranscriptDocumentView.swift         → diff / ops / JS bridge
NewPiMarkdownWebRenderer.swift            → HTML 外壳与 CSP
transcript-document.js                   → 条目 DOM、滚动状态机、Warmer / Poller
markdown-renderer.js                     → per-root 块级增量 Markdown
transcript-document.css                  → content-visibility 与 intrinsic height 占位
```

- 每条会话一个 WKWebView，流式与最终正文使用同一文档路径；没有原生 Text → WebView 的完成态切换。
- 原生不消费内容高度，只发送内容操作和 `jumpTo` / `scrollToBottom` / `restoreAnchor` 等意图；JS 是文档内唯一滚动 writer。
- 旧 per-message 宿主、原生高度表和预热器已删除；文档内 `Warmer` / `Poller` 仍服务于虚拟化与保锚，不是遗留原生路径。
- Markdown 与高亮资源本地打包，不依赖 CDN。原始 HTML 和 Markdown 图片语法禁用，用户附件通过受控 `pi-att://` 展示。
- 当前决策与边界见 [UI 架构 ADR](ui-architecture-decision.md)；[旧滚动笔记](dev-notes/chat-scroll-layout.md) 仅作为迁移前背景。
- 图片输入 MVP 已实现：选择/拖拽/粘贴、预处理、附件落盘、三类 provider 编码和原生预览；发送前检查模型的图片能力标记。限制见 [图片设计记录](multi-modal-vision-plan.md)。
- 渲染产物持久化 replay 尚未接入生产单文档路径，不能把 runtime/WebView 热保活等同于磁盘 HTML replay。

## 会话切换与聊天室

普通会话由 `SessionRuntime` 独立持有 agent、事件任务和文档控制器。热切换保留 WebView/DOM，
后台生成继续运行；冷恢复后台读取 JSONL，并使用 generation 防竞态和持久锚点恢复。
空闲 runtime 按 LRU 淘汰，切换项目则结束旧项目的运行态。

聊天室通过 `ChatRoomRuntimeStore` 保活控制器，主路径复用 `AgentLoop`，但有独立的共享历史、
角色上下文与讨论/投票/执行/Review/完成阶段；仍保留 provider 兼容路径。
数据保存到 `~/.new-pi/agent/chatrooms/<id>/` 下的 `chatroom.json` 和 `messages.jsonl`，
不使用普通会话的分支树。切换聊天室视图可重建 WebView，但不会销毁正在运行的控制器。
详见 [聊天室设计](chatroom-design.md)。

输入草稿由各 `SessionRuntime` / `ChatRoomFlowController` 持有独立 `NewPiComposerDraft`，
输入面板直接观察草稿，父运行时及根列表不转发逐键通知。视图重建不清草稿，但 runtime 淘汰、
切项目或退出后的保留不在保证内；没有磁盘草稿持久化。实现与验证见
[草稿生命周期记录](dev-notes/2026-09-12-navigation-draft-lifetime.md)。

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
- CLI — `new-pi sessions list/show/export`；无参数显示 provider 状态，不提供交互式 Agent 对话

Resume restores provider profile from session header.

## Session branching (Phase 8 / P4-BRANCH)

JSONL entries form a tree via `id` / `parentID`. `SessionManager.syncMessages` incrementally appends new messages without destroying sibling branches. App UI exposes **Fork from here** on transcript rows; `AgentSession.fork(atMessageIndex:)` rewinds the active branch.

## Session export (Phase 8 / P8-EXPORT)

`SessionExporter` produces Markdown, plain text, or JSONL (via `JSONLSessionCodec`). App: toolbar Export menu. CLI: `new-pi sessions export <id> [--format markdown|json|text]`.

## Sub-agents (Phase 8 / P8-SUBAGENT)

`SubAgentTool` runs a nested `AgentLoop` with read + bash tools (no recursion). Registered in `AgentSessionFactory.codingSession`. Requires user approval like bash/write.

子 agent 继承审批与危险评估链。`AgentLoop.executeToolCalls` 当前将 `.parallel` 和
`.sequential` 都作为逐个 `await` 执行，不能把委派能力描述为已实现并行调度。

## 验证入口

- 核心测试：在 `Packages/NewPiCore/` 下执行 `swift test`。
- App 构建和 WebKit/UI 校验：[scripts/README.md](../scripts/README.md)。
- 文档中的历史测试记录仅证明当时结果，不代表当前 checkout 已通过全部验证。

## Phase roadmap

以下为早期里程碑记录，不代替当前 [TODO](TODO.md)。

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
