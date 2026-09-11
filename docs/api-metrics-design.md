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
| `startedAt` | `gen_ai.client.operation.duration` 起点 | 请求发出时刻 |
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
