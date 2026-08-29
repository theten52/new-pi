# NewPi UI 架构决策：有条件采纳单文档 Transcript

> 决策日期：2026-08-30
>
> 分支：`feat/ui-arch-rework`
>
> 决策依据文档：
> [`ui-architecture-research.md`](./ui-architecture-research.md)（13 仓库调研）·
> [`ui-architecture-research-verification.md`](./ui-architecture-research-verification.md)（源码核验）·
> [`ui-target-architecture.md`](./ui-target-architecture.md)（单文档提案）
>
> 本文是**决策记录（ADR）**，不是第三份提案。结论、理由、执行方案、证伪条件各就各位。

---

## 1. 结论

**有条件采纳单文档 Transcript 目标架构，以 Phase 0 spike 作为 go/no-go 闸门；闸门通过前不做任何生产路径迁移。**

同时在 spike 启动**之前**先做一件与闸门结果无关的小事：把 `engineFingerprint` 接进高度查询（理由见 §4.1，它同时是 spike 的测量保护）。

不采纳的部分与时机：

| 事项 | 决定 |
|---|---|
| 立即按 Phase 1–4 迁移 | ❌ 不采纳。提案自己承认最大假设（500 turn 性能）未验证 |
| 核验报告 §5 的三项待办（滚动状态机 / 高度下沉 block 级） | ⏸️ 暂缓。若 spike 通过，前两者随边界一起消失；若证伪，按原顺序执行 |
| 工具卡原生 vs 文档内 | ✅ 采纳提案 §6.4：单文档前提下工具卡进文档。调研报告的"原生卡片"建议只在留守当前架构时成立，两文不矛盾 |
| osaurus 作为目标架构 | ❌ 不采纳（同意提案 §4：其复杂度多在重新实现浏览器已有机制）；作为参考实现质量第 1 位的评价保留 |

---

## 2. 为什么我判断提案的根因诊断成立

提案的核心论点是：当前痛点不是 N 个 bug，而是「原生持布局权、Web 持内容尺寸」这一条异步边界的重复投影。我在决策前独立核对了代码，文档论断属实，且**找到一条文档没有强调、但更有力的证据**：

### 2.1 独立核实成立的事实

| 论断 | 核实结果 |
|---|---|
| `height(for:)` / `height(for:width:)` 无引擎校验，`renderedHTML(for:engine:)` 有 | ✅ `NewPiMarkdownWebRenderer.swift:60-78` vs `:101-110`，属实 |
| 每条 markdown 行独立 WKWebView（nonPersistent data store + 4 个 message handler） | ✅ `NewPiMarkdownWebRenderer.swift:498-510` |
| 预热器是"屏幕内 alpha=0 窗口跑探针 WebView"，200 行 | ✅ `NewPiMarkdownHeightPreheater.swift`，注释自述存在的唯一理由是提前拿到异步高度 |
| `renderStreaming(root, source)` 已对容器参数化 | ✅ `markdown-renderer.js:405`，冻结前缀 + 尾块 patch 逻辑与文档描述一致 |
| 滚动写入 4 点 × 6 个 onChange 驱动 | ✅ `NewPiChatView.swift`（rail jump / 冷启动恢复 / rail 校正 / 钉底 × transcript/geometry/isStreaming/last.id/last.body/composerHeight） |

### 2.2 文档没有强调的关键证据：流式高度量化 160pt

`NewPiMarkdownWebRenderer.swift` 的 `applyStreamingHeight()` 注释记录了一次实测：

> 实测（sample）主线程约 73% 时间阻塞在 WebView layer 重分配的 CA 表面同步
> （RBLayer display → wait_for_allocations）上，根因就是这里每次 delta 都改高度；
> 量化把 layer 重分配次数降一到两个数量级。

**这是异步边界成本最直接的量化证据**：流式期间每个 delta 的内容尺寸变化都要跨越边界
（JS 测量 → message → SwiftUI 改 frame → CA 表面重分配），73% 主线程时间花在边界同步上，
不得不以"高度只增不减、160pt 步进量化"这种有损手段止血。

单文档架构下 WebView frame 在流式期间**完全不 resize**——滚动发生在文档内部，
这一整类成本连根消失，而不是再叠加一层补偿。类似地，滚轮转发单例注册表、
保活面板 frame 重叠门控、逐 WebView 白屏看门狗与进程恢复——全部是 per-message WebView
数量带来的成本，不是渲染本身的成本。

### 2.3 一个提案略微低估的工作量（如实记录）

`markdown-renderer.js` 是 IIFE 单例：`renderedBlocks`、`lastPostedHeight`、`hasStreamed`、
光标元素 id 全是模块级状态。单文档内每个 turn 一个 `<article>` 时，
需要把这块状态改为 **per-turn 实例**（工厂函数/类包一层）。改动机械、风险低，
但不是提案 §3.2 所说的"仅需把 root 参数改为 turn 的 article"那么小。
Phase 1 排期应为此留出余量。

---

## 3. 与近期工作的兼容性（刚合入 main 的三个特性）

| 特性 | 单文档下的归宿 | 兼容性 |
|---|---|---|
| 轮对话气泡背景色（`Color.bubbleTint(for:)`） | 移到 CSS：`<section class="turn" style="--turn-tint: …">`，FNV-1a 色相算法可直接用 JS 复刻，确定性不变 | ✅ 甚至更自然（turn 本来就是文档结构单位） |
| Session 重命名 / 列表悬浮高亮 | 侧边栏，纯原生，不在迁移范围 | ✅ 无交集 |
| Rail 定位 | 数据源从高度表换成 JS 上报的 turn offsets（提案 §6.7），rail 本体仍是原生浮层 | ✅ 数据源更准，rail UI 不变 |

**反向约束**：迁移期间渲染器 js/css 会频繁改动 → `engineFingerprint` 频繁翻转 →
若高度查询仍无引擎校验，A/B 对比的两条路径会共享**过期高度缓存**，污染 spike 测量数据。
这就是 §4.1 必须先做的直接原因。

---

## 4. 执行方案

### 4.1 Step 0（先做，与闸门结果无关）：engineFingerprint 接进高度查询

- `MarkdownRenderingCache.height(for:)` / `height(for:width:)` 增加 engine 参数与校验，
  与 `renderedHTML(for:engine:)` 行为对齐：指纹不匹配视为 miss。
- `setHeight` 写入时记录当前指纹（复用 `Entry.engine` 字段，磁盘格式向后兼容：
  旧条目 engine 为 nil → 一律 miss，自然淘汰）。
- 调用点：`MarkdownHeightPreheater`、`NewPiMarkdownText`、高度表重建路径。
- 规模预估：< 50 行 diff。spike 证伪时它是核验报告 §5 待办第 2 项的落地；
  spike 通过时它随高度表一起退役，但保护了迁移期数据正确性。**任何结果下都不白做。**

### 4.2 Phase 0 · Spike（go/no-go 闸门，1–2 天）

在 feature flag 后搭最小单文档原型，**只验证提案承认的最大未知数**：

```text
范围（刻意最小）：
  - 一个 WKWebView 承载 <main id="transcript">
  - 从真实会话 JSONL 合成 ≥200 turn / ≥500 turn 的测试 transcript
  - 已完成 turn 优先从 MarkdownRenderingCache 的 replay 产物直出（验证缓存复用路径）
  - CSS：content-visibility: auto + contain-intrinsic-size（提案 §5 已实测可用）
  - renderStreaming 包一层 per-turn 状态（§2.3），支持一个模拟流式 turn
  - 不做：rail、滚动状态机、工具卡、迁移任何生产代码

测量四组数（go/no-go 全部以实测为准，不接受推断）：
  M1  冷挂载到首屏可读耗时（200 / 500 turn 各测）
  M2  模拟流式期间每帧主线程占用（目标 < 8ms，对齐提案 §9）
  M3  常驻内存增量（200 / 500 turn，对比当前实现的同会话数据）
  M4  滚动流畅度（500 turn 全程滚动，记录掉帧）
```

**判定标准（预先承诺，避免事后合理化）：**

| 结果 | 判定 |
|---|---|
| M1 < 500ms 且 M2 < 8ms 且 M3 ≤ 当前实现 且 M4 无明显掉帧 | ✅ GO，进入 Phase 1 |
| 仅 500 turn 不达标、200 turn 达标 | 🟡 条件 GO：先做 JS 侧 turn 窗口化（DOM 只留最近 N turn + 高度占位 stub），复测 500 turn 再定 |
| 200 turn 即不达标 | ❌ NO-GO，执行 §4.4 退路 |

> **Spike 结果（2026-08-30）：GO。** 200/500 turns 全部达标（M1 185ms、M2 p95 4ms、
> M3 +87MB、M4 75fps 零掉帧），详见 [`dev-notes/ui-arch-spike-results.md`](./dev-notes/ui-arch-spike-results.md)。

Spike 产出无论成败都写成报告（`docs/dev-notes/`），失败数据对未来任何渲染架构决策都有价值。

### 4.3 GO 之后：Phase 1–4（按提案，附修正）

沿用提案 §7 的四阶段，补充三点修正：

1. **Phase 1 增加 per-turn 渲染器状态重构**（§2.3），并为 `renderStreaming` 补 JS 侧
   快照测试（冻结前缀不分叉 / 分叉全量兜底 / 源变短裁尾）——这是全系统正确性的基石，
   目前没有测试覆盖。
2. **Phase 2 的 JS 滚动模块**以 osaurus `ScrollAnchorManager` 算法为蓝本
   （topmost visible element + offset，1px 阈值断反馈环），单 writer、同步执行；
   原生侧只发意图。`overflow-anchor` 已实测不可用，锚定手写。
3. **flag 生命周期硬上限**：Phase 2 结束即删旧路径（预热器 / 窗口化 / 高度表布局消费 /
   滚轮转发器 / per-WebView 看门狗），不允许双路径长期并存。提案 §3.1 预估净删
   600–800 行，以删除完成作为 Phase 2 的验收条件之一。

### 4.4 NO-GO 退路（预先写好，证伪时不临时想方案）

维持当前架构，按核验报告 §5 顺序执行三项待办：

1. 滚动写入收敛为显式状态机（`ChatScrollIntent`，单 writer）——价值最高
2. ~~engineFingerprint 接进高度查询~~（Step 0 已完成）
3. 高度表下沉到 block 级（JS 高度上报带 blockID）

提案 §6 的 UX 细则（工具过程 per-run 聚合摘要、tail 3 行预览等）与架构解耦，
在当前架构上逐条落地。

---

## 5. 本决策的证伪条件

以下任一成立时，应重开本文档复议：

- Phase 0 spike 数据与 §4.2 判定标准冲突（数据优先于本文结论）
- 单文档在真实使用中出现当前架构没有的硬伤（如 WKWebView 单点崩溃恢复
  体验不可接受、VoiceOver 实测不达标）
- macOS SDK 行为变化使 `content-visibility` 虚拟化失效

---

## 6. 一句话版本

> 文档的根因诊断经独立代码核实成立（73% 主线程 CA 同步是边界成本的直接量化），
> 最难的渲染器资产已确认可复用；但最大假设未经测量，
> 所以采纳方向、不采纳立即迁移——先花 < 50 行修掉高度缓存的引擎校验漏洞，
> 再用 1–2 天 spike 拿数据决定走哪条路。

---

## 7. 补充（2026-08-30）：「block 级高度表」与「展示重规划」的关系

背景：后续计划重新规划 agent 输出的展示方式（工具展示 / 思考过程展示 / 结论展示），
曾考虑以此为由提前做核验报告待办 #3（block 级高度表）。核实后结论：**两者不在同一层，
展示重规划不构成提前做 block 级高度表的理由。**

### 7.1 两层「block」，不要混淆

| 层 | 粒度 | 高度管理现状 |
|---|---|---|
| transcript item 层（工具卡 / 思考 / 结论 / 用户气泡） | 每行一个 entry | **已是 per-item**：`NewPiTranscriptHeightMap.estimateRow()` 按类型分宽度口径（tool 行 / md 行 / 气泡行），工具卡折叠展开今天已只影响自己一行 |
| markdown 子块层（一条 assistant 消息内的段落/代码块） | 待办 #3 的目标 | 待做；动机是消息内局部失效，与展示重规划不直接相关 |

### 7.2 展示重规划的真正地基：typed item 模型

当前数据层是 stringly-typed 的，是重规划的第一障碍：

- `item.title == "You"` / `title.hasPrefix("Tool ")` 靠显示字符串判类型
- `body.hasPrefix("Running ")` 靠解析文案判工具运行状态（`NewPiToolTranscriptView.swift:18-25`）
- 思考过程未进 transcript：`thinkingDelta` 只写 debug log（`NewPiViewModel.swift:1151`）

应先把 `NewPiTranscriptItem` 改为类型化模型（user / assistant / tool(state) / thinking / summary / …）。
**该模型两种架构通吃**：当前架构路由原生视图，单文档序列化为 DOM 组件输入，无白做风险。

### 7.3 对排期的影响

子块级高度表动的是全仓最高危区域（rail / 窗口化 / 高度缓存 / 持久化格式 / JS 上报协议），
且 spike GO 后随高度表整层删除。因此：

```text
Step 0.5（新增，架构中立）：typed transcript item 模型 + thinking 入 transcript
仅当 spike NO-GO 且「消息内嵌折叠块」成为明确需求时，才启动子块级高度表
```

展示重规划本身与 spike 解耦：GO 则做文档内组件（活动带 / 思考折叠区 / per-run 聚合，提案 §6.3），
NO-GO 则做原生卡片，现有 item 级高度表直接承载。
