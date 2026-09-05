# 聊天室 × Session 对话：技术方案对照与复用分析

> 2026-09-06。应「看看聊天室有什么可以复用 Session 对话技术」的调研需求，
> 对照 Session 对话的完整技术方案与聊天室现状，给出可复用项清单与建议路线。
> 结论先行：**文本渲染管线已复用（Phase 2 完成）**；下一层高价值复用是
> **详情组折叠 / Composer 输入框 / token 用量**；架构完全体是把角色发言迁移到
> `AgentSession`/`AgentLoop`——对话引擎的完全复用。

## 一、Session 对话技术方案盘点

### 引擎层（NewPiCore）

| 组件 | 职责 |
|------|------|
| `AgentLoop` | agentic 循环：streamAssistant（流式）→ executeToolCalls → 事件流 `AsyncStream<AgentEvent>`；内置 compaction 钩子、`AgentMessageHistoryRepair` 孤儿工具调用修复、steeringProvider 插话钩子 |
| `AgentSession` | 会话壳：`prompt`/`steer`（发言中插话队列）、审批门 `approvalGate`（新 run 前 `cancelAll` 防审批复活）、`abort`/`shutdown`、`attachPersistence`（事件驱动的增量 JSONL 落盘 + 慢持久化监控）、`fork`/branch、`updateConfig` 模型热切换、事件广播（含慢广播诊断） |
| `CompactionService` | 每轮 turn 前按窗口预算压缩上下文 |
| 工具链 | Read/Write/Edit/Bash + SubAgent + MCP 动态加载 |

### UI 运行时层（NewPiApp）

| 组件 | 职责 |
|------|------|
| `SessionRuntime` | 观测运行时：`transcript`、`isStreaming`、`streamingBubbleComplete`/`finalAnswerComplete`（状态提前收敛，不等 agentEnd）、token 用量（累计/本轮/速率滑动窗口）、**详情组状态机**（turn/marker/manualOverride 跨 rebuild 稳定）、**流式合并缓冲**（text/thinking delta 攒批 + 节流 flush）、LRU 会话缓存 |
| `NewPiViewModel` | 会话生命周期（后台线程构建、主线程组装）、keptAliveRuntimes 保活面板、模型热切换、provider 管理 |
| `NewPiSessionPanel` | 会话 UI：多行 Composer（高度自适应 + 图片附件/粘贴/拖拽）、user markers、审批 sheet、状态栏（token 速率等） |
| `NewPiTranscriptDocumentView` + JS | 单文档渲染管线：diff → ops → WKWebView（markdown-it/hljs、流式/最终双渲染、详情组折叠、fork、minimap、滚动状态机） |
| `ScrollPositionStore` | 滚动锚点持久化 |

## 二、聊天室现状对照

### 已复用 ✓

| 项 | 方式 |
|----|------|
| 单文档渲染管线（Phase 2 完成） | `ChatRoomTranscriptAdapter` → `NewPiTranscriptItem` → `NewPiTranscriptDocumentView`，与 Session 同一条 diff→ops→JS 链路 |
| markdown/工具卡/滚动/✦ 光标 | 随渲染管线免费获得 |
| `NewPiTranscriptItem` 类型 | 直接使用 |
| `ScrollPositionStore` | storeKey = chatroom UUID |
| `ContextTokenEstimator` | 预算提示与自动压缩共用 |
| 压缩语义 | `CompactionConfig.recommended` 与 Session 对齐（窗口×0.8 / 0.75 触发 / 保留 8 条） |

### 自建且与 Session 平行/重复 ✗

| 聊天室 | Session 对应物 | 差异要点 |
|--------|----------------|----------|
| `ChatRoomFlowController`/`ChatRoomRuntime` | `SessionRuntime`/`NewPiViewModel` | 平行运行时层；聊天室缺流式合并缓冲、详情组状态机、用量统计 |
| `ChatRoomTranscriptAdapter`（每次全量重算） | Session 增量 transcript 更新 + delta 攒批缓冲 | 聊天室在 provider 层做了 120ms 节流，两层节流可收敛为一 |
| `ChatRoomApprovalManager` + `ChatRoomApprovalSheet` | 审批门 + `NewPiToolApprovalSheet` + 策略/审计/危险评估 | 聊天室是简化版（读自动过/写审批），无审计、无危险评估 |
| `ChatRoomStore`（messages.jsonl 追加） | `JSONLSessionStore`（增量快照/fork/branch/慢写监控） | 聊天室故意保持简单（记录不删、展示完整），合理 |
| 聊天室自动压缩（发言间检查点） | `CompactionService`（turn 内压缩） | 语义不同：共享历史在 loop 外，压缩点不同——有意保留 |
| 4 个自制工具（read/write/list/search） | `BuiltInTools`（read/write/edit/bash）+ MCP | **行为不一致**：聊天室 read 256KB 截断 vs session read 报错；聊天室无 edit/grep/bash |
| 单行 `TextField` 输入 | `NewPiComposerScrollView`（多行/附件/自适应高度） | 未复用 |
| 无详情组（`detailTurnID` 恒 nil） | 详情组折叠（thinking/tool/中间 assistant 收进组） | **500 轮工具调用那次刷屏的直接解药** |
| 无用量统计 | `totalUsage`/`lastTurnUsage`/token 速率 | `ChatRoomLLMResponse` 目前丢弃 `UsageStats` |

## 三、可复用项与建议路线

### Phase A：组件级复用（低成本、直接收益）

1. **详情组折叠**（收益最大）：把 adapter 的 `detailTurnID` 从恒 nil 改为按「同一发言内的 thinking/工具卡」分组复用 Session 的详情组渲染——一次发言几十张工具卡（如 500 轮那次）会折叠成一行「处理详情」，彻底解决刷屏。
2. **Composer 输入框复用**：多行 + 高度自适应 + 图片附件，聊天室插话体验直接对齐 Session。
3. **token 用量显示**：`ChatRoomLLMResponse` 透传 `UsageStats`，角色气泡/状态栏展示，与预算横幅互为补充。
4. **流式节流收敛**：provider 层 120ms 攒批与 Session 的合并缓冲思路统一，二选一。

### Phase B：引擎级复用（架构完全体）——角色发言迁移到 AgentSession

「对话可复用」的完全体：**每个角色 = 一个 AgentSession**，发言 = 一次 `prompt` run。

直接获得的能力：
- **steering**：发言中插话（现在 userSpeak 只能排在两次发言之间）
- **审批统一**：复用 session 的审批 UI/策略/审计/危险评估，聊天室自制审批层可退役
- **工具链统一**：read/write/edit/bash + MCP，消除两套工具行为不一致
- `AgentMessageHistoryRepair`、增量持久化与慢写监控、usage 统计全部免费

迁移要点（难点如实列出）：
1. **共享上下文注入**：每个角色的 `AgentContext.messages` 需要构建共享历史——现有 `ChatRoomContextBuilder`（署名/合并/检查点）逻辑整体保留，只是产出喂给 AgentContext。
2. **压缩点变化**：AgentLoop 的 compaction 在 turn 内压「本角色上下文」，与现在的发言间检查点压缩语义不同。共享历史被各角色各自压缩后会产生分叉，需要决策：压缩摘要是否回写共享历史（建议：是，摘要作为检查点广播回 ChatRoom）。
3. **事件桥接**：AgentEvent 流 → 现有临时消息实时改写逻辑替换为消费 AgentEvent（textDelta/thinkingDelta/toolExecution* 一一对应，改造成本低）。
4. 多模型天然支持：每角色不同 `AgentLoopConfig.model`。

**触发条件建议**：当聊天室需要 MCP 工具、统一审批、或 steering 中任意一项时启动 Phase B；Phase A 可独立先行，两者不冲突（Phase A 的成果在 Phase B 中全部保留）。

## 四、明确不复用项

- **fork/branch**：聊天室无分支语义（决策 #13），不引入。
- **会话文件格式**：聊天室 messages.jsonl 保持追加式完整记录（决策：记录不删、展示完整），不迁移到 Session 的 branch 式存储。
- **审批简化语义**：读自动过/写审批是聊天室的产品决策（决策 #10/#18），Phase B 迁移时应保留该策略映射到 session 审批框架，而非照搬 coding agent 默认策略。
