# 长会话渲染性能：问题清单、复现证据与独立复核指南

> **用途：交给其他 Agent 独立验证，而不是要求接受本文结论。**
>
> 本文 §0–§10 保留 2026-09-11 修复前的调查与受控实验；其缺陷描述、源码片段和指纹是历史基线。
> **后续已实施修复，当前状态、代码入口及验证结果见 [§11](#11-修复实施与验证记录)。**
> 请把“机制确实存在”“能复现异常行为”“在真实使用中占主要耗时”视为三个不同命题。
> 本文明确区分它们，避免把源码中的潜在成本直接认定为用户实际卡顿的根因。

## 0. 给接手 Agent 的最短说明

请优先复核 **F01 冻结前缀误重建**，然后是 **F02 同值发布**。
这两项已有直接实验，验证成本低，不需要真实模型、不需要重读整个项目。

**review 当前工作区时请先读 §11，再对照历史问题；不要把旧版复现的失败预期直接套到修复后代码。**

接着按用户症状选择：

- 多个 Session 同时输出时更卡：F03、F02。
- 输出很长、跨很多段落或代码块后更卡：F01、F08。
- 聊天室特别卡、普通 Session 相对正常：F05、F09。
- 切回已经打开过的会话仍要等：F06，以及 §5 的视图生命周期边界。
- WebView 白屏后不自动恢复：F07。
- 流式期间或滚动期间持续唤醒：F04。

**本次未完成真实 App 的端到端性能归因。** 不应把以上条目写成“九个都已证明导致实际卡顿”。
不要先大改架构；先用本文的复现与反证条件确认问题，再决定最小修复。

### 0.1 推荐提交给 reviewer 的任务描述

```text
请复核 docs/dev-notes/2026-09-11-long-session-rendering-review.md。
目标是验证/反证，不是立即修复，也不是从零开始全仓库研究。

1. 先核验 HEAD 和目标文件是否变化。
2. 优先执行 F01、F02 的最小复现。
3. 对 F03–F09 分别判断：
   - 源码机制是否存在；
   - 实验是否真的覆盖该机制；
   - 能否推出文中声称的用户影响；
   - 是否已有其他代码抵消、限制或修复它。
4. 每条返回“确认 / 部分确认 / 反证 / 证据不足”，并给具体源码与实验输出。
5. 明确区分性能风险、正确性缺陷与有意的体验取舍。
6. 保持现有工作区改动不动，不运行真实模型，不修改用户会话或审批状态。
7. 没有实测的指标不得写成测量结论；Chromium 通过不得代替 WKWebView 验证。
```

## 1. 基线、范围与证据等级

### 1.1 时间与代码版本

| 阶段 | 基线 | 内容 |
|---|---|---|
| 原生侧调查、Combine 实验、原生基准、11 项 Core 回归 | `875ccb1` | 已包含“冷加载跳过无用高度读取”修复 |
| JS 最小复现与真实 WKWebView 复核 | 2026-09-11 约 04:49–04:52 | 当时还有其他审批相关工作区改动；渲染器 JS 与原生 diff 核心未变 |
| 本文写作时重新核验 | `4b49812a903a8ec91ab5dd076923ec486efcf404` | 包含后续审批 UI 与 composer IME 修复 |

调查期间仓库由其他工作继续更新。本文重新检查了 `875ccb1..4b49812`：

- `markdown-renderer.js`、`transcript-document.js`、`transcript-document.css`、
  `NewPiViewModel.swift`、`NewPiTranscriptDocumentView.swift`、token 估算器、
  `TranscriptStreamingDOMChecks.swift` 在这一提交区间没有变化。
- `dee1ff8` 调整聊天室审批 UI、授权记忆与审计；没有改变本文关注的预算计算或流式消费所在 actor。
- `4b49812` 修改 composer 对 IME marked text 的处理；不是本文 F02 所指的 runtime 发布去重修复。
- `NewPiApp.swift` 和 `ChatRoomLoop.swift` 的行号发生位移，因此本文优先给**文件 + 符号名**，行号只是定位辅助。
- 写作时仍有其他未提交的工具快照相关改动和测试目录；本文不分析、不更改这些内容。

### 1.2 调查范围

主要文件：

| 文件 | 本次关注点 |
|---|---|
| [markdown-renderer.js](../../NewPiApp/MarkdownRenderer/markdown-renderer.js) | 块切分、冻结前缀、流式尾块、最终渲染与代码高亮 |
| [transcript-document.js](../../NewPiApp/MarkdownRenderer/transcript-document.js) | DOM 条目、滚动状态机、Poller、Warmer、上报 |
| [transcript-document.css](../../NewPiApp/MarkdownRenderer/transcript-document.css) | `content-visibility`、估算高、折叠布局 |
| [NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift) | 全量签名 diff、JS 投递、状态回传、内容进程恢复 |
| [NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift) | SessionRuntime、后台消费、flush、保活、恢复 |
| [NewPiChatView.swift](../../NewPiApp/NewPiChatView.swift) | Session 面板生命周期、可见性、观察关系 |
| [NewPiApp.swift](../../NewPiApp/NewPiApp.swift) | ChatRoomDetailView、预算、跨类型切换 |
| [NewPiChatRoomStore.swift](../../NewPiApp/NewPiChatRoomStore.swift) | 详情与侧边栏通知、运行时生命周期 |
| [NewPiChatRoomTranscriptAdapter.swift](../../NewPiApp/NewPiChatRoomTranscriptAdapter.swift) | 全量消息适配与稳定条目 ID |
| [ChatRoomLoop.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomLoop.swift) | MainActor 消费、上下文预算 |
| [ChatRoomSpeechBuffer.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomSpeechBuffer.swift) | 120ms 消费端合并、尾部冲刷 |
| [ContextTokenEstimator.swift](../../Packages/NewPiCore/Sources/NewPiCore/Compaction/ContextTokenEstimator.swift) | Unicode scalar 全量扫描 |
| [AgentSession.swift](../../Packages/NewPiCore/Sources/NewPiCore/AgentSession.swift) | 恢复时附加持久化、事件与提交边界 |

附带核验了用户标记的 [ModelTypes.swift](../../Packages/NewPiCore/Sources/NewPiCore/ModelTypes.swift)：
它定义模型配置、用量和停止原因，不是渲染器实现。`ModelConfig.maxTokens` 默认值为 8192；
`UsageStats` 是模型返回用量的累加结构，不能直接替代“当前有效上下文”的估算。
不要因为预算全量扫描有成本，就把它改成累计 `inputTokens`：两者含义不同。

### 1.3 证据等级

| 标记 | 含义 | 不代表什么 |
|---|---|---|
| S：源码确认 | 当前调用链和条件分支可直接确认 | 不代表已测真实耗时 |
| D：确定性实验 | 调用次数、通知数、身份等可重复结果 | 不代表实际帧率或 CPU 百分比 |
| W：真实 WKWebView | 使用项目本地 JS/CSS，在 WebKit 内验证 | 不代表包含完整 SwiftUI 导航、GPU 呈现 |
| M：微基准 | 对指定 fixture 与函数测量耗时 | 不代表真实用户数据或整页延迟 |
| H：历史实测记录 | 引用仓库已有复盘中的实验 | 不代表本次重新跑过相同场景 |

建议优先级不是安全漏洞严重度：

- P1：优先验证/修复，有明确异常机制或可能造成明显体验损害。
- P2：有冗余成本或规模风险，应结合实际规模排序。
- 待验证：不能作为“已确认实际故障”提交修复。

### 1.4 结论总表

| ID | 问题 | 建议优先级 | 证据 | 当前能下的结论 |
|---|---|---|---|---|
| F01 | 正常尾块完成误触冻结前缀全量重建 | P1 | S + D + W | 内部冻结块确实被重建；特定正常分块序列呈二次增长 |
| F02 | 流式 flush 同值赋值仍发布 SwiftUI 通知 | P1 | S + D | “同值不发布”的注释错误；隔离不完整 |
| F03 | 隐藏保活 Session 继续投递、请求绘制 | P1，需场景验证 | S + H | 缺少可见性门控；实际新增渲染成本尚未在当前 App 重测 |
| F04 | Warmer 暂停分支持续零延迟自调度 | P2 | S + D | 暂停了工作，但没有停止轮询 |
| F05 | 聊天室 UI 重复全量估算上下文 | P2 | S + M | 同一预算有重复调用路径；成本随有效历史增长 |
| F06 | 命中保活也先读盘、解码 | P2 | S | 热路径存在确定的多余 I/O/解码；额外切换竞态尚需动态测试 |
| F07 | 内容进程恢复没有主动补上最新快照 | 待验证，若确认优先处理 | S | 恢复分支本身没有保证重放；未做终止回调动态复现 |
| F08 | 每批全历史签名、完整当前正文编码 | P2/规模风险 | S + M | 全量扫描确实存在；已有普通规模测量不足以解释秒级卡顿 |
| F09 | 聊天室消费仍依赖 MainActor | 待验证/架构风险 | S + H | 普通 Session 的后台合并没有覆盖聊天室；未复现当前分钟级积压 |

## 2. 必须先知道的架构事实与历史修复

### 2.1 当前是单文档，不是每消息一个 WebView

当前每个会话文档用一个 WKWebView：

```text
provider 事件
    |
    +-- 普通 Session：后台 delta 合并 -> MainActor 节流 flush
    |                                      |
    |                              live transcript 影子
    |                                      |
    |                                applyLive
    |
    +-- 聊天室：MainActor 消费 -> 120ms 合并 -> runtime.messages 发布
                                               |
                                      详情 body / adapter
                                               |
                                           SwiftUI apply
    |
    v
Coordinator：transcript 全量签名比较 -> 少量 ops
    |
    v
evaluateJavaScript -> transcript-document.applyOps
    |
    +-- 条目 DOM 与分组
    +-- assistant article 的 Markdown 实例
    +-- Scroll / Poller / Warmer
    +-- JS 状态回报 -> 原生 ObservableObject
```

原生侧不消费内容高度，不应为了本次问题重新引入旧的逐消息高度表、滚轮转发或窗口化路径。
`content-visibility` 减少离屏布局/绘制，并不自动免除 JS 构建全部 DOM、解析 Markdown、
原生签名计算或源码字符串复制的成本。

### 2.2 不要把这些已修复项重新列为待办

| 提交 | 已有修复 | 本文如何使用它 |
|---|---|---|
| `e173f11` | 删除旧 per-message 路径 | 不建议恢复旧双路径 |
| `8d7eb5c` | 普通 Session 的 delta 消费移下 MainActor | 承认其效果，F02/F03 是仍存在的其他成本 |
| `74663c8` | 钉底宽限期、聊天室发送钉底 | 不把“完全未调用钉底”当现状 |
| `aad8608` | 流式 assistant 强制 `contentVisibility = visible` | 旧流式 CV 冻结问题已有修复 |
| `e7b1daf` | 聊天室显式流式身份、尾部定时冲刷、中断保留 | 不建议重做这些已实现能力 |
| `0c5d8fc` | 聊天室正文通知不再传播到列表 Store | 不把列表每批重刷当作当前未修复问题 |
| `875ccb1` | `reportHeight == false` 时不读取无用旧高度 | 冷加载逐 article 无用测高已修复 |
| `4b49812` | composer 尊重 IME marked text | 输入法未提交文本被覆盖的问题不能再按旧代码认定 |

重要文档：

- [流式卡顿复盘](../streaming-stall-postmortem.md)：区分事件积压、主线程阻塞、图层提交、布局冻结。
- [冷加载无用高度读取修复](./2026-09-11-transcript-cold-load.md)：500 条历史的受控测量及其边界。
- [聊天室性能基线与列表隔离](./2026-09-11-chatroom-render-performance.md)：适配、签名、Store 通知。
- [聊天室流式正确性修复](./2026-09-09-chatroom-stream-rendering.md)：120ms 合并与显式身份。
- [滚动跳变复盘](./2026-08-30-transcript-scroll-jump.md)：WebKit 的 CV/RO 与异步滚动限制。

较早的 [Session 即时恢复方案](../session-switch-instant-resume-plan.md) 和
[渲染产物重放方案](../rendered-result-replay-plan.md) 包含旧 per-message 架构前提。
可以用来理解用户诉求，但不能据其推断当前已经有 HTML 缓存、快照兜底或逐消息高度管理。

## 3. 分项分析

### F01：正常流式尾块变化，被误判为冻结前缀被编辑

**位置**

- [markdown-renderer.js](../../NewPiApp/MarkdownRenderer/markdown-renderer.js)
- `createMarkdownRenderer` 内的 `renderStreaming`。
- 写作基线约第 447–465 行；关键条件为：

```javascript
const frozenLimit = blockCount - 1;
// common 是上一批与本批逐块内容相同的公共前缀长度
if (common < frozenLimit && common < renderedBlocks.length) {
  while (root.firstChild) {
    root.removeChild(root.firstChild);
  }
  renderedBlocks = [];
  common = 0;
}
```

**触发条件**

上一批尾块尚未完成；下一批既补完该尾块，又开始了新块。
这是正常追加，不需要编辑、撤销、fork 或 provider 出错。

两批原始正文：

```text
第一批：
# Frozen heading

partial

第二批：
# Frozen heading

partial completed

next
```

**逐值推演**

| 变量 | 第二批时的值 |
|---|---:|
| 上一批块数 `renderedBlocks.length` | 2 |
| 本批块数 `blockCount` | 3 |
| 公共前缀 `common` | 1 |
| 按本批计算的 `frozenLimit` | 2 |
| `common < frozenLimit` | true |
| `common < renderedBlocks.length` | true |

第一块标题完全没有变化，第二块原本就是可变尾块。
但比较边界使用了**本批**冻结范围，从而把**上一批**可变尾块的正常变化认定为冻结前缀分叉。
结果是标题等全部旧块也被删除重建。

**已经做过的验证**

1. 直接执行当前 JS，在最小 DOM 替身里计数 `markdown.render` 调用：
   - 两批示例：冻结标题节点身份不保留，总渲染调用 5 次（第一批 2 次、第二批 3 次）。
   - 连续 100 个块：累计 5,050 次块渲染。
2. 派生现有 WKWebView 验证 harness，在真实 WebKit、真实本地 markdown-it/hljs 下复核：

```json
{
  "probe": "real WKWebView frozen prefix",
  "frozenPrefixNodePreserved": false,
  "finalBlockCount": 3,
  "textPreserved": true
}
```

**复杂度结论与边界**

100 块实验的序列是：每批补完旧尾块，并追加一个新尾块。
在这个序列中工作量为 `1 + 2 + ... + 100 = 5050`。
如果块大小大致固定，块渲染次数随块数呈二次增长。

不能说“任何 100 块回答都一定渲染 5,050 次”：

- provider 分批位置、原生 flush 合并位置会影响是否进入该条件；
- 如果下一批新增块时旧尾块内容恰好没有变化，可能不会全量回退；
- 只有一个超长尾块时，这个特定条件不触发，但仍可能每批重解析整个尾块，属于另一个成本。

最小 DOM 替身验证的是调用次数和节点操作，不是布局耗时。
真实 WKWebView 实验补上了节点身份被替换的验证，但本次没有测该异常在完整 App 中增加多少毫秒。

**可能的用户症状**

- 长回答在换段落、结束代码块附近不顺畅。
- 旧代码块被反复解析、高亮，长回答后半段工作量上升。
- 内部节点替换可能影响选择或交互连续性；这项用户影响尚未单独测试。

**为什么现有测试没挡住**

[TranscriptStreamingDOMChecks.swift](../../scripts/validation/TranscriptStreamingDOMChecks.swift)
断言 `node('answer') === answer`，验证的是外层消息条目。
本问题保留外层 article/消息容器，替换的是内部 `.markdown-block`，所以测试仍通过。
现有性能 fixture 的活动正文主要是 `"Streaming" + " delta"`，没有覆盖“旧尾块变化 + 新块出现”。

**建议修复方向，不是已实施方案**

- 根据上一批哪些块已经不可变来判定“冻结前缀被修改”，不要把上一批尾块包括进去。
- 保留真正不变的前缀；从发生变化的旧尾块继续更新。
- 不能简单删除所有回退保护：源缩短、旧块被改、fork/重建仍需要正确处理。
- 对“尾块变为冻结块”是否需要补高亮进行独立验证，不能为了节点稳定让最终样式不正确。

**必须补的回归测试**

- 旧尾块补完并开始新块：早于旧尾块的节点身份不变。
- 一批新增多个段落：不重建旧冻结前缀。
- 代码围栏未闭合到闭合，再新增正文。
- 真正编辑旧冻结块时输出正确。
- 源缩短、清空、最终 `renderFinal` 的行为保持正确。
- 分批策略变化时最终 Markdown 内容一致。

**反证条件**

若实际目标版本没有上述判断，或“只补完尾块”的输入下冻结前缀身份始终保留，应先确认版本。
若要反证用户影响，需要测完整真实输出分批，而不是只证明最终文字没有丢失。

**Git**

`git blame` 将关键条件定位到 `4e57eef`，不是 `875ccb1` 的新回归。

### F02：同值 `@Published` 赋值，破坏了流式隔离的前提

**位置**

- [NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)：
  `SessionRuntime` 属性声明约第 190–212 行；
  `flushStreamingDelta(on:)` 约第 2357–2364 行。
- [NewPiChatView.swift](../../NewPiApp/NewPiChatView.swift)：
  `NewPiSessionPanel` 观察 `runtime`。

关键代码：

```swift
// 注释声称：@Published 同值不重复发布，SwiftUI 无额外刷新
runtime.agentActivity = .writing
runtime.streamingBubbleComplete = false
runtime.finalAnswerComplete = false
```

**确认的问题**

这些属性是 Combine `@Published`。
它没有自动执行 Equatable 去重；再次赋相同值仍会触发发布。
同一函数中对 ViewModel 自身 `agentActivity` 的赋值有 `!= .writing` 检查，
但对 runtime 的上述三个赋值没有。

**实验**

使用真实 Combine 的三个同类型用途的发布属性，连续执行 100 轮同值赋值：

```text
100 same-value flushes: objectWillChange=300
```

这是验证 `@Published` 语义的最小实验，不是编译了完整 `SessionRuntime` 的端到端通知计数。
结合实际属性声明与实际无条件赋值，足以反证注释“同值不会发布”。

**影响链**

```text
后台 delta 合并
  -> MainActor flush
  -> 三个同值 @Published 赋值
  -> runtime.objectWillChange
  -> 观察 runtime 的 SessionPanel 失效
  -> 可能重新计算 markers / tint / composer / representable 输入
```

`applyLive` 期间 Coordinator 的 `liveDriven` guard 能阻止陈旧 SwiftUI 快照覆盖新内容，
但它只保护 JS 内容投递，不代表 SwiftUI 视图重算本身不存在。

**必须保留的限定**

- 300 次通知不等于 300 次 body 计算、布局、绘制或 CA transaction。
- SwiftUI 可以合并同一更新周期的通知。
- 本次没有用 Instruments 证明移除这三次发布后完整 App 的 GPU 等待下降多少。
- `4b49812` 保护 IME 未提交文本，是另一层修复；不能说这一输入法问题仍未修。

**同类回传成本**

[NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift)：

- `updateScrollState` 每次无条件赋 `isNearBottom`。
- `updateMarkerPositions` 每次无条件赋 `markerPositions`。

JS `reportScrollState` 有**整个 payload**去重，并非毫无去重。
但正文高度或 scrollTop 改变时会回传，即使 `nearBottom` 仍为 true。
原生只需发布 nearBottom 的变化，不必因其他字段改变重新发布同值 Bool。

JS `reportTurnOffsets` 有 250ms 调度合并，但没有 offsets 内容判等。
同样可能把相同 marker 字典重新发布。

**建议**

- 对 UI 状态做真实变化判断。
- 位置持久化与 UI 派生状态发布分开：不能为了不刷新 UI 就停止保存有效锚点。
- 不要靠删掉 `@Published` 让状态栏永久不更新。
- 新测试区分“第一次状态迁移有通知”和“后续纯正文增量没有同值通知”。

**Git**

runtime 三次赋值与错误注释来自 `8d7eb5c`。
这不否定该提交把逐 delta 消费移出 MainActor 的修复价值。

### F03：隐藏保活文档没有投递门控

**位置与链路**

1. [NewPiChatView.swift](../../NewPiApp/NewPiChatView.swift)：
   `ForEach(viewModel.keptAliveRuntimes)`，用 `.opacity(0)`、hit testing 和 zIndex 区分活跃面板。
2. 同文件 `NewPiSessionPanel.onAppear`：
   `runtime.docController = docController`。
3. [NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)：
   `flushStreamingDelta` 以 controller 是否存在判断 live；
   `storeFlushTarget` 没有检查当前是否活跃，直接 `applyLive`。
4. [NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift)：
   `send` 执行 `evaluateJavaScript`，然后 `webView.setNeedsDisplay(.infinite)`。

**已确认与未确认**

- 已确认：应用代码没有“不可见则停止文档更新”的门控。
- 已确认：运行态与面板都在保活时，后台内容会继续走投递路径。
- 未确认：当前操作系统/WebKit 对每个隐藏页实际进行多少布局、合成与 surface 分配。
- 未确认：当前真实多会话场景的 CPU、内存、GPU 等待增量。

历史 [流式卡顿复盘](../streaming-stall-postmortem.md) 把并发隐藏 WebView 列为放大器。
更早的 [即时恢复方案](../session-switch-instant-resume-plan.md) 则把后台继续渲染记为有意取舍，
以换取切回零等待。应视为需要用新测量重新评估的取舍，不是从一开始就毫无理由的代码。

**复核场景**

- 仅前台 A 输出。
- A 输出，切到保活 B，A 继续输出。
- A/B/C 同时输出，仅一个可见。
- 切换到聊天室，普通 Session 容器被移除的场景单独测，不能假定与 `.opacity(0)` 相同。

观察：

- 每个文档 JS 批次数、投递字节与完成时间。
- 实际可见面板首屏和切回延迟。
- CPU、内存、CA/RenderBox 等待。
- 后台任务是否继续、审批是否能在切回后处理。

**建议**

后台 Agent 和状态累积应继续，隐藏文档可以暂不投递。
切回时基于最新状态做一次一致同步，而不是逐个重放所有过时中间帧。
实现必须验证：

- 运行中切出/切入不丢尾字。
- 背景结束、背景错误、背景审批均正确。
- 恢复锚点不被强行钉底覆盖。
- controller 未挂载、页面仍加载、被淘汰时的行为可解释。

不能仅把 `applyLive` 改成 `guard active else { return }` 就算完成：
影子态提交、可见性变化时的补投递以及 live 独占状态也需要一致处理。

### F04：Warmer 的“暂停”实际是不断安排下一次检查

**位置**

[transcript-document.js](../../NewPiApp/MarkdownRenderer/transcript-document.js)：
`Warmer.schedule`、`Warmer.runChunk`，约第 345–374 行。

```javascript
if (Scroll.intent === "userScrolling" || Scroll.intent === "jumpingToTarget") {
  this.schedule();
  return;
}
if (forkLocked) {
  this.schedule();
  return;
}
```

`schedule()` 使用 `setTimeout(..., 0)`。
回调在执行 `runChunk()` 前把 `pending` 设回 false，因此暂停分支可以立即再次调度。

**实验**

对真实源码做仅在内存中存在的测试入口暴露，以受控队列代替计时器。
设置 `forkLocked = true`，甚至不提供任何行，然后执行最多 1,000 次回调：

```json
{"probe":"warmer paused with no rows","callbacks":1000,"stillPending":1}
```

零行 fixture 只用于隔离调度分支；生产里通常是在已有内容的 `applyOps` 后唤醒预热。
暂停判断发生在零行退出判断之前，因此能最小化地证实持续重排队。

**影响及限定**

- 可以确认不必要的定时唤醒。
- 不能把 `setTimeout(0)` 解释为真实每秒无限次回调：WebKit 会钳制定时器频率，也可能节流后台页。
- 没有实测 CPU 百分比，不应宣称“这一项占满一个核心”。
- 与 F03 同时发生时，多个文档各自可能拥有一条暂停轮询链。

**改进方向**

暂停时直接结束本轮调度，由状态变化重新唤醒：
流式结束、滚动结束、跳转结束、新增待预热内容等。
现有 `scrollend`/debounce 路径已有 `Warmer.schedule()`，可作为复用点。
但必须确认 `forkLock true -> false` 即使没有新的 upsert，也能唤醒待处理预热，
不能因为去掉轮询而让预热永远不恢复。

**Git**

- 用户滚动让路时重新调度的逻辑可追溯到 `cd20603`。
- 流式锁定时重新调度来自 `d6edcd6`。

### F05：聊天室详情重复进行全量 token 估算

**位置**

[NewPiApp.swift](../../NewPiApp/NewPiApp.swift)，写作基线：

- `ChatRoomDetailView.body` 第 1570 行读取 `contextBudgetWarning`。
- 状态栏约第 1833 行读取 `chatroomContextText`。
- `contextBudget` 约第 1945 行；调用估算约第 1964 行。
- `contextBudgetWarning` / `chatroomContextText` 都重新读取计算属性 `contextBudget`。

[ChatRoomLoop.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomLoop.swift)：
`ChatRoomContextBuilder.estimatedTokens` 约第 850 行；
内部遍历 `effectiveHistory`，调用
[ContextTokenEstimator.swift](../../Packages/NewPiCore/Sources/NewPiCore/Compaction/ContextTokenEstimator.swift)
的 Unicode scalar 扫描。

**准确的触发前提**

- 聊天室有可解析的模型配置和有效 context window；否则预算计算会提前返回 nil。
- 正文或其他状态使详情 body/相关子树重算。
- 两个预算展示入口都求值时，会重复估算；不是每个原始 token 必然精确执行两次。
- 已有有效压缩检查点时，扫描的是检查点之后的有效历史，而非所有展示历史。

**为什么可能影响输入/滚动**

预算是 UI 同步计算，并非 Markdown 内核工作。
当详情在 MainActor 上求值时，大量历史扫描会占用主线程。
这解释了一种可能情况：JS apply 很快，但输入或切换仍不顺畅。
本次没有测当前完整 App 的 body 实际频率，因此只确认机制和函数成本。

**微基准结果**

每个场景 500 条合成消息，无压缩摘要/检查点。
两次相同预算估算视为一份样本，预热 2 次，计时 20 次。
使用排序后的第 10 个值作近似 P50、第 19 个值作 P95；不是高精度统计结论。

| 场景 | UTF-8 正文字节 | 优化编译 P50/P95 ms | Debug Core P50/P95 ms |
|---|---:|---:|---:|
| ASCII，短历史正文 | 560,000 | 1.459 / 1.628 | 11.420 / 12.138 |
| 中文，短历史正文 | 1,200,000 | 2.716 / 3.510 | 20.692 / 21.720 |
| ASCII，扩大十倍 | 5,600,000 | 12.859 / 13.746 | 110.823 / 117.720 |
| 中文，扩大十倍 | 12,000,000 | 25.331 / 27.698 | 216.969 / 227.245 |

**编译口径**

- 优化组：提取当前 `estimatedTokens/effectiveHistory` 和完整 token 估算器源码，
  与探针以 `swiftc -O` 编译；模型类型链接已有 Debug Core 对象。
  这是对关键估算算法的优化构建测量，**不是整个 Release App**。
- Debug 组：探针以 `-O` 编译，直接调用已有 Debug Core 中的算法。
- 两组不能简单分别贴成“正式版 App”和“Xcode App”的整机耗时。
- 原始临时探针已清理；附录提供重建 fixture 的代码和编译说明。

**特别重要的规模限制**

12MB 中文 fixture 对应单次约 400 万估算 token，1.2MB 对应约 40 万。
这可能明显超过实际配置的 context window；正常自动压缩会限制有效历史规模。
因此大样本证明**算法随输入增长的成本**，不证明正常生产必然长期处理这么大的有效上下文。
应增加 32k/128k/200k 等实际窗口内的场景，并验证加载旧历史、压缩前、配置不可用等边界。

[ModelTypes.swift](../../Packages/NewPiCore/Sources/NewPiCore/ModelTypes.swift) 的默认输出上限
8192 也意味着：不能把 100 个长块或 12MB 历史都描述为默认单次响应的典型规模。
历史累计、模型可配置上限和一次生成上限是不同维度。

**建议**

1. 先让一次 UI 更新共享一次预算计算。
2. 再考虑缓存已提交历史的估算，仅对变化尾部更新。
3. 缓存失效必须覆盖压缩摘要/检查点、消息修改、删除、中断标记和模型预算变化。
4. 不要用累计 usage 直接替代有效历史估算，也不要为了提速删除 CJK 加权规则。

**反证条件**

如果实际 SwiftUI 求值并没有重复执行两个入口，重复次数的说法应收窄；
但全量单次扫描的成本仍可单独成立。
如果真实窗口内成本始终很低，应降低这一项相对优先级。

### F06：保活命中前仍完整读取历史

**位置**

[NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)：

```swift
// resumeSession，约第 1049 行
let context = try await Task.detached(priority: .userInitiated) {
    try JSONLSessionStore().load(from: fileURL)
}.value
await beginSession(restoredContext: context, fileURL: fileURL)
```

真正的保活判断在 `beginSession` 约第 1263 行：

```swift
if let fileURL, let existing = runtimes[fileURL.path] {
    // 复用已有 runtime
}
```

**确定的结论**

通过 `resumeSession` 恢复另一个会话时，即使缓存命中，也会先等待 JSONL 完整加载/解码。
读取位于后台，不代表用户切换无等待；它仍在激活目标 runtime 的依赖链上。
`beginSession` 内“复用时不读文件”的局部注释不能描述整个恢复入口。

**额外的冷恢复重复工作**

冷构建后会调用
[AgentSession.attachPersistence](../../Packages/NewPiCore/Sources/NewPiCore/AgentSession.swift)
（约第 246 行），它又执行一次 `jsonlStore.load(from:)`。
因此当前入口已经解码的会话可能在附加持久化时再次读取/解码。
本次没有测真实 SessionManager 恢复耗时，也未计算这一重复读取的实际占比。

**与快速连点相关的待验证正确性问题**

`sessionSwitchGeneration` 在 `beginSession` 开头才递增，晚于首次文件读取。
可能的时序：

```text
点击 A -> A 的首次 load 很慢
点击 B -> B load 较快 -> beginSession(B) 取号并激活
A load 完成 -> beginSession(A) 此时才取得更新的号
```

这可能使最后完成读取的旧请求被当成最新请求。
热命中分支还有 `await existing.session.attachedSessionHeader`，其返回后没有同样的 generation 校验。
这些是源码推演，**未完成受控延迟的动态验证**，应与“确定有多余读取”分别给结论。

**建议验证**

- 对已经打开并保活的目标，计数 `JSONLSessionStore.load`；期望热切换入口不需要它。
- 对冷恢复计数读取/解码总次数，避免只测其中一层。
- 用受控文件加载替身构造 A 慢/B 快，不用制造真实磁盘故障。
- 如果接手者改请求序号，验证项目切换、冷构建、热命中以及旧任务收尾都不会误激活。

**修复方向**

热路径优先；只有 miss 才读历史。
请求身份在首次异步操作之前建立；每个有可能改变活跃状态的 await 返回点都按同一规则核验。
冷恢复可传递已经加载的持久化上下文，但要保证 branch/leaf/header 不丢失。

### F07：内容进程终止后的重放缺少快照来源

**状态：源码级高置信疑点，尚未动态复现，不纳入“已复现故障”清单。**

位置：[NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift)：

- `pendingSnapshot` 第 146 行。
- `applyInternal` 第 244 行左右。
- `didFinish` 第 444 行。
- `webViewWebContentProcessDidTerminate` 第 454 行。

**控制流**

1. 页面未加载时，`applyInternal` 才把 snapshot 放进 `pendingSnapshot`。
2. 页面完成加载，`didFinish` 取出 pending 并把它清为 nil。
3. 已加载时的新快照直接进入 `applyLoaded`；没有单独保存“最新完整快照”。
4. 内容进程终止回调清空签名、顺序和 fork 锁状态，再 `loadShell()`。
5. 没有在该回调里设置新的 `pendingSnapshot`。
6. 如果重建期间没有外部 `apply/applyLive`，下次 `didFinish` 没有内容可以重放。

因此注释“重建外壳 + 全量重放”只保证了外壳重建以及**下次有新快照时**不被旧签名挡住，
没有在该分支本身保证主动重放。

**限制**

- 活跃流式页下一批 `applyLive` 可能补上 pending，掩盖问题。
- SwiftUI 的其他失效可能触发 `updateNSView` 并恢复内容。
- 因此不能无条件声称“任何进程终止后都会永久白屏”。
- 本次未杀 WebContent 进程，也未在真实 Coordinator 上完成模拟终止回调实验。

**建议的低风险验证**

基于 [TranscriptColdLoadChecks.swift](../../scripts/validation/TranscriptColdLoadChecks.swift) 的 `ColdPage`：

1. 用真实 Coordinator 加载合成 500 条历史，等待正常 apply 完成。
2. 不再产生新的 SwiftUI/apply 输入。
3. 直接调用 `page.coordinator.webViewWebContentProcessDidTerminate(page.webView)`，
   模拟恢复分支，不杀任何用户进程。
4. 等待一次新的导航完成，检查 `.ti` 行数和新增 apply 计数。
5. 再显式提交一次相同快照，观察是否恢复。

该测试只验证**恢复回调的完整性**，不验证真实 OS 终止如何发生。
注意 `ColdPage.loaded` 是自定义状态；重载前要重置或使用导航计数，避免误把第一次加载当第二次。
其 `sessionID == nil` 是为了不写用户滚动位置；若验证锚点恢复，应另行处理测试存储，
不要把 nil 分支的缺失恢复标记误当成生产有 sessionID 的相同行为。

**建议**

保留可重放的最新 snapshot，恢复时显式排入一次重放。
只保存字符串签名不能重建条目内容与元数据。
验证流式影子比已发布 transcript 更新时，重放不会倒退。

### F08：原生 diff 与跨进程负载仍随内容体积增长

**位置**

[NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift)：

- `applyLoaded` 第 263 行：每次遍历全部 items，重建 order/signatures/ID 集合。
- `signature` 第 337 行：拼接 kind、metadata、speaker 和完整 `item.body`。
- `upsertOp`：变化条目发送完整 `body`。
- `send` 第 420 行：ops 序列化，再把 JSON 字符串编码成 JS 字面量。

补充：[NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)
的 `storeFlushTarget` 每次还全量计算 `transcriptTintHues`；
活动正文通过 `last.body + delta` 生成新字符串。

**正确的表述**

- 原生每批有全历史扫描，不能称为“端到端只处理 delta”。
- 只给变化条目发 upsert 已经避免全部历史都跨进程发送。
- 但变化的长回答自身每批仍完整编码、传输、在 JS 分块。
- Swift 字符串分配/比较有实现优化，实际复制量应测量，不用理论上界代替 profiler。
- 双重 JSON 编码是当前安全边界的一部分，不能为了性能直接拼接不受信任正文。

**本轮实际运行的现有原生基线**

使用 [check-chatroom-performance.sh](../../scripts/validation/check-chatroom-performance.sh)，
设置 `NEWPI_EXPECT_FILTERED_NOTIFICATIONS=1`：

| 场景 | 消息/条目 | 适配 P50/P95 ms | 签名 P50/P95 ms | Store/详情通知 |
|---|---|---|---|---|
| short | 21 / 22 | 0.017 / 0.019 | 0.013 / 0.015 | 0 / 100 |
| long | 501 / 502 | 0.417 / 0.476 | 0.344 / 0.383 | 0 / 100 |
| tools | 201 / 802 | 0.410 / 0.453 | 0.662 / 0.744 | 0 / 100 |

每场景 100 次更新，变化条目总数均为 100。
这组结果**不能支持“全量签名就是当前秒级卡顿主因”**，反而约束了这类说法。
它不包含完整 Coordinator、JSON 编码、IPC、SwiftUI、预算估算和 GPU。

**额外待验证风险**

`send` 没有以 JS 完成回调驱动的应用级单飞/最新快照合并机制。
自适应 flush 读取的是原生 delta 缓冲积压，不直接度量 WebContent 的执行积压。
如果 JS 比投递慢，可能排入过时的完整正文。
本次未测 IPC 队列深度，不将“没有背压”直接写成已发生队列故障。

**建议**

先以内容字节量和活动回答长度扩展基准，再决定是否增加 revision/增量签名/单飞投递。
元数据变化（fork index、detailTurnID、streaming、附件、tint）也必须进入 diff，
不能只按正文长度或 message ID 判断未变化。
不要为了跳过陈旧帧而丢掉 remove/order/审批边界等结构变化。

### F09：聊天室的合并器仍位于 MainActor 消费之后

**位置**

- [ChatRoomLoop.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomLoop.swift)：
  `ChatRoomLoop` 标为 `@MainActor`；
  写作基线第 619 行附近 `for try await event in stream`。
- [ChatRoomSpeechBuffer.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomSpeechBuffer.swift)：
  `ChatRoomSpeechBuffer` 也标为 `@MainActor`。
- 对照 [NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)：
  普通 Session 的 `startRuntimeEventLoop` 使用 `Task.detached`，delta 写入锁保护缓冲。

**结论**

聊天室有 120ms 合并，不等于原始事件消费已独立于 MainActor。
MainActor 繁忙时，聊天室 delta 必须先获得执行机会，才能进入这个合并器。
因此它不具备普通 Session 后台合并路径相同的抗主线程阻塞能力。

**不能夸大的地方**

- 原生 SwiftUI 重算不一定慢到导致事件积压。
- 已有 120ms 发布频率限制、侧边栏隔离和正确的尾部定时器。
- 本次 11 项核心回归通过，但它们没有模拟完整 App 的 CA 同步等待。
- 未在当前聊天室实际复现“模型结束后还出字几分钟”，不能照搬旧 Session 复盘数字。

**建议验证**

用合成 provider 保持生产时间线，记录生产、消费、flush、DOM apply 四种时间戳。
仅在独立测试程序中制造短时间 MainActor 不可用，比较普通 Session 与聊天室：

- 生产是否完成但消费延迟？
- 延迟在原始事件队列还是已经合并的正文？
- 停止、错误、插话、审批前尾字可见性是否仍正确？

迁移前必须保留 `ChatRoomApprovalEventGate` 的顺序语义：
审批展示依赖消费到对应边界，而不仅是生产者已经发出事件。

## 4. 其他观察：暂不作为已确认缺陷

### 4.1 上报与滚动包含历史扫描

[transcript-document.js](../../NewPiApp/MarkdownRenderer/transcript-document.js)：

- `Scroll.topAnchor()` 从 `main.children` 开头找视口顶部条目。
- `Poller.pollAboveViewport()` 在轮询上方三屏之前，也先从头寻找锚点下标。
- `reportScrollState()` 先计算几何，再根据 payload 判断是否重复。
- `applyOps()` 有两处 `reportScrollState()` 调用。
- `reportTurnOffsets()` 遍历用户条目并读位置，250ms 合并。
- `Warmer.runChunk()` 为寻找最近未预热条目会扫描 children。

“只补偿上方三屏”不代表定位锚点过程也只扫描三屏。
但几何读取不一定每次触发昂贵完整布局，浏览器可能复用结果。
本次没有对大历史这些扫描的调用次数/耗时做独立 WebKit 量化，先作为下一轮测量点。
不能因为看到 `getBoundingClientRect()` 就一律认定布局抖动。

### 4.2 全量 order op

Coordinator 在 `newOrder != lastOrder` 且旧顺序非空时发送全量 `order`。
普通尾部新增也满足这个条件；JS 会遍历给定 ID，用 `appendChild` 移动已有节点。
这是可进一步验证的结构成本，不与 F01 混为一谈：
F01 是一条回答内部节点重建，order 是消息条目级重排。
尚未实测普通追加是否因此造成可感知滚动或选择问题。

### 4.3 日志和指标不在部分基准计时范围内

`PROBE stream flush`、`PROBE dom applied` 等仍走日志代码。
[NewPiLogger.swift](../../Packages/NewPiCore/Sources/NewPiCore/Diagnostics/NewPiLogger.swift)
的文件日志调用不是统一后台批写；
[NewPiLogStore.swift](../../NewPiApp/NewPiLogStore.swift) 的 handler 会投递到 MainActor。

不过 [LLMMetrics.swift](../../Packages/NewPiCore/Sources/NewPiCore/Diagnostics/LLMMetrics.swift)
对 flush/diff/DOM 指标只把大于等于 50ms 的慢项落盘，不是每条都写文件。
不能把“指标 task 存在”误说成“每个指标都同步写磁盘”。

冷加载测试替换了 logger/metrics，以隔离用户数据；因此其结果不能覆盖真实日志开销。
这只是测量边界，不是本次已证明的主要瓶颈。

## 5. 用户症状、已知行为和诊断边界

### 5.1 “长会话”至少有四种不同规模

| 维度 | 典型成本 |
|---|---|
| 历史条目多 | 原生适配/签名、DOM 构建、锚点扫描、预热 |
| 当前一条回答很长 | 完整正文复制/编码、分块扫描、可变尾块重解析 |
| 当前回答块很多 | F01 的冻结前缀误重建尤其相关 |
| 同时保活并输出的会话多 | 隐藏投递、通知、WebView 渲染资源竞争 |

基准只写“500 条”不够，应同时记录总字节、代码块数、最长块、活动消息长度、折叠情况。

### 5.2 Session 保活不是所有切换都保留 DOM

- 普通 Session A/B 在同一 `NewPiChatView` 内切换：面板用透明度保活。
- 聊天室 A/B：根视图按 `.id(chatroom.id)` 创建不同详情，文档会冷建。
- Session/聊天室跨类型切换：根视图 `if/else` 切换分支，
  `NewPiChatView` 可能整棵移除；runtime 保活不等于 WKWebView 保活。
- 普通 Session 超出缓存被淘汰后：也会冷建。

因此“切回又解析”在部分路径是现有生命周期设计，不一定是 F06 的重复读盘。
需要分别测数据恢复、view/controller 重建、HTML 外壳加载和 Markdown 渲染。
不要简单增加保活数量：那可能加重 F03 和内存压力。

### 5.3 收尾位移不都等于性能故障

当前仍有：

- 最终答复时处理详情折叠。
- `renderFinal` 全量归一化 Markdown。
- 流式 160pt 高度档位退回自然高度。
- fork 解锁后在钉底状态下有约 1.6s catch-up。

旧复盘曾把终态星号光标停留后消失也列为位移来源，
但当前 `enableCaret = false`，不能继续把该星号消失当作现状原因。
hljs 的调用在当前 `markdown.render()` 路径内同步执行；后续浏览器布局/绘制可能异步，
不要笼统写成“hljs 任务本身异步执行”。

复盘提出“答案开始时提前折叠”的 A 方案，当前 Session 仍在最终 assistant 的
`messageEnd` 路径调用 `finalizeDetailGroup`，没有按该提议提前到首个正文 flush。
这属于体验方案是否落实的问题，不是本次建议直接修改的既定需求。

### 5.4 性能指标不能混用

| 指标 | 说明 |
|---|---|
| provider 生产完成时间 | 模型/网络结束 |
| 原始事件消费完成时间 | 可判断是否在消费者之前排队 |
| 原生 flush 耗时 | 必须明确是否只测字符串合并 |
| Coordinator diff/编码/投递 | 不等于 JS 已完成 |
| JS 同步 apply 耗时 | 不含所有后续异步布局与 GPU 呈现 |
| 两个 RAF | 不是“像素已经显示”的保证 |
| objectWillChange 数量 | 不是实际绘制帧数 |
| runloop timer 准点 | 不能证明 MainActor 没被 CA 嵌套等待阻塞 |

现有 `flushStreamingDelta` 的 `elapsed` 在 `storeFlushTarget` 之前结束计时，
因此其 `mergeMs` 很小并不能排除后续 diff/编码/投递成本。
这是理解已有探针的重点，不应把每个阶段各自便宜就当成端到端已经证明便宜。

## 6. 可复制的最小复现

### 6.1 F01 + F04：直接执行当前 JS，验证机制

在仓库根运行以下 Node 脚本。只读取两个项目 JS，不写仓库、不访问网络、不启动模型。
Node 的最小 DOM 不用于性能计时；真实 WebKit 复核见下一节。

```bash
node <<'NODE'
const fs = require('node:fs');
const vm = require('node:vm');

class Element {
  constructor() {
    this.children = [];
    this.parentNode = null;
    this.style = {};
  }
  get firstChild() { return this.children[0] || null; }
  appendChild(child) {
    this.children.push(child);
    child.parentNode = this;
  }
  removeChild(child) {
    const index = this.children.indexOf(child);
    if (index < 0) throw Error('Missing child');
    this.children.splice(index, 1);
    child.parentNode = null;
  }
  replaceChild(next, old) {
    const index = this.children.indexOf(old);
    if (index < 0) throw Error('Missing old child');
    this.children[index] = next;
    next.parentNode = this;
    old.parentNode = null;
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

let renders = 0;
const markdown = {
  utils: { escapeHtml: text => text },
  disable() {},
  render(text) { renders++; return text; }
};
const window = { markdownit: () => markdown };
vm.runInNewContext(
  fs.readFileSync('NewPiApp/MarkdownRenderer/markdown-renderer.js', 'utf8'),
  { window, document: { createElement: () => new Element() } }
);

let root = new Element();
let renderer = window.createMarkdownRenderer(root, {
  reportHeight: false, postSnapshot: false
});
renderer.renderStreaming('# frozen\n\npartial');
const first = root.children[0];
renderer.renderStreaming('# frozen\n\npartial completed\n\nnext');
console.log(JSON.stringify({
  probe: 'normal tail completion',
  frozenPrefixNodePreserved: root.children[0] === first,
  renderCalls: renders
}));

root = new Element();
renders = 0;
renderer = window.createMarkdownRenderer(root, {
  reportHeight: false, postSnapshot: false
});
let text = 'block 0';
renderer.renderStreaming(text);
for (let i = 1; i < 100; i++) {
  text += ' completed\n\nblock ' + i;
  renderer.renderStreaming(text);
}
console.log(JSON.stringify({
  probe: '100 growing blocks',
  finalBlocks: root.children.length,
  renderBlockCalls: renders
}));

const timers = [];
const main = {
  children: [], addEventListener() {}, querySelectorAll() { return []; }
};
const enqueue = callback => { timers.push(callback); return timers.length; };
const w = {
  scrollY: 0, innerHeight: 600, addEventListener() {},
  setTimeout: enqueue, clearTimeout() {}, scrollTo() {}
};
let source = fs.readFileSync(
  'NewPiApp/MarkdownRenderer/transcript-document.js', 'utf8'
);
const marker = '  window.transcriptDoc = {';
if (!source.includes(marker)) throw Error('Probe marker missing; inspect new source');
source = source.replace(marker,
  '  window.probeWarmer = Warmer; ' +
  'window.probeLock = () => { forkLocked = true; };\n' + marker);
vm.runInNewContext(source, {
  window: w,
  document: { getElementById: () => main, documentElement: { scrollHeight: 0 } },
  setTimeout: enqueue
});
w.probeLock();
w.probeWarmer.schedule();
let callbacks = 0;
while (timers.length && callbacks < 1000) {
  timers.shift()();
  callbacks++;
}
console.log(JSON.stringify({
  probe: 'warmer paused with no rows',
  callbacks,
  stillPending: timers.length
}));
NODE
```

调查时输出：

```json
{"probe":"normal tail completion","frozenPrefixNodePreserved":false,"renderCalls":5}
{"probe":"100 growing blocks","finalBlocks":100,"renderBlockCalls":5050}
{"probe":"warmer paused with no rows","callbacks":1000,"stillPending":1}
```

若修复后输出变化，不要先改测试“适配”旧输出；确认变化是否正是冻结前缀保留、暂停停止自调度。
如果源码结构变化使注入失败，应显式报错后重新定位，而不是用失效探针声称问题不存在。

### 6.2 F01：在现有真实 WKWebView harness 上复核

先运行未修改的现有检查：

```bash
cd Packages/NewPiCore
bash ../../scripts/validation/check-transcript-dom.sh
```

它应保持通过。接着在**临时目录副本**中派生
[TranscriptStreamingDOMChecks.swift](../../scripts/validation/TranscriptStreamingDOMChecks.swift)，
不要改生产 JS，也不要覆盖仓库原测试。

其 `didFinish` 中已有 `apply` 和 `node` JS helper。
将最终的 PASS return 替换为以下 JS（放在 Swift raw 多行字符串内部时保留至少 8 个空格的缩进）：

```javascript
apply([
  {op:'reset'}, {op:'forkLock',locked:true},
  {op:'upsert',id:'prefix-probe',kind:'assistant',
   body:'# Frozen heading\n\npartial',streaming:true}
]);
const frozenNode = node('prefix-probe').querySelector('.markdown-block');
apply([
  {op:'upsert',id:'prefix-probe',kind:'assistant',
   body:'# Frozen heading\n\npartial completed\n\nnext',streaming:true}
]);
return JSON.stringify({
  probe: 'real WKWebView frozen prefix',
  frozenPrefixNodePreserved:
    node('prefix-probe').querySelector('.markdown-block') === frozenNode,
  finalBlockCount: node('prefix-probe').querySelectorAll('.markdown-block').length,
  textPreserved: node('prefix-probe').textContent.includes('Frozen heading')
});
```

复用现有脚本的编译方式：

```text
xcrun swiftc -swift-version 6 -parse-as-library <临时 Swift 副本> -o <临时可执行文件>
<临时可执行文件> <仓库绝对路径> <已创建的空临时 fixture 目录>
```

在 `Packages/NewPiCore/` 下执行 Swift 命令。
现有 runner 有 20s 超时；正常验证不应无限等待。
测试会把本地渲染资源复制到提供的临时 fixture 目录，退出后只清理该具体目录和本次文件。
不要杀用户的 NewPi/WebContent 进程，不需要鼠标键盘辅助功能授权。

本次实际执行过该派生测试，结果见 F01；不是仅建议未来执行。

### 6.3 F02：Combine 同值通知

```bash
cd Packages/NewPiCore
swift -e '
import Combine
final class State: ObservableObject {
    @Published var agentActivity = "writing"
    @Published var streamingBubbleComplete = false
    @Published var finalAnswerComplete = false
}
let state = State()
var notifications = 0
let subscription = state.objectWillChange.sink { notifications += 1 }
for _ in 0..<100 {
    state.agentActivity = "writing"
    state.streamingBubbleComplete = false
    state.finalAnswerComplete = false
}
print("100 same-value flushes: objectWillChange=\(notifications)")
subscription.cancel()
'
```

调查时输出为 300。
后续可扩展成真实 runtime 测试，但不要把该语言语义实验误称为完整 SwiftUI 绘制实验。

### 6.4 F05：预算微基准的完整 fixture

把以下 Swift 放在 session 临时文件中，不加入业务 target。
它调用公开的真实 Core 算法，不调用模型，不保存聊天室。

```swift
import Foundation
import NewPiCore

@main
struct BudgetCostProbe {
    static func main() {
        let room = ChatRoom(name: "synthetic-budget-probe", projectPath: "/tmp")
        print("case,historyBytes,tokensSum,twoEstimatesP50ms,twoEstimatesP95ms")
        for (name, count, repeats, seed) in [
            ("ascii-500", 500, 80, "History text. "),
            ("cjk-500", 500, 80, "长会话渲染性能分析。"),
            ("ascii-500-large", 500, 800, "History text. "),
            ("cjk-500-large", 500, 800, "长会话渲染性能分析。")
        ] {
            let text = String(repeating: seed, count: repeats)
            let history = (0..<count).map { _ in
                ChatRoomMessage(
                    chatroomID: room.id,
                    roleID: "synthetic-role",
                    content: text,
                    phase: .discussion
                )
            }
            var samples: [Double] = []
            var tokens = 0
            for iteration in 0..<22 {
                let start = ContinuousClock.now
                let first = ChatRoomContextBuilder.estimatedTokens(room: room, history: history)
                let second = ChatRoomContextBuilder.estimatedTokens(room: room, history: history)
                tokens = first + second
                let c = start.duration(to: .now).components
                if iteration >= 2 {
                    samples.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
                }
            }
            samples.sort()
            print("\(name),\(text.utf8.count * count),\(tokens),\(samples[9]),\(samples[18])")
        }
    }
}
```

`tokensSum` 是两次相同估算的和，单次值需除以 2。
fixture 故意直接调用估算器，不经过 UI 模型配置/压缩门控；这是大规模结果不能代表典型生产的原因。

编译路径选择：

1. **Debug Core 组**：参考现有原生性能脚本，链接 Debug Core 的 Modules 和对象文件，探针使用 `-O`。
2. **优化算法组**：在临时文件中提取 `ChatRoomContextBuilder` 开头到 `static func systemPrompt`
   之前的声明（补上 enum 结束括号），以及完整 `ContextTokenEstimator`，
   与探针一同 `-O` 编译并导入 Core 模型。提取必须以明确 marker 定位，marker 缺失就报错。
3. 也可用真正的 Release Core 重跑，但这会是新的编译口径，应另列结果，不直接覆盖原记录。

不要为了复现增加第三方测试/benchmark 工具或请求真实 API。
不同机器、运行负载和编译器的绝对数值不同，重点看输入规模与同组趋势。

## 7. 已运行与未运行的验证清单

| 检查 | 本次状态 | 覆盖范围 |
|---|---|---|
| Combine 同值发布最小实验 | 已运行，300 次通知 | F02 的发布语义 |
| 现有聊天室原生性能基准 | 已运行，通过通知断言 | 适配/签名、列表隔离 |
| `swift test --filter ChatRoomRenderingTests` | 已运行，11 tests / 2 suites 通过 | 尾部刷新、插话、停止、失败、审批顺序等 |
| 当前 JS 的分块调用计数 | 已运行，100 块累计 5050 次 | F01 特定分批的算法机制 |
| Warmer 受控计时队列 | 已运行，1000 次后仍 pending | F04 自调度 |
| 现有 WKWebView DOM 检查 | 已运行，PASS | 非末尾流式、外层 DOM、Thinking 展开、定型、插话、测高模式 |
| 派生 WKWebView 冻结块身份检查 | 已运行，身份 false | F01 真实渲染路径 |
| token 预算 Debug/优化算法微基准 | 已运行 | F05 函数成本，不含整个 UI |
| 冷加载 500 条的完整脚本 | 本次未重跑；引用已有修复文档 | 不能作为本次新测量 |
| 内容进程终止恢复测试 | 未运行 | F07 仍需动态验证 |
| 当前完整 App 多会话 GPU/CA 采样 | 未运行 | F03 的真实影响尚待量化 |
| 当前聊天室事件积压压力测试 | 未运行 | F09 不能称已重现分钟级延迟 |
| 实际用户 Session 的读盘/热切换计时 | 未运行 | F06 只有源码机制结论 |

Core 命令输出先出现 XCTest “0 tests”，之后 Swift Testing 输出实际 11 个测试通过；
不能截取前半段就写成“没有运行测试”或把 0 当成最终总数。
这些 Core/原生基准是在 `875ccb1` 阶段运行，不声称已经为之后所有并行改动重新跑过测试。

本次临时探针和 fixture 已清理，没有保留独立原始输出文件。
本文的 JSON/CSV 数字是调查当时工具输出的转录，不是后来在当前 HEAD 全部重新生成的报告。
接手 Agent 应运行复现，并把新的完整输出、版本和环境记录到自己的 session artifacts。

文档写完后，另做了一次交付自检：直接提取并执行 §6.1 的代码块，三条输出仍与记录一致；
检查了全部 51 个相对文件链接，目标均存在，代码围栏成对。
这次自检只重跑了该只读 JS 探针，不代表其他历史实验也全部重跑。

## 8. 建议的复核矩阵与验收方式

### 8.1 第一轮：只验证，不修复

| 检查 | 必需断言 | 可反证的结果 |
|---|---|---|
| F01 两批追加 | 冻结标题节点是否相同 | 相同且未清空旧块，需检查版本/路径 |
| F01 100 块 | 实际 render 调用次数 | 不再按三角数增长，需定位已有修复 |
| F02 同值赋值 | 通知数、实际属性声明 | 目标属性有显式去重或不再被面板观察 |
| F03 背景 A 输出 | A 的 JS apply 是否继续 | 原生或 WebKit 层确有可见性门控，记录其范围 |
| F04 暂停预热 | 无工作时是否持续排 timer | 暂停后无后继 timer 且恢复仍正常 |
| F05 双预算 | UI 入口调用次数、有效历史量 | 实际只求一次/规模被严格限制，应下调影响 |
| F06 热恢复 | load/decode 次数 | 热命中在首次读取前已经短路 |
| F07 恢复回调 | 第二次导航后行数/批数 | 无外部 apply 仍能主动完整重放 |
| F08 长正文 | diff/编码/IPC 分开计时 | 历史不再扫描或实际成本可忽略 |
| F09 消费队列 | producer/consumer/flush 时间 | 聊天室消费已经不依赖 MainActor |

### 8.2 若之后决定修复

建议拆开提交，不同时大改渲染、滚动、审批、持久化：

1. F01：冻结前缀边界与内部节点身份测试。
2. F02：真实变化发布；保留状态转换。
3. F04：暂停/恢复调度生命周期。
4. F03：可见性门控与切回补投递，单独做跨会话回归。
5. F05/F06：预算缓存和恢复快路径，分别测试失效/异步竞态。
6. F07：验证后再补完整重放语义。
7. F08/F09：在更大的测量证据支持下再做增量化/消费线程调整。

性能改进必须同时保留：

- 单文档架构与文档内滚动权。
- 用户主动上滚后不被强拽回底部。
- 冷恢复锚点、rail 跳转、窗口变化下的可读性。
- Markdown 最终内容、代码高亮、复制、fork 元数据。
- Thinking/工具详情手动展开状态。
- 多会话后台执行、停止、错误、中断部分输出。
- 聊天室插话、审批前尾字可见、审批 gate 顺序。
- 资源全部本地、无任意模型文本注入 JS 字面量的捷径。

### 8.3 Reviewer 输出模板

```text
ID：
结论：确认 / 部分确认 / 反证 / 证据不足
核验版本与相关文件是否有工作区改动：
实际读取的符号：
实际执行的命令/测试：
关键输出：
确认的最窄事实：
没有证明的用户影响：
原文中需要改正或收窄的说法：
最小修复方向：
必须新增/保留的回归：
是否需要先做完整 App profile：
```

## 9. 文件指纹与快速导航

以下 SHA-256 在写作核验时采集。用于防止 reviewer 在变化后的代码上混用旧证据，
不是要求版本必须固定不动。

```text
de9ebbefa36305dddeaca21e66ab2585cad07be63be6ee7b705f3bc2c52a5c24  NewPiApp/MarkdownRenderer/markdown-renderer.js
32cdcc253e4ca24514d4637e4d694503c6fdd90249336d6d782fbeb1507643eb  NewPiApp/MarkdownRenderer/transcript-document.js
fd53cdf381b097752dfccf0bae77f4bcb39b8f8505d952db0ea605b0d8c85835  NewPiApp/MarkdownRenderer/transcript-document.css
31b43f632de2dbc68ba0160f5313ca1cd1737e09e0772f805e93ce8be4d61f67  NewPiApp/NewPiViewModel.swift
a5311ad289dc718bba34d5b47356aae23aac78985152ab9026e64f4c7d33a80e  NewPiApp/NewPiTranscriptDocumentView.swift
6d2be12c6844a7d8c73879c8d15b95afad7848b9cb24d3e6f8e792e3468e7179  NewPiApp/NewPiChatView.swift
f32bb90b5c836b433d077ea67fc3d42cb4191346513a22b9b201d57d33869143  NewPiApp/NewPiApp.swift
47088c53c20343f1476797a80094d703e782fe3716ce898c6643d37c526b832e  NewPiApp/NewPiChatRoomStore.swift
91022eacfddfc638102d109cd1753b5e3390591c3a09cc9068b92774a280bb68  Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomLoop.swift
e57528a0e1d9e3b7430d8dfaa9dcfbba8a6074ebfa0449146cbb7f75e3310dc3  Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomSpeechBuffer.swift
a9ae24cf3eaadf7a6dcdb3730d4202d4f9f994fa767644578b1ce72215e5b886  Packages/NewPiCore/Sources/NewPiCore/Compaction/ContextTokenEstimator.swift
cce4238624ced80ab2d45f8228a10d2fc252ead258188782e0e4b2cc1794889f  scripts/validation/TranscriptStreamingDOMChecks.swift
```

建议的只读定位命令（从仓库根运行）：

```bash
git rev-parse HEAD
git status --short
git --no-pager log -12 --oneline -- NewPiApp/MarkdownRenderer
git --no-pager blame -L 447,465 -- NewPiApp/MarkdownRenderer/markdown-renderer.js
git --no-pager blame -L 359,374 -- NewPiApp/MarkdownRenderer/transcript-document.js
git --no-pager blame -L 2357,2364 -- NewPiApp/NewPiViewModel.swift
git --no-pager diff 875ccb1 HEAD -- NewPiApp/NewPiTranscriptDocumentView.swift
```

## 10. 总结

最强的新证据是 **F01：真实 WebKit 中，正常尾块完成会重建未变化的冻结前缀**。
F02 的发布语义错误也已确定。F04 的持续暂停轮询有确定性复现。

F03、F05、F06、F08 的冗余路径可在源码中确认，但实际影响要按可见性、有效历史、
活动回答长度、构建模式分开测量。
F07、F09 不应被包装成已经重现的用户故障。

本次发现不是“单文档方案整体不可用”，也不支持直接重写渲染器。
优先把可重复的局部异常修准确，再用完整 App 测量决定后续优化。

## 11. 修复实施与验证记录

### 11.1 范围与版本

本轮在 `4b49812a903a8ec91ab5dd076923ec486efcf404` 基线上修改工作区，尚未提交。
保留既有单文档架构、本地资源、WebKit 滚动 writer 和模型事件顺序；
未回退用户原有的工具快照、学习测试或文档改动，也未启动真实模型、重启用户 App 或操作用户会话。

下面的“已修复”指具体机制已修改且相应验证通过，**不是九项都已完成真实用户卡顿的端到端归因**。
§9 的指纹用于定位修复前版本，不应再与当前文件相等。

### 11.2 各项改动与证据

| 项目 | 当前改动 | 验证与边界 |
|---|---|---|
| F01 | 按**上一批**冻结范围判断分叉；块签名同时记录高亮状态，旧尾块冻结时即使文本不变也补高亮 | 真实 WKWebView 检查内部前缀节点身份、围栏高亮、编辑/缩短/清空及 100 块增长；插入节点由旧实验 5,050 降为 199 |
| F02 | 正文 flush 对 `.writing` 和两个完成标记先判等；`isNearBottom`、marker 字典同值不再发布 | 真实 Coordinator 接收 100 轮同值 UI 状态（滚动位置仍变化）不产生 UI 发布；锚点持久化通道未关闭；runtime 三个属性的条件写入通过 App 编译，未单独运行完整面板通知计数 |
| F03 | 宿主接收 `isVisible`；隐藏时不做内容 diff/编码/JS 投递，只覆盖待发快照；重新可见自动补最新状态。面板移除时提交 live shadow 并解绑控制器 | 同一真实页面隐藏期间 100 次更新无新内容批次，显示后一次恢复后台完成的正文。验证的是桥接门控，不代表后台 WKWebView 的全部系统 GPU 活动为零 |
| F04 | 暂停时停止预热 timer 链；fork 解锁独立唤醒；滚动结束或输入空闲后恢复，覆盖未产生 `scrollend` 的边界输入 | 真实 WKWebView 计时器计数检查锁定期间停止重复调度、无 upsert 解锁仍唤醒、用户滚动暂停及空闲恢复 |
| F05 | runtime 缓存当前历史版本总预算；消息/配置变化使总值失效；逐消息缓存正文和中断提示估算，摘要单独缓存；自动压缩和 UI 共用入口 | 500 条历史首算 500 次，重复读取不再估算字符，修改一条仅增加 1 次；检查中文、emoji、摘要/检查点、编辑、删除、重排、角色系统标记、中断类型等失效 |
| F06 | `resumeSession` 首次 await 前取请求号，先查 runtime；冷加载结果和热 header await 均校验请求号/项目/缓存身份；旧构建不得注册覆盖新 runtime；旧请求不得关闭新请求的 loading 状态；provider readiness 回调也受请求身份保护 | 已解码 `SessionContext` 直接 attach，Core 测试在文件不存在时验证 header、分支和 leaf 保留，并验证后续写盘。热路径零读盘与 A 慢/B 快的激活保护已做源码检查和完整 App 编译，**尚无完整 ViewModel 的可控 I/O 竞态实测** |
| F07 | 始终保存最新可重放快照；终止回调失效旧 diff、恢复锚点并重建外壳；新文档加载后无需外部 apply 即重放 | 真实 Coordinator 的终止回调测试：500+ 条静态页面自动恢复；隐藏状态下重建仍不投递内容，重新可见后恢复最新 live 文本与 fork 锁。未终止系统进程 |
| F08 | 结构化签名保留字符串值共享，不再拼接整份历史正文；普通 append/remove 不重排全部节点；JS 内容通道单飞，在途期间只保留最新完整快照，滚动意图另存；generation 隔离旧页面回调 | 连续 100 个快照最多 2 批，末尾文本正确；陈旧 SwiftUI 快照不能覆盖 live；正常 append 无 order，真实重排和仅 fork 元数据变更仍生效。双层 JSON 转义保留，并验证含闭合 script 字样、引号和中文的正文。**全历史条目遍历、活动消息完整 body 投递仍存在，未改为逐字符补丁协议** |
| F09 | 将 Session 已有的锁保护增量缓冲抽到 Core 共用；聊天室 AgentLoop 原始 delta 由 detached 消费器合并，MainActor 只接调度和边界；边界先 drain，取消传给消费任务并等待退出 | 人为短暂阻塞 MainActor，10,000 个 delta 仍在后台全部合并，解除阻塞后的边界看见完整尾字；插话、审批 gate、取消、失败和落盘顺序回归通过。旧 `chatWithEvents` 兼容路径保留原消费策略，本次主要修正 UI 使用的 AgentLoop 路径 |

### 11.3 关键实现入口

- [markdown-renderer.js](../../NewPiApp/MarkdownRenderer/markdown-renderer.js)：`renderStreaming` 的冻结范围与高亮状态。
- [transcript-document.js](../../NewPiApp/MarkdownRenderer/transcript-document.js)：`Warmer.schedule/runChunk`、解锁唤醒、`Poller` 空闲恢复。
- [NewPiTranscriptDocumentView.swift](../../NewPiApp/NewPiTranscriptDocumentView.swift)：`latestSnapshot`、`flushPending`、`Signature`、`pageGeneration`、`setVisible`、恢复回调。
- [NewPiChatView.swift](../../NewPiApp/NewPiChatView.swift)：可见性参数和面板卸载时的 shadow 提交。
- [NewPiViewModel.swift](../../NewPiApp/NewPiViewModel.swift)：flush 去重、恢复请求身份和 provider readiness 校验。
- [ChatRoomContextTokenCache.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomContextTokenCache.swift)：有效历史估算缓存。
- [StreamingDeltaBuffer.swift](../../Packages/NewPiCore/Sources/NewPiCore/StreamingDeltaBuffer.swift)：Session/聊天室共用后台合并缓冲。
- [ChatRoomSpeechBuffer.swift](../../Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomSpeechBuffer.swift)：后台消费与边界冲刷、取消生命周期。
- [AgentSession.swift](../../Packages/NewPiCore/Sources/NewPiCore/AgentSession.swift)：已解码上下文 attach 重载。

### 11.4 自动化回归

现有验证入口已扩充，无新测试框架或外部依赖。所有 Swift 命令从 Core 目录执行：

```bash
cd Packages/NewPiCore

swift test --filter 'ChatRoomSpeechBufferTests|ChatRoomRenderingIntegrationTests|ChatRoomContextTokenCacheTests|AgentSessionShutdownTests|JSONLSessionCodecTests|SessionManagerTests'

bash ../../scripts/validation/check-transcript-dom.sh
NSUnbufferedIO=YES bash ../../scripts/validation/check-transcript-cold-load.sh
NEWPI_EXPECT_FILTERED_NOTIFICATIONS=1 bash ../../scripts/validation/check-chatroom-performance.sh
```

- Core：29 项测试 / 6 个 suite 通过，包括新增缓存、后台消费、分支上下文复用验证。
- DOM：既有非末条 streaming、手动展开、最终归一化、插话保留检查继续通过；新增冻结前缀/高亮/预热调度检查。
- 冷加载/生命周期：5 个场景均为初次 1 批内容投递；500 条静态助手消息恰好渲染 500 次；无多余 article 旧高度读取；原位恢复场景测得锚点误差 0px。
- 恢复检查中输出 `Transcript document process terminated, rebuilding` 是主动调用恢复回调的预期日志，不是探针真的崩溃。
- 新增文本转义检查使用语义文本断言：renderer 开启 `typographer`，ASCII 双引号变弯引号属于既有行为，不能误判为传输截断。
- SessionContext 的持久化测试使用整秒时间戳，遵守现有 JSONL ISO8601 精度，避免把亚秒舍入误认作分支内容丢失。
- App：现有 `NewPi` scheme 的 Debug `xcodebuild build` 通过；没有打包替换正在运行的应用。

结构化签名基准一轮结果（毫秒；探针 `-O`、Core Debug，非完整 Release App）：

| 场景 | 条目数 | adapter P50/P95 | signature P50/P95 | 100 次更新 root/detail 通知 | 变化条目总数 |
|---|---:|---:|---:|---:|---:|
| short | 22 | 0.017 / 0.019 | 0.008 / 0.009 | 0 / 100 | 100 |
| long | 502 | 0.422 / 0.659 | 0.211 / 0.379 | 0 / 100 | 100 |
| tools | 802 | 0.421 / 0.465 | 0.377 / 0.442 | 0 / 100 | 100 |

这是受控运行结果，不是稳定承诺或端到端交互延迟。旧基准与本轮的机器负载可能不同；
节点身份、插入数、投递批次数、缓存估算调用次数是更直接的验收证据。

### 11.5 继续 review 的重点

1. **完整 App 手工验证仍有价值**：多个会话并发输出、跨 Session/聊天室切换、正在审批时隐藏/返回、停留在长历史中段时后台完成、真实重连和页面进程故障。当前脚本验证 Coordinator 生命周期，不等价于完整 SwiftUI/CA 负载。
2. **F06 的异步时序**：特别关注“点 A → A 读盘或 MCP 构建中 → 点 B（包含当前已激活的 B）”、同一文件重复点击、切项目，以及旧 credential 回调迟到。不要只检查最终 `activeRuntime` 的一处 guard。
3. **最新快照合并只能用于显示态**：不能迁移到模型事件、审批请求、工具执行结果或持久化事务；这些必须维持顺序和边界。本轮只合并 delta 字符和可重建的文档快照。
4. **UI 派生状态去重不等于禁掉状态上报**：滚动位置变化即使 `nearBottom` 不变，仍要保存锚点。
5. **剩余规模风险**：JS 的锚点/最近条目扫描、全历史适配/签名遍历、活动 body 的完整编码、冷页面 Markdown 解析和最终归一化没有全部消除。没有新增测量时不要宣称这些都已成为主要瓶颈，也不要把本轮当作性能工作的终点。

## 12. 修复后真实 Session 的 200 行复现：原生呈现等待仍存在

### 12.1 调查范围与环境

用户反馈：在 Session 中要求模型直接输出 200 行文本，流式过程仍明显卡顿。
本节对照实际请求日志和现场进程采样，不把 §11 的测试通过等同于端到端卡顿已解决。

- 2026-09-11 05:49:33、05:50:09、05:50:56：用户原始三次测试。
- 06:09:40：重启后的第一次复现；未记录秒级 MainActor 延迟。首次采样实际从 06:10:01 开始，晚于请求结束，**不能用于证明卡顿原因**。
- 06:13:10：第二次复现。提前监听 `Agent run started`，事件触发后约 0.1 秒开始 `sample`，采样 20 秒，间隔 2ms，覆盖实际输出和收尾。
- 现场进程 PID 77858，macOS 26.5；运行的是 Xcode DerivedData 下的 Debug App，父进程为 `debugserver`，加载 `NewPi.debug.dylib`、Main Thread Checker 和异步回溯记录库。
- 本次没有修改运行环境或业务代码。未做同二进制脱离调试器、Release 或 Metal validation 的 A/B，因此**不能认定 Debug 或某项验证开关就是唯一原因**。
- 采样文件保留在本次 Copilot session 的 `files/newpi-200-lines-triggered-sample.txt`，不提交到仓库；同目录 `newpi-200-lines-main-sample.txt` 是首次错过输出窗口的空闲期样本，应明确区分。

### 12.2 原始三次测试：文字持续到达，UI 却成批追赶

| 请求开始 | 最大 MainActor 探针漂移 | 正文 flush 次数 | 最大 JS apply | 末个正文 delta → 流结束 |
|---|---:|---:|---:|---:|
| 05:49:33 | 10.92s | 1 | 23ms | 5.7s |
| 05:50:09 | 7.85s | 90 | 7ms | 7.9s |
| 05:50:56 | 3.48s | 28 | 9ms | 5.7s |

三次原生正文合并的 `mergeMs` 均四舍五入为 0ms，不能据此说整个 flush 管线“无成本”；
该计时不包含后续投递、渲染提交和等待调度。

第一轮尤其明确：05:49:35–44 持续出现匹配的 `bcast` / `consumed` 序号，
直到 05:49:45 才发生一次 7,448 字符的 flush。不是服务端一直不发字，而是 MainActor
迟迟不能运行显示任务。第二轮 provider 在 05:50:28 完成，UI 在 05:50:33 才处理完成边界，
其中 `messageStart` 的 `hopLag=4.30s`。

### 12.3 现场调用栈：同步等待发生在原生呈现层

06:13:10 开始的有效采样记录主线程 7,967 个样本，最大等待分支为：

```text
AppKit / UpdateCycle
  CA::Transaction::commit
    CA::Context::commit_transaction
      CA::Layer::display_if_needed
        -[RBLayer display]
          -[RBLayer displayWithBounds:callback:]
            RB::SharedSurfaceGroup::add_subsurface
              RB::SharedSurfaceGroup::wait_for_allocations
                RB::CommitMarker::Observer::test_displayed
                  -[CAContext waitForCommitId:timeout:]
                    CA::Context::synchronize
                      CA::Render::Context::wait_for_synchronize
                        mach_msg
```

该分支 `wait_for_synchronize` 为 **2,909 / 7,967 ≈ 36.5%** 的主线程采样。
这只是最大单一分支，未把其他相似等待分支叠加；是采样占比，**不是 CPU 利用率**，
也不是精确的单次等待时长。

同轮日志：

- 06:13:17：MainActor 漂移 2.41s；
- 06:13:19：1.13s；
- 06:13:23：2.62s；
- 正文 8,248 字符，74 次正文 flush；
- 79 次 JS DOM apply 合计 198ms，单次最大 15ms；
- 最后正文到流结束还有 8.1s；
- UI 接收侧 run wall time 18.57s。

**已证实结论**：本轮秒级停顿包含显著的 RenderBox/CA 表面分配和提交确认同步等待，
它阻塞了 MainActor 上的 flush/完成边界；不能用“JS apply 只要几毫秒”排除原生呈现阻塞。
现场栈与历史 `streaming-stall-postmortem.md` 记录的路径一致。

**尚未证实的更细归因**：栈未标出是哪一个具体视图/图层最先制造表面分配压力，
不能直接认定只有 WKWebView、某个 SwiftUI modifier 或 `setNeedsDisplay(.infinite)` 单独负责。
需隔离宿主层、提交频率、内容高度与调试注入进行 A/B。

### 12.4 为什么 §11 的修复没有消除此问题

1. Session 的后台消费者确实持续接收和合并 delta，避免了原来的逐事件排空债务；
   但真正改 UI 的 `flushStreamingDelta` 仍必须等 MainActor。**不丢输出、不积压原始事件不等于显示不卡。**
2. Coordinator 单飞以 `evaluateJavaScript` completion 为边界，该回调不代表 CA/WindowServer
   已完成呈现。JS 执行快仍可能不断触发昂贵的原生图层提交。
3. 每个内容批次仍会调用 `setNeedsDisplay(.infinite)`；流式条目仍随正文增长，
   高度量化为 160pt 步进。这些是需要对照测量的触发面，不应直接删除 PAINT-GATE
   （曾经出现不刷新、滚动后才补画的回归）。
4. 用户原始三次输出实际是**包含 200 行正文的一个围栏代码块**：每条 204 个物理行、
   2 个 fence 行、1 个空行，约 7–8KB 字符。它不同于 100 个独立段落的冻结前缀测试。
   代码块在流式中仍是可变尾块，每批会重建整块；这是进一步减少呈现变动的候选项，
   但本轮毫秒级 DOM 测量不支持把它直接写成十秒级 JS CPU 阻塞。

### 12.5 另一个独立问题：Responses 正文后的静默尾段

原始三次测试实际走 `https://api.deepseek.com/responses`，不是 Chat Completions。
`Stream tail analysis` 记录 5.7–7.9s 的无正文尾段，第二次现场复现为 8.1s。
这会拉长 API 面板的“总时间”，与“正文出字时的 MainActor 停顿”必须分开解释，
两段时间可能重叠，不能简单相加。

当前 [ResponsesAPIProvider.swift](../../Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesAPIProvider.swift)
已经在 `response.completed / incomplete / failed` 到达并识别后主动退出读取循环。
因此不能把“已收到终态却继续等待 TCP 断开”的旧缺陷直接当作本次原因。
现有指标未逐条记录原始 SSE 的终态/文本 done 时刻，仍需增加这些时间点或做协议侧对照，
区分服务端终态迟发、网络到达与本地消费延迟。

不能以“若几秒没新文字就假装完成”修复：这可能截掉工具调用、失败状态或用量。

### 12.6 下一步修复验收应改变什么

- 以“200 行单一代码块 + 真实 SwiftUI 宿主 + 实际流式节奏”为回归场景，
  而不是只检查多个独立块的节点身份或 JS 同步耗时。
- 优先减少和隔离原生图层提交压力：现有 `NEWPI_FLUSH_MS` 可用于提交频率 A/B，
  同时测首字上屏延迟、最长可见停顿、MainActor 漂移及 CA 等待采样占比。
- 调整 PAINT-GATE/宿主层时保留“无用户滚动也能持续呈现”的验收，不能以不刷新换取低耗时。
- 分别记录最后正文、Responses 终态、Agent 完成、最后内容提交，避免把 API 时间和 UI 排空混成一个数字。
- 本轮调查只确认阻塞位置和剩余机制，**尚未实施或宣称解决 RenderBox/CA 同步等待**。

## 13. 200 行卡顿的触发点修复与受控验收

本节是 §12 之后的修复记录；§12 的“尚未定位具体图层”描述的是当时证据，不是最新状态。
没有更改单文档架构、40ms flush 下限、JS 单飞策略或 PAINT-GATE。

### 13.1 首轮回放为什么未复现

新增 [TranscriptPresentationChecks.swift](../../scripts/validation/TranscriptPresentationChecks.swift)，
由既有 [check-transcript-cold-load.sh](../../scripts/validation/check-transcript-cold-load.sh) 的
`NEWPI_PRESENTATION_REPLAY=1` 分支编译执行，不引入测试框架。

回放使用真实 SwiftUI `NSHostingController`、文档 representable/Coordinator、本地 HTML/JS、
真实 minimap 与 50 条合成历史；独立后台生产者每 45ms 追加一行，MainActor 每 40ms 读取最新进度。
正文是一个围栏里的 200 行，额外包含开闭围栏共 202 个供给步。每轮约 9.5s，连续执行三轮。
输入框在探针里是简化的 TextField，**不是完整 NewPi App 或 LLDB 环境**。

第一版只有状态文字，缺少真实状态图标；最大调度延迟仅 8–19ms。
尝试原生文字动画时仍未看到现场栈。这个阴性结果**不能排除完整状态栏**，
也不能据此宣称调试器是唯一原因。最终改为编译、挂载完整的
[NewPiAgentStatusBar](../../NewPiApp/NewPiAgentStatusView.swift)，才稳定复现。

另外剔除了不可用于性能结论的探针启动失败：
窗口不可见或被压成 46×16 时，RAF 不代表可见呈现；尝试 WindowGroup 的启动版本未稳定进入回放。
持久脚本使用显式尺寸的 NSHostingController，启动时检查窗口可见且 viewport 高度大于 500，
设 90s 看门狗和有超时的 RAF 等待，防止把无窗口空转当作性能正常。

### 13.2 同一场景的受控 A/B

下面三组均使用已经稳定代码节点的 renderer，故 DOM 优化不是组间变量。
保持相同的正文、历史、40ms 消费节奏、真实状态栏和 minimap，仅改变状态动画。
这轮 A/B 的礼花保持未触发，最后又单独加入真实完成礼花做回归（见下）。

| 状态栏版本 | 三轮最大 MainActor 延迟 | 三轮有效正文投递数 | 结论 |
|---|---|---|---|
| 原始图标 pulse + 原始文字呼吸 | 3100.9 / 6289.8 / 4236.3ms | 62 / 43 / 54 | 稳定复现秒级阻塞 |
| 保留图标 pulse，仅把文字换成原生 CA 动画 | 1156.9 / 3427.2 / 2067.9ms | 132 / 118 / 115 | 未解决，实验代码已撤回 |
| 移除图标 pulse，保留原始 SwiftUI 文字呼吸 | 110.2 / 13.0 / 12.6ms | 202 / 201 / 202 | 此触发路径不再出现秒级阻塞 |

原始状态栏第二轮生产结束后仍等约 1988ms 才完成最终文本校验；移除 pulse 的三轮为 24–27ms。
该数字不是单独的“显示器上屏延迟”，而是后台生产结束到最终 DOM/RAF 校验完成的尾部跨度。
投递减少不是模型少产字：生产者继续推进，MainActor 被阻塞后只能合并读取最新正文。

20s、2ms 间隔的进程采样与 §12 现场栈一致：

```text
CA::Transaction::commit
  -[RBLayer display]
    RB::SharedSurfaceGroup::wait_for_allocations
      RB::CommitMarker::Observer::test_displayed
        -[CAContext waitForCommitId:timeout:]
          CA::Context::synchronize
```

原始完整状态栏主线程 8377 个样本中，最大单一 `wait_for_allocations` 分支 5044 个，
约 **60.2%**；这是采样占比，不是 CPU 利用率或精确等待秒数。
移除 pulse 后的同长采样中没有 `RBLayer` / `wait_for_allocations` 命中。
采样保留在本会话 artifacts：`presentation-statusbar-before-sample.txt`、
`presentation-statusbar-native-label-sample.txt`、`presentation-statusbar-fixed-sample.txt`。

因此可将**持续 SF Symbol pulse 确认为这个受控场景中引出 RenderBox/CA 阻塞的触发点**。
不能据此证明 Apple 框架内部是哪一层缺陷，也不能推导所有 SwiftUI 动画都不安全。
普通文字 opacity 呼吸在相同负载下通过，最终保留；不需要重写文字为 AppKit，也不需要包装 WKWebView。

### 13.3 最终生产改动

1. **状态图标**：[NewPiAgentStatusView.swift](../../NewPiApp/NewPiAgentStatusView.swift)
   移除 `.symbolEffect(.pulse, isActive: ...)` 和图标内不再使用的减动效环境读取。
   图标与绿色状态不变，文字呼吸仍提供活跃反馈；文字减动效支持不变。
2. **单围栏追加**：[markdown-renderer.js](../../NewPiApp/MarkdownRenderer/markdown-renderer.js)
   对顶层单围栏，使用 markdown-it 的 token 内容/缩进/换行规范化，保留容器、pre/code、复制按钮、
   Text 节点身份，只修改新增文本。未结束末行的补位换行可以替换，但不重建整个子树。
   只在源字符串追加且围栏标记/信息一致时进入快路径；编辑、缩短、混合块、列表/引用等走原渲染。
   冻结及最终完成仍完整归一化并高亮。
3. **不删绘制唤醒**：`setNeedsDisplay(.infinite)` 保留；未提高流式下限，不以少刷新换取低耗时。
   原生不读取正文高度，滚动和 CV 仍由 JS 管理。
4. **不保留无效实验**：原生文字动画、WindowGroup 探针尝试、WK 宿主包装候选均未进入生产路径。

DOM 回归检查初次创建后 200 行追加期间 **0 次子树重建**，并校验容器/code/Text 三层身份。
字符粒度围栏、部分闭合标记、反引号/波浪围栏、缩进、CRLF/NUL、特殊字符、引用、
前缀编辑、最终高亮均与一次性渲染对照；此前 100 个增长块的 199 次插入回归继续通过。
此优化减少不必要的重建，**不是把多秒卡顿重新归因于 JS CPU**。

### 13.4 协议尾段单独计量

[LLMMetrics.swift](../../Packages/NewPiCore/Sources/NewPiCore/Diagnostics/LLMMetrics.swift) 新增可选
`lastTextAt`、`textDoneAt`、`terminalAt`，旧 JSONL 仍可解码，不用 endedAt 伪造末次正文时间。
三种 provider 均记录末次正文；Responses 额外记录 `output_text.done` 与真正终态的解码时刻。

API 面板新增“尾”以及 tooltip，分别解释正文接收跨度、末次正文到终态、终态到 provider 标记结束。
`textDuration`、总时间和旧 tok/s 计算保持原口径，明确旧速率分母含协议尾段，并非独立测量的模型速度。
更多定义见 [API 指标设计](../api-metrics-design.md)。

`output_text.done` 不是请求完成：只记录时间点，不重复该事件里的完整文本，不丢后续文本、
工具调用、错误与 usage。不添加“无字几秒就成功”的超时。
这项改动增加区分证据，**没有宣称消除了服务端或网络中的 5.7–8.1s 静默尾段**。

### 13.5 最终验收与复跑

最终持久探针已挂载真实状态栏，并在完成时触发真实礼花；MainActor 看门狗继续覆盖完成后 2s。
完整 code.textContent 与生成的全部 200 行逐字比较，不能仅检查“有第 200 行”。

| 最终回归 | 第一轮 | 第二轮 | 第三轮 |
|---|---:|---:|---:|
| 有效正文投递数 | 202 | 202 | 202 |
| 总回放至最终 DOM 校验 | 9.63s | 9.61s | 9.61s |
| 最大 MainActor 延迟，含完成动画 | 46.1ms | 8.7ms | 16.2ms |
| MainActor 延迟 P95 | 7.0ms | 6.9ms | 6.8ms |
| DOM apply 最大 | 7ms | 5ms | 6ms |

其余验证：

- 两个相关 Core 测试文件：26 项通过，含旧指标兼容、新时间点和 text done 后的工具/usage。
- 真实 WK DOM 回归通过，含 200 行代码块无子树替换、冻结高亮和预热唤醒。
- 五个冷恢复场景通过；隐藏补投递、JS 单飞、重排/metadata 和进程重建回归继续通过。
- 独立 DerivedData 的完整 `NewPi` Debug App 构建成功；没有关闭或覆盖用户正在运行的旧 App。

仓库根目录保存旧状态栏后，从 Core 目录复跑：

```bash
BASELINE_DIR="$(mktemp -d)"
git show 4b49812:NewPiApp/NewPiAgentStatusView.swift > "$BASELINE_DIR/StatusBefore.swift"
cd Packages/NewPiCore
NEWPI_PRESENTATION_REPLAY=1 \
  NEWPI_STATUS_VIEW_SOURCE="$BASELINE_DIR/StatusBefore.swift" \
  ../../scripts/validation/check-transcript-cold-load.sh
NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 \
  ../../scripts/validation/check-transcript-cold-load.sh
rm "$BASELINE_DIR/StatusBefore.swift"
rmdir "$BASELINE_DIR"
```

设置 `NEWPI_PRESENTATION_SAMPLE` 为绝对文件路径，可从“已可见且已加载”时刻自动采样 20s，
不用靠人工猜测输出窗口。`NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1` 对最大延迟设 500ms 上限；
共享机器受到其他负载干扰时，应保存采样并复核，而不是盲目调宽门槛。

**验收边界**：已在同一机器、真实生产状态栏与文档桥的受控回放中复现并消除该触发路径，
还需用户重新运行最新 App，在原始 Session、显示器和 Xcode 调试配置下复测。
这是比 §11 的局部 DOM 测试更强的证据，但不等价于承诺所有会话、所有系统版本永远无停顿。

## 14. 后续等待体验与首字观测

08:50、08:51 的实际请求显示：API 起点到首个正文约 1s，首 delta 与首次 DOM 更新在同一秒；
末次正文到终态为 6.2s、6.1s。终态与 Agent 完成同秒，不能把这段尾部全部写成 UI 排空。
但缺少发送入口时刻和帧回调，仍不足以解释用户感知的完整首字等待。

### 确定的交互修复

[Session 输入框](../../NewPiApp/NewPiChatView.swift) 不再因整个 Agent 运行而禁用：
可以编辑下一条文本及准备图片，Send 仍禁用，Return 仍通过运行状态检查。
运行期间拒绝发送时草稿不清空；任务完成后由用户主动发送，不自动排队、不覆盖当前请求。
[ViewModel](../../NewPiApp/NewPiViewModel.swift) 同时对其它发送入口增加运行状态保护。
现有 IME、选区、取消清空、发送被拒、完成后发送的原生输入回归均通过。

### 尚不确定的耗时先补观测

增加同 runID 的稀疏、单调时钟时间线，覆盖发送准备、Session/Agent 启动、上下文准备、
provider 编码/HTTP/首 delta、后台消费、MainActor flush、JS 投递/完成和两次 RAF 回调。
定义、缺失阶段和呈现边界见 [API 指标设计](../api-metrics-design.md#发送到首字的分阶段诊断2026-09-11)。
没有修改模型参数、提高频率、提前结束 Responses，或把 RAF 当成实际像素呈现。

24 项相关 Core 测试通过，完整 Debug App 构建成功；原生输入框、冷恢复与真实状态栏
200 行回放通过。加打点后的三轮最大 MainActor 延迟为 7.3/47.0/9.9ms，
每轮完整消费 202 个合成供给步，并断言首字 dispatch/DOM/帧回调都关联到本轮 trace。
其中一次探针窗口不可见而主动失败，不算性能样本；重新在可见窗口执行才完成上述验收。

验证中发现既有 shutdown 测试只等 provider 把 delta 入队，就要求 Session 持久化完整文本，
存在调度竞态。现改为先订阅 Session 事件、等实际收到目标正文后再 shutdown，并同时校验
trace 跨 actor/Task 的继承；没有为测试增加等待毫秒数，也没有改生产取消语义。

## 15. 正文与工具交替时的底部留白跳动

### 15.1 现象与已确认机制

用户反馈：流式正文底部离输入区域较远，工具执行详情却比较贴底；
正文 → 工具 → 正文交替时，视觉上反复上移、贴底、再上移。

以 `e6d9929` 为本轮修改前基线，相关实现是：

1. [transcript-document.js](../../NewPiApp/MarkdownRenderer/transcript-document.js)
   对所有 `op.streaming` 条目调用 `applyStreamingHeightStep`，
   把外层行高向上取整为 160px 的倍数；同一流式阶段只增不减。
2. 普通工具条目以 `toolRunning` 表示执行中，并不是 `op.streaming`，
   因而通常保持自然高度。正文在 messageEnd 变为非流式后，又清空固定 `style.height`。
3. [transcript-document.css](../../NewPiApp/MarkdownRenderer/transcript-document.css)
   原本是文档四边 16px padding，加每条消息 16px 下边距。
   无人工占位时，最后可见卡片到文档底部的留白实际上已约为 32px。
4. `Scroll.beginBatch/endBatch` 按既有底部跟随意图重新钉底；
   内容高度改变时滚动目标随之变化，不是原生额外增加了一个 160px spacer。

所以用户感知的“固定高度”主要是**人工档位余量**，不是真的固定底距：
例如自然高 90px 的正文被撑为 160px，多出 70px；到终态就释放这 70px。
在长会话底部跟随时，该空白会直接推高卡片的可见内容。
工具执行状态切换再叠加真实的新条目/折叠，放大了阶段交替的视觉不一致。

160px 量化是较早的 RenderBox 卡顿缓解措施。§13 已定位并移除状态图标 pulse，
但这并不自动证明高度量化可以安全撤除，因此本轮仍做真实 SwiftUI 宿主回放和采样。
本节更新当前策略；前面章节对量化实现的描述保留为历史调查依据。

### 15.2 候选方案与取舍

| 方案 | 作用 | 风险/代价 | 本轮决定 |
|---|---|---|---|
| A：流式也使用内容自然高度 | 消除 160px 档位余量及完成时释放占位；正文和工具使用同一布局规则 | 实际内容每次长高都可能触发布局/合成，必须检查原生呈现是否退化 | **采用**，经回放验收 |
| B：统一文档底部 24–32px 留白 | 给各类最后条目同样的呼吸空间，不分别补偿正文和工具 | 必须识别最后一个可见条目，否则隐藏详情节点会导致下边距叠加 | **采用 32px**；延续原自然高度条目的实际底距 |
| C：边界尽量同批，并遵守现有底部跟随/上翻保锚 | 避免同批多次相互矛盾的滚动写入；尊重用户阅读位置 | 如扩大为延迟所有 messageEnd/toolStart 事件，会改变实时反馈与业务语义 | **沿用已有机制**，不新增延迟或改事件队列 |
| D：给工具也分配 160px 占位 | 看起来与正文一样“离底较远” | 仍然保留档位跳动、终态释放、工具卡片大量空白，属于补偿症状 | 不采用 |
| E：对 height/scroll 加过渡动画 | 短暂掩盖一次跳变 | 连续流式时动画反复重启，可能持续漂移；与滚动钉底及合成性能冲突 | 不采用 |

最终选择 **A + B，保留 C 的现有滚动纪律**。不通过降低刷新频率、关闭内容显示、
恢复旧多 WebView 高度桥，或再添加一个原生 scroll writer 来绕开问题。

### 15.3 实际修改与不变项

- 删除 `applyStreamingHeightStep` 及其调用，不再读取 `scrollHeight` 来确定档位，
  也不再写入/清除流式专属 `height`。
- 文档改为 `padding: 16px 16px 32px`。
- 用 `.ti:nth-last-child(1 of .ti:not(.detail-hidden))` 清除最后可见行的下边距。
  最后 DOM 节点可能是折叠隐藏的工具/思考，不使用简单的 `:last-child`。
  相邻可见条目的 16px 间距不变；空会话没有虚构消息，短会话仍顶对齐。
- 保留流式正文 `content-visibility: visible`、完成后恢复 `auto`、
  intrinsic 高度缓存、Warmer、`setNeedsDisplay(.infinite)`、单飞/latest-only 桥接、
  40ms 冲刷下限，以及原有 Scroll 状态机。
- 没有更改手动展开/收起详情、最终详情自动折叠、消息状态和工具执行时序。
- 没有修改正文光标策略：当前 renderer 内部 `enableCaret = false`，
  虽然调用方传入 `caret: true`，实际没有显示光标；本轮未重新引入动画或影响布局。

这里的 **32px 指最后可见卡片/行外框到底部视口边界**，前提是长文处于钉底状态。
它不包含卡片自身内边距，也不是承诺“最后一个字形到输入框文本基线恰好 32px”。
新工具插入、详情真实折叠、Markdown 最终归一化仍可能合法改变内容高度；
本轮消除的是人工占位造成的额外跳动，不是冻结所有正常布局变化。

### 15.4 验证结果

#### 几何与行为：真实 WKWebView

扩展 [TranscriptStreamingDOMChecks.swift](../../scripts/validation/TranscriptStreamingDOMChecks.swift)：

- 思考 → 短正文 → 40 行增长 → 同源正文终态 → 执行中工具 → 下段正文；
- 折叠详情后，尾部隐藏节点仍在 DOM，最后可见 disclosure 的底距仍正确；
- 最终答复移出组、上翻历史时后台继续新增工具/正文、跳回最新；
- 48 次尾部几何检查：自然行高贴合实际首个内容子元素，底距 32px（容差 <2px）；
- 每新增一行确实长高且增量 <40px，不允许保持原档位或突然长高 160px；
- 同一正文转为终态时不收缩占位，上翻锚点误差 <1px；
- 手动展开运行中工具后底距仍相同，工具完成后展开状态不丢失；
- 短会话保持 `scrollY = 0`、首条顶部 16px，不强制底对齐；
- 保留原回归：100 个增长块共 199 次插入、200 行单围栏追加 0 次子树替换、
  最终高亮、手动展开和预热暂停/恢复。

历史 fixture 首次插入会经历 CV 估算收敛，几何测试先完成初始钉底准备；
**后续类型切换不额外补 scrollToBottom**，因此不会用补滚动掩盖本轮切换错误。
跳转历史使用产品的平滑滚动，测试等待其结束后再模拟 wheel 接管，避免把动画过程误判成保锚失败。

#### 呈现性能：真实 SwiftUI 状态栏 + 原生文档桥 + WKWebView

扩展 [TranscriptPresentationChecks.swift](../../scripts/validation/TranscriptPresentationChecks.swift)，
仍用 50 条历史、45ms 后台供给、40ms 主线程消费、三轮各 200 行单围栏，
保留状态栏文字呼吸、首字帧关联和完成礼花；最大 MainActor 延迟门槛仍为 500ms。

| 配置 | 每轮最大 MainActor 延迟 | 每轮 dispatch 次数 | 每轮 JS apply 最大耗时 |
|---|---|---|---|
| 旧 JS/CSS（`e6d9929`，160px 量化） | 8.1 / 6.9 / 10.8ms | 202 / 202 / 202 | 15 / 5 / 5ms |
| 新自然高度 + 32px 尾距 | 47.7 / 7.9 / 8.3ms | 201 / 202 / 201 | 9 / 5 / 5ms |

两组都通过 500ms 门槛。新配置同时运行了 20s、2ms 采样，存在额外观测开销；
不据此宣称它比旧配置更快，也不把 47.7ms 与 8.1ms 的单次差异归因为高度策略。
部分供给步合并成一次投递是已有 latest-only 行为，每轮最终 200 行全文相等断言均通过，
首字 JS/DOM/帧 trace 仍完整。墙钟约 9.6s 主要由固定供给节奏决定，不是在线模型速度测量。

另外新增原生桥接的 **3 组正文/工具交替、6 次工具执行、最终组折叠 + 最终答复**：
尾距检查通过，最大 MainActor 延迟 **7.3ms**。
原生层的尾距检查允许桥接与 RAF 在 3s 内收敛；无额外滚动写入。
严格的同源完成不收缩、逐行不跳档断言在上一组 DOM 检查中完成。

采样位于本次会话 artifacts 的 `natural-height-presentation-sample.txt`，
开始于 2026-09-11 10:00:29，主线程共 8383 个样本：
**没有采到主线程 `wait_for_allocations` 阻塞链**。
不能写成“RenderBox 完全不运行”：主线程仍有少量 `RBLayer display`，
后台 `com.apple.RenderBox.SharedSurface` 队列还有 4 个 observer/CA 检查样本，
它们不等价于原先主线程数千样本的同步阻塞。

验证过程中，普通层级探针有两次帧超时，第三次在加可见性检查后明确报告窗口被遮挡；
这些不完整运行没有算进上述三轮结果，也不据此归因产品卡顿。
最终 A/B 均使用**相同的临时 `.floating` 测试窗口**防止其它窗口遮住探针，结束后关闭并恢复之前前台应用。
生产 App 窗口层级完全未改。这个探针不是完整用户 App 的所有窗口、显示器与调试状态。

#### 其它回归

- 普通 cold-load 五场景通过，500/501 行恢复场景锚点误差均 0px；
- 单飞/latest-only、隐藏文档追平、结构/元数据、WebContent 恢复、帧超时与旧回调隔离通过；
- App Debug `xcodebuild` 成功，编辑器诊断无错误；
- 未更改 provider、Core 生产实现或持久化模型；不启动登录 shell 成本优化/工具参数打点两个暂缓事项。

### 15.5 复跑与用户验收

以下命令顺序执行，不并发启动图形性能探针：

```bash
cd Packages/NewPiCore
../../scripts/validation/check-transcript-dom.sh
NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 \
  NEWPI_TRANSCRIPT_REVISION=e6d9929 ../../scripts/validation/check-transcript-cold-load.sh
NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 \
  ../../scripts/validation/check-transcript-cold-load.sh
../../scripts/validation/check-transcript-cold-load.sh
```

`NEWPI_TRANSCRIPT_REVISION` 仅替换临时 probe 内的 transcript JS/CSS，不改工作区或正在运行的 App。
有该变量时只做旧资源的连续输出性能回放，不运行明确要求新自然高度的交替几何断言。
无该变量时额外运行新交替场景。`NEWPI_PRESENTATION_SAMPLE` 可指定独立采样路径。

用户后续在重新构建并启动的最新版 App 中重点验证：

1. 长会话保持底部，让模型交替输出说明、执行多个工具、继续说明；
   不应再出现正文先悬空一大段、转工具后突然贴底的额外占位变化。
2. 同时检查短正文、长正文、最终详情折叠和手动展开，正常新卡片出现/折叠的布局变化仍应保留。
3. 流式途中上翻历史，确认不被持续拉回；点击回到底部后恢复跟随。
4. 再跑连续 200 行，核对尾字、最终高亮和可编辑草稿；如有秒级卡顿，保留同轮 trace 与现场采样再归因。

## 16. 非围栏 Markdown 结束时约一行跳动（待修复）

### 16.1 新反馈与范围

用户于 2026-09-11 10:13 反馈：输出 Markdown 时，最后有一个幅度很小、约一行的跳动。
示例提示是“输出一个 markdown，我在测试 markdown 渲染，不要使用代码围栏包围”，
用户表示该测试必现。**本轮仅记录和分析，不修改生产渲染行为。**

调查基线为 `f88a5b1`：§15 的 160px 高度量化已从源码删除。
这不证明运行中的 App 已加载该版本，也没有取得这次生成正文的精确 source；
提示词不是确定性 fixture，不能仅凭“输出 Markdown”推断具体列表、表格和末块形态。
下面区分“受控样例已证实的机制”和“对用户原始现场的待验证归因”。

### 16.2 优先候选：流式拆块与全文最终解析不等价

入口位于 [markdown-renderer.js](../../NewPiApp/MarkdownRenderer/markdown-renderer.js)：

1. `splitBlocks` 主要按空行切分；只对顶层围栏维持跨行状态。
   它不是完整的 Markdown 容器边界解析器，不跟踪松散列表、嵌套列表等跨空行结构。
2. `renderStreaming` 对各块独立调用渲染，每块外有 `.markdown-block` 包装。
3. `renderFinal` 清空这些包装后执行 `root.innerHTML = markdown.render(markdownSource)`，
   重新按全文语义生成最终 DOM。
4. [GitHub Markdown 样式](../../NewPiApp/MarkdownRenderer/github-markdown-light.css)
   有 `.markdown-body li > p { margin-top: 1rem; }`，段落也有下边距；
   列表结构和边距折叠关系变化，足以造成一行量级的高度差。

最小复现的**实际正文**如下（展示用围栏不属于输入 source）：

```text
1. First

2. Second

3. Third
```

最后流式快照的 DOM 等价于三个独立的紧凑列表：

```html
<div class="markdown-block"><ol><li>First</li></ol></div>
<div class="markdown-block"><ol start="2"><li>Second</li></ol></div>
<div class="markdown-block"><ol start="3"><li>Third</li></ol></div>
```

同一 source 的最终态则为一个松散列表：

```html
<ol>
  <li><p>First</p></li>
  <li><p>Second</p></li>
  <li><p>Third</p></li>
</ol>
```

这不是末尾多收到了一个换行：实验保证最后 streaming 和 final 使用**完全相同的 source**，
只是 `streaming` 从 true 改为 false。也不只是 DOM 全量替换的耗时问题，而是输出结构本身不同。
嵌套列表还出现流式阶段把续段/子列表当作顶层块、结束时重新归入父项的现象，
因此不能只删一条 margin 规则来宣称完整解决。

### 16.3 真实 WebKit 测量

使用当前本地 JS/CSS、900×650 的 WKWebView、合成历史和合成正文，不联网、不访问用户会话。
每 7 个字符追加一次，补齐完整流式 source，再对同一 source 执行最终渲染。
记录文章/外层行高、扁平化块结构、各块位置和 margin、文档高度、scrollY 与底距。

| 合成正文 | 最终文章高度相对最后流式快照的变化 |
|---|---:|
| 三项空行分隔有序列表 | **+26px** |
| 空行分隔无序列表，带标题和结尾段落 | **+6.765625px** |
| 带续段及嵌套子列表 | **+13px** |
| 标题、空行列表、表格、引用等混排 | **+8.71875px** |
| 普通段落、标题、紧凑列表、两种简单引用、简单表格、水平线 | 0px |
| 单个跨块引用链接、未闭合粗体样例 | 0px，但语义/DOM 等价性不能由高度为零推出 |
| 外层单围栏 Markdown 对照 | 0px |

共 14 个样例。像素值依赖本机字体、窗口宽度和样式，不能当作固定常量；
**已证实的是特定 Markdown 结构在完成时改变高度**，并非所有非围栏正文都改变。

另对有序松散列表单独拆开 messageEnd 与 fork 解锁，记录：

| 时刻 | 文章高 | 外层行高 | scrollY | 最后卡片底距 | 视口高 |
|---|---:|---:|---:|---:|---:|
| 最后完整流式快照 | 77 | 123 | 701 | 32 | 650 |
| final 同步批次后 | 103 | 123 | 701 | 32 | 650 |
| final 后两次 RAF | 103 | 149 | 701 | 6 | 650 |
| fork 解锁后两次 RAF | 103 | 149 | 727 | 32 | 650 |

由此可以复现“文章先增高，稍后视口移动约一行”的链路：
文章 **+26px**，随后 `scrollY` **+26px**，底距回到原本正确的 32px。
视口高始终不变，说明这个样例不需要原生输入框/状态栏改变高度也能产生位移。

这里的历史条目在测试准备阶段固定为 `content-visibility: visible`，
排除冷历史估算自身的变化；目标回答保持生产行为：
流式 `visible`，最终还原为 `auto`，其外层行高到下一帧才反映新文章高度。
这与 intrinsic 高度缓存交接有关联，**尚未单独 A/B 证明 CV 是唯一的延迟来源**。
首次未排除冷历史估算的探针没有稳定钉底，只用于观察文章结构；
上述表格取自修正后的钉底实验，不混用首次结果。

临时探针源码 `MarkdownFinalGeometryProbe.swift` 与原始 JSON `markdown-final-geometry.json`
保留在本次会话 artifacts；编译产物和临时复制资源已清理，不进入仓库。
这是布局/滚动的受控 WebKit 测量，**不是完整 App 的 GPU 呈现采样或用户原始会话的复现**。
复核时可在既有 WKWebView 验证器中加入上述 source，依次调用
`streaming:true`、同源 `streaming:false`、`forkLock:false`，在同步点及两次 RAF 后取相同几何数据。

### 16.4 其它候选与已排除的误归因

| 候选 | 当前判断 | 进一步区分方法 |
|---|---|---|
| 空行列表/嵌套结构在最终全文解析时合并 | **已在受控样例证实，优先排查用户正文是否包含** | 比较同源最后流式与最终 HTML、块位置和文章高度 |
| `.markdown-block` 包装消失造成 margin 折叠差异 | 与上项有关，不能笼统认定所有块都错 | 简单段落/标题对照为 0；需按具体块组合测试 |
| 流式尾部补闭合与最终原文语义不同 | 代码存在此差异，但本轮未闭合粗体样例高度差为 0 | 针对用户真实末块、字体换行临界宽度检查，不泛化 |
| final 后的 CV/intrinsic 估高交接 + 1600ms 收尾钉底 | **观察到外层高度晚一帧更新与后续滚动追平** | 同时记文章/行高/scrollY；先查高度为何变化，勿先禁用钉底 |
| messageEnd 收起处理详情、原生状态栏/输入区域尺寸变化 | 产品确有阶段切换，但未测用户现场，属于备选 | 固定视口、无详情/工具的对照仍可复现列表问题；实际现场需记录 viewport 尺寸和组状态 |
| 160px 人工高度释放 | `f88a5b1` 源码已删除；若 App 为旧版本需另行确认 | 记录构建版本及条目 inline height |
| 末尾 ✦ 光标淡出移除 | 当前 `enableCaret = false`，不应作为本版本原因 | 以执行代码和 DOM 为准；相关调用/滚动处的历史注释仍提及光标，不是启用证据 |
| 单纯协议尾段等待、模型输出慢 | 解释时间等待，不足以解释同源静态测试的 26px 高度/位移变化 | 将 provider 时间线和几何时间线分开 |

现有收尾钉底确实可能让这个高度差表现为最后一下滚动，但它也负责正确保持底距。
直接删掉 catch-up 可能只把问题改成底部被挤压/尾字不可见，而不是修好 Markdown 的前后不一致。
同理，不应禁用最终规范化来保持错误的流式列表语义。

### 16.5 待办与验收方向

优先评估流式分块是否应基于完整 Markdown 容器语义，让松散列表和嵌套列表在流式期就是同一列表；
保留稳定冻结前缀、尾部增量和最终高亮能力，不能简单退回每个 delta 全文重建。
再评估 final 的布局交接与收尾滚动是否能避免分两帧变化。
本轮不预先选择具体算法，也不修改 CSS 或 Scroll。

此前 §15 的“同源终态不收缩”回归使用普通逐行文本；
性能回放的 200 行主要是单围栏。它们没有覆盖“带空行列表在 final 重组”，所以通过不等于此问题不存在。
后续需补充上述最小样例与混排正文，验收语义、几何、上翻保锚、最终底距，
并重跑真实宿主的连续输出性能，避免为稳定高度牺牲语义或重新引入秒级卡顿。
跟踪项：[BACKLOG-MARKDOWN-FINAL-REFLOW](../TODO.md#backlog-markdown-final-reflow--流式与最终-markdown-结构不一致)。
