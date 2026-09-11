# API 指标监控设计（LLM Metrics）

> 指标采集与展示：设置页 Debug →「API 监控」。目的：把「用户感觉慢」精确定位到
> 具体阶段（网络 / 排队 / prefill / 思考 / 生成 / UI 渲染），并按 provider×model 横向对比。

## 存储

- 内存：`LLMMetricsRecorder`（actor 单例）环形缓冲最近 **500** 条（面板只看最新）。
- 落盘：`~/.new-pi/agent/metrics/metrics-YYYYMMDD.jsonl`（日滚动，每行一个 JSON，
  跨会话留存）。UI flush 只落盘 `>=50ms` 的，控制文件量。
- 启动：`NewPiViewModel.init` 调 `loadRecentFromDisk()`，从今日文件尾部（≤2MB）恢复
  最近 500 条，重启后面板仍能看到历史。

## 指标（字段短名 ↔ OpenTelemetry GenAI 对照）

一条 LLM 请求 = 一次 LLM API 调用（agent 一次 run 可能多轮 = 多条）。

| 本项目字段 | OTel GenAI 对应 | 含义 |
|---|---|---|
| `startedAt` | `gen_ai.client.operation.duration` 起点 | provider 计时起点，含凭据读取/编码；不等于实际 HTTP 发起时刻 |
| `runID` | — | 可选，关联 Session 一次发送及其多个 API 请求的本地时间线 |
| `responseAt` | —（TTFB 近似） | 收到 HTTP 响应头/流首字节 |
| `firstThinkingAt`/`lastThinkingAt` | — | 首个/最后一个 thinking delta |
| `firstTextAt` | — | 首个正文 delta |
| `lastTextAt` | — | 最后一个正文 delta；三种 provider 均记录，旧记录为 nil |
| `textDoneAt` | — | Responses 最后一次 `output_text.done`；不是请求完成 |
| `terminalAt` | — | Responses completed/incomplete/failed 解码时刻 |
| `endedAt` | `gen_ai.server.completion.duration` 终点 | 流结束（正常/错误） |
| `timeToFirstToken`（派生） | `gen_ai.server.time_to_first_token` | 首内容 token 延迟：网络+排队+prefill+思考准备 |
| `thinkingDuration`（派生） | — | 思考段时长（reasoning 生成耗时） |
| `textDuration`（派生） | — | 首正文到流结束，保留既有口径，包含协议尾段 |
| `textEmissionDuration`（派生） | — | 首正文到末正文的接收跨度 |
| `textTailDuration`（派生） | — | 末正文到 provider 标记结束，面板显示「尾」 |
| `textToTerminalDuration`（派生） | — | 末正文到 Responses 终态 |
| `terminalDrainDuration`（派生） | — | 终态到 provider 标记结束，不含指标落盘及 UI 处理 |
| `totalDuration`（派生） | `gen_ai.client.operation.duration` | 端到端总耗时 |
| `outputTokensPerSecond`（派生） | —（非独立测量的服务端 token 间隔） | 输出 token / textDuration，含协议尾段；输出 token 也可能含思考 |
| `inputTokens` | `gen_ai.usage.input_tokens` | 输入 token |
| `cachedInputTokens` | `gen_ai.usage.cached_tokens` | prompt cache 命中 |
| `outputTokens` | `gen_ai.usage.output_tokens` | 输出 token |
| `reasoningTokens` | — | 思考 token（部分模型，未提取处为 nil） |
| `contextWindow` | — | 模型上下文窗口（算占用 %） |
| `statusCode` | `http.response.status_code` | HTTP 状态 |
| `errorType` | `error.type` | cancelled / http_error / llm_error / network / stream_error |
| `costAmount`/`costCurrency` | — | 按 `ModelDefinition.pricing` 估算（缺失为 nil） |
| `providerName`/`model`/`vendor` | `gen_ai.provider.name` / `gen_ai.request.model` | 归属 |
| `thinkingLevel` | `gen_ai.request.reasoning_effort` | 配置的思考档位 |
| `mode` | `gen_ai.operation.name` | chat / responses / anthropic |

UI 侧指标：`UIFlushMetric`（flush 耗时 / 合并字符 / 积压）——回答「模型慢还是 UI 渲染慢」。

## 聚合（LLMMetricSummary）

按 provider×model 分组：请求数、错误率、**P50/P95 TTFT 与总耗时**、平均 token/s、
思考占比、cache 命中率、累计 in/out token、估算成本。

## 采集点

- `OpenAICompatibleProvider` / `ResponsesAPIProvider` / `AnthropicProvider` 的
  stream 循环：HTTP 响应到达、每个 thinking/text delta、结束（正常/错误）打时间戳，
  结束时构造 `LLMRequestMetric` 上报（含成本，Anthropic 无 profile 故成本 nil）。
- `NewPiViewModel.flushStreamingDelta`：每次流式 flush 后上报 `UIFlushMetric`。

内容不含 prompt（隐私），JSONL 无密钥。

2026-09-11 新增时间点均为可选字段，旧 JSONL 可直接解码。未记录 `lastTextAt` 时不臆造尾段。
`output_text.done` 只更新计时，不重发该事件中的全文、不产生 completed、不截断后续工具/错误/usage。
正文后无字的尾段可能包含合法协议事件，不能据此断言服务端纯等待，更不能静默超时后当作成功。

## 已知边界

- `reasoningTokens`：OpenAI 兼容/Responses usage 未细分提取时记 nil（后续可从
  `completion_tokens_details` 补）。
- 成本：依赖 profile 的 `ModelDefinition.pricing`；未配置价格的模型/Anthropic 记 nil。
- provider 层测不到「纯服务端推理/排队」时间（服务端不暴露时），TTFT 为网络+排队+prefill 合计。

## 发送到首字的分阶段诊断（2026-09-11）

仅看 `firstTextAt - startedAt` 不能解释“点击后多久可见”。现增加
`RequestLatencyTrace`，由 Session 的 `send` 方法入口创建，每次发送使用随机 `runID`。
日志 category 为 `latency`，格式如下：

```text
Request latency milestone
runID=<UUID> stage=firstProviderText elapsedMs=1234.567
```

`elapsedMs` 使用 `ContinuousClock`，从同次发送入口开始累计；不要用日志头的秒级时间算细分延迟。
每个阶段每次运行最多一条，状态集合有固定上限，不采样正文、不加入每 token 的日志。

| 相邻阶段 | 能定位的等待 |
|---|---|
| `sendEntered` → `sendAccepted` | 模型能力/附件校验、附件写入、原生发送准备 |
| `sendAccepted` → `promptReceived` | Task 调度及 Session actor 等待 |
| `promptReceived` → `agentStarted` | Session 启动、清理旧审批及 AgentLoop 调度 |
| `preparationStarted` → `preparationFinished` | 上下文压缩与历史修复 |
| `providerStarted` → `requestSent` | 读取凭据、编码请求、请求前日志等客户端准备 |
| `requestSent` → `responseHeaders` | URLSession 发起到 HTTP 响应头 |
| `responseHeaders` → `firstProviderText` | 到首个正文 delta 被解析；含网络/缓冲/服务端工作，不能独立细分 |
| `firstProviderText` → `firstConsumerText` | AgentLoop、Session 广播到常驻后台 UI 消费者 |
| `firstConsumerText` → `firstUIFlush` | MainActor 调度、flush 节流和首批合并 |
| `firstUIFlush` → `firstJSDispatch` | 原生 diff/编码、页面就绪、可见性门控与 JS 单飞等待 |
| `firstJSDispatch` → `firstDOMAcknowledged` | JS 执行及其 completion 回到原生；不是显示器上屏 |
| `firstJSDispatch` → `firstFrameCallback` | 应用正文后两次 RAF 的消息回到原生；只是浏览器帧机会代理 |
| `agentEnded` → `uiUnlocked` | 后台收到 Agent 完成到 MainActor 解除发送锁 |

`textDone`、`terminalReceived`、`providerEnded` 也加入相同时间线。
阶段是**首次到达**，多工具轮次的一次 run 只测首轮正文链路；每次 API 的时间仍看
`LLMRequestMetric`（通过 `runID` 关联）。`providerEnded` 可能早于整个 Agent 的完成。
自动压缩的内部 provider 不继承此 trace，避免它的首字覆盖真实答复的首字；
压缩总耗时记入 preparation 区间，原有 API 指标继续保留。

### 可见性和缺失阶段不能当成功

- 隐藏文档不会下发首字探针；恢复到可见且实际下发目标 assistant upsert 后才记录 dispatch。
- 首批 flush 时若没有绑定文档控制器，记录 `presentationUnavailable`，不假定正文已经呈现。
- 回调中保留 runID，旧页面 generation 的 JS completion 不会污染新页面；销毁/进程重建时
  取消未完成探针并标记 `presentationUnavailable`。
- 三秒仍未收到帧回调时记录 `frameNotObserved`，不重试、不改 UI、不推进 Agent 状态。
  该检查也需要 MainActor 调度，日志时刻不保证恰好三秒。
- 收到帧消息时还要检查 document.hidden 与原生窗口是否可见；不可见记
  `presentationUnavailable`，不记可见帧成功。它仍不证明目标条目在 viewport 内，
  也不证明 CA/WindowServer 或显示器已完成呈现。
- 用户事件等待 MainActor **之前**的时间仍不在 `sendEntered` 中；
  原始键盘/鼠标时间与实际像素呈现若需验证，仍需系统级采样，不能从这些代理指标臆造。
- 被拒绝的发送记录 `sendRejected`；错误记录 `failed`。缺少阶段说明流程未到达，
  不用假时间补齐。没有正文的工具请求可能没有首字相关阶段。

本轮验证包含：并发阶段去重/运行隔离、TaskLocal 跨 Session/AgentLoop/provider Task 继承、
压缩作用域隔离、旧 JSONL 兼容、真实 WKWebView 首字帧关联、隐藏文档延后探针和内容进程恢复。
