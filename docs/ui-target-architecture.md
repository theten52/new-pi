# NewPi UI 目标架构提案：单文档 Transcript

> **2026-09-12 修复摘要**：全文 parse 后按顶层 token 渲染，已修复语义分块造成的收尾重排；19 个真实 WKWebView 语义用例及四例零高度/滚动差通过，原始用户场景仍待验收。未改 CSS/滚动/原生布局，未接入 HTML replay；下文 26px 等历史证据保留，成本与保证边界见 [修复记录](./dev-notes/2026-09-12-markdown-final-reflow.md)。

> 提案日期：2026-08-30
>
> **落地状态（2026-08-30）：核心架构迁移已完成**。本提案的单文档架构已成为唯一渲染路径
> （含 Phase 2 滚动收敛与遗留路径删除，净减 2834 行）。执行记录与偏差说明见
> [`ui-architecture-decision.md`](./ui-architecture-decision.md) §4.3；现行实现地图见 CLAUDE.md。
> 当前决策与源码入口以 [ADR §1](./ui-architecture-decision.md#1-结论) 为准；
> 本文保留原提案推导，不是待迁移任务书。§2 为旧架构诊断，§3 为原设计及实施偏差，
> §5 为历史平台探测，§6/§9 为设计目标而非完整验收声明，§7/§10 的迁移与 fallback 已归档。
> 文档导航见 [`README.md`](./README.md)；“核心架构完成”不表示全部 UX 细则已实现。
>
> **2026-09-11 加固**：保持单文档与文档内 scroll writer；修复冻结前缀误重建，
> 增加隐藏文档暂停投递、JS 单飞/最新快照合并、进程重建快照重放与预算缓存。
> 实施证据及尚未完成的端到端验证见
> [长会话性能复核 §11](./dev-notes/2026-09-11-long-session-rendering-review.md#11-修复实施与验证记录)。
> **现场验证补充**：同文 §12 的真实 200 行复现仍出现 RenderBox/CA 表面分配同步等待；
> 单文档布局与 JS 单飞没有消除原生合成层瓶颈，后续需以 MainActor 延迟和呈现采样验收。
> **随后修复（同日 §13）**：真实状态栏回放把触发点收敛到图标的持续 `symbolEffect(.pulse)`。
> 移除该动画、保留文字呼吸后，同场景秒级等待栈消失；另加单围栏 Text 节点增量更新。
> 三轮含完成礼花的回归最大 MainActor 延迟为 46/9/16ms；完整用户 Debug 环境仍需复测。
> **底部留白优化（同日 §15）**：随后撤除流式 160px 量化，统一自然高度与文档 32px 尾距；
> 尾部隐藏详情不参与最后可见行的下边距计算。交替输出、折叠、保锚及真实宿主回放通过，
> 三轮最大 MainActor 延迟 47.7/7.9/8.3ms；保留文档内唯一 Scroll writer、CV 与绘制唤醒。
> **残余限制（同日 §16，待修复）**：单文档并不保证流式/最终解析语义相同；
> 空行列表重组已测得 26px 高度差和收尾位移，需另行对齐块语义与布局交接，而非恢复人工高度占位。
>
> 作者立场：这是一份**有主张的**提案，不是选项罗列。允许不受当前实现约束。
>
> 相关文档：
> [`ui-architecture-research.md`](./ui-architecture-research.md)（13 仓库调研）·
> [`ui-architecture-research-verification.md`](./ui-architecture-research-verification.md)（源码核验）
>
> 平台能力已在本机 WebKit（macOS 15.4 / Darwin 24.4.0）实测，见 §5。

---

## 1. 一句话结论

**把整条 transcript 收拢进一个 WKWebView，让 Web 引擎同时拥有布局权和滚动权；
原生只保留不随内容滚动的外壳（composer / sidebar / rail 浮层 / 工具栏）。**

原提案理由（“现在”指迁移前）：

> NewPi 现在**付着 Web 引擎的全部成本**（异步边界、独立进程、bridge 往返），
> 却**放弃了它最大的收益**（布局与滚动在同一个同步过程里完成、跨消息选择、查找、免费虚拟化）。
> 单文档架构不是引入新技术，而是**去收回已经付过费的东西**。

单文档为跨消息选择与查找提供基础条件，不代表相关交互已完整验收；CV 也仍需估算高与文档内校正。

---

## 2. 根因：痛点不是 N 个 bug，是一条边界

> **迁移前诊断归档**：以下原生高度表、preheater、每消息 WebView、四处 writer 均非当前结构。
> 原始源码行号与性能动机保留作证据，不应转成现行待办。

迁移前结构（当时已核验）：

```text
SwiftUI VStack（手动窗口化）  ← 布局权 & 滚动权在这里，需要「同步」拿到高度
  ├─ NewPiMarkdownText 行 → WKWebView #1   ← 内容与真实高度在这里，「异步」才知道
  ├─ NewPiToolTranscriptView（原生卡片）
  ├─ NewPiMarkdownText 行 → WKWebView #2
  └─ ...
```

每条 markdown 行一个 WKWebView（`NewPiMarkdownWebRenderer.swift:498`，各自独立
`nonPersistent()` data store、4 个 message handler、独立滚轮转发）。

**布局权在原生侧、内容尺寸在 Web 侧，二者靠异步消息连接。**
下面这些看似无关的问题，全部是这条边界的同一个投影：

| 现象 | 追溯到的根因 |
|---|---|
| 「滚动条越滚越短」 | 未实例化行只能估算高度，估算与真实值不符 |
| `NewPiMarkdownHeightPreheater.swift`（200 行，屏幕内 alpha=0 窗口跑探针 WebView） | 存在的唯一理由：**提前**拿到异步高度，让估算不错 |
| 宽度分桶 + 内容 SHA256 + 跨启动持久的高度缓存 | 存在的唯一理由：避免重复承担异步测量成本 |
| 「自动钉底把恢复的 scrollTo 又拽回底部」（`NewPiChatView.swift:65` 注释） | 多个原生 writer 竞争一个「目标值依赖异步高度」的滚动位置 |
| 「冷启动 scrollTo 被时序吞掉」（`:364` 注释） | 同上 |
| 4 个滚动写入点 / 6 个 onChange 驱动 | 同上 |
| **无法跨消息选择文本** | N 个互相独立的 document |
| **无法全文查找** | 同上 |
| 面板保活、滚轮转发、frame 重叠导致滚动卡死 | N 个 WebView 的生命周期管理 |

**这不是「再修几个 bug」能收敛的**——每修一个，都是在异步边界上再加一层补偿。
预热器就是补偿的补偿：为了让估算准，先用一个隐藏窗口把内容渲染一遍。

调研报告给出的三项待办（滚动状态机、engineFingerprint、block 级高度表）**全部是这条边界的补偿工作**。
它们在迁移前架构下成立；现已移除该边界，原生高度表/指纹任务退役，滚动状态机在文档内落地。

---

## 3. 方案：单文档 Transcript

> **原设计示意**：布局/滚动归属已落地；下方 turn 树及协议不是现行 DOM/API 的逐字规格。
> 当前每条 item 对应 `.ti`，正文使用 per-root renderer；宿主投递 `upsert/remove/order` 等 ops。

```text
NSWindow
 ├─ Sidebar（原生）
 ├─ 主区
 │   ├─ TranscriptWebView（单个 WKWebView，拥有布局权 + 滚动权）
 │   │     <main id="transcript">
 │   │       <section class="turn" data-turn-id="…">
 │   │         <div class="user-msg">…</div>
 │   │         <div class="activity">…折叠的工具时间线…</div>
 │   │         <article class="answer">…block 增量渲染…</article>
 │   │       </section>
 │   │       …
 │   └─ Rail（原生浮层，不在流内，不参与布局）
 └─ Composer（原生，不随内容滚动）
```

三条铁律：

1. **凡是随 transcript 滚动的内容，一律在文档里**（正文、代码块、工具卡、diff、artifact、错误）。
2. **凡是不随 transcript 滚动的，一律在原生**（composer、sidebar、工具栏、rail 浮层）。
3. **原生侧永远不需要知道内容高度。** 这是判断方案有没有走样的唯一试金石。

### 3.1 可以直接删掉的东西

> **原删除评估，已执行并有偏差**：旧原生 preheater/高度表/窗口化/每消息宿主已退役，
> 实际连同 `MarkdownRenderingCache` 与 `engineFingerprint` 删除；下表“产物缓存仍保留”
> 是未沿用的设想。JS Warmer / Poller 仍在文档内处理 CV 占位与几何补偿，不在删除范围内。

| 删除 | 行数 | 为什么不再需要 |
|---|---:|---|
| `NewPiMarkdownHeightPreheater.swift` | 200 | 没有任何原生消费者需要预先知道高度 |
| 高度表作为**布局输入** | — | 文档自己测量自己 |
| 宽度分桶高度缓存 | — | 同上（渲染产物缓存仍保留，用于会话切换即时恢复） |
| 手动窗口化 + 占位逻辑 | — | `content-visibility: auto` 接管（实测支持，见 §5） |
| 每行 WebView 生命周期 / 滚轮转发 / 面板 frame 重叠处理 | — | 只剩一个 WebView |
| 4 writer × 6 driver 的滚动竞争 | — | 滚动只有一个 writer，在文档内，同步 |

粗估净减少 **600–800 行**补偿性代码，且删掉的都是最难维护、注释最长的那部分。

### 3.2 可以原样复用的东西（重要）

> **原复用估计，非当前资产清单**：核心算法保留，但已完成 per-root 工厂化，不是只改 root 参数。
> 原生持久 HTML replay 缓存与 `engineFingerprint` 未保留；JS 兼容 API 仍存在，
> 生产实例明确关闭 `reportHeight` / `postSnapshot`。当前进程恢复重放的是最新 transcript 快照的 ops。

迁移**不是重写渲染器**。现有 `markdown-renderer.js` 的核心资产可直接复用：

| 资产 | 位置 | 复用方式 |
|---|---|---|
| `splitBlocks()` 顶层块切分 | `:196-232` | 原样 |
| `repairTailSource()` 尾部规范化 | `:237-297` | 原样（已优于 osaurus 参考实现） |
| `renderStreaming()` 冻结前缀 + 尾块 patch | `:405-462` | **仅需把 `root` 参数从「文档根」改为「该 turn 的 `<article>`」** |
| `renderBlockNode()` / `enhanceCodeBlocks()` | `:318-341`, `:279-315` | 原样 |
| 渲染产物快照 / replay | `:147`, `:175` | 原样，改为按 turn 存取 |
| 本地资源 + CSP（无 unsafe-inline、`html:false`） | — | 原样 |
| `engineFingerprint()` | `NewPiMarkdownWebRenderer.swift:313-333` | 保留，用于产物缓存失效 |

`renderStreaming(root, source)` 本来就是**对某个容器元素做块级 diff**——
它天然就是「per-turn 渲染器」，只是现在恰好每个容器住在自己的 WebView 里。
这是整个迁移中最幸运的一点：**最难写的部分已经写好且写对了。**

### 3.3 滚动：唯一 writer，同步执行

> **已落地原则与示意接口**：Scroll 意图纪律管理文档内写入，包含 Poller 直接 `scrollBy` 的受控补偿；
> “同批同步”不保证后续 CV 布局永不漂移，当前还使用 Warmer 与有界 RAF 校正。
> 以下接口为原设计，实际为 `jumpTo` / `scrollToBottom` / `restoreAnchor`，恢复保存条目 id + delta，
> 绝对 offset 仅作锚点缺失时的兜底，不是只保存一个 scrollTop。

滚动逻辑全部移入文档内的一个模块，原生侧只发意图、不写位置：

```js
// 单一 writer。所有滚动位置变更必须经过它。
const Scroll = {
  intent: 'idle',   // idle | userScrolling | pinnedBottom | followingStream
                    // | restoringAnchor | jumpingToTarget
  saveAnchor()  { /* 记录首个可见元素 + 元素内偏移 */ },
  restoreAnchor() { /* 变更后按新 rect 重算，差值 <1px 则跳过 */ },
}
```

与 osaurus `ScrollAnchorManager` **算法相同**（topmost visible element + offset，1px 阈值断反馈环），
但有一个决定性差异：

> osaurus 的锚点保存/恢复要跨 `NSTableView` 的 reload 时序；
> NewPi 迁移前要跨**原生 ↔ Web 的异步消息**。
> 在单文档里，保存 → DOM 变更 → 恢复发生在**同一个同步执行块**内，
> 中间不可能插入别的 writer，也不可能有「高度还没回来」的中间态。
>
> **同一个算法，从「尽力而为」变成「确定成立」。**

原生侧的接口收缩为两个方向：

```text
原生 → JS：  appendTurn / patchStreamingTail / freezeTurn / jumpToTurn(id) / restoreSession(scrollTop)
JS → 原生：  scrollTopChanged(y) / turnOffsets([{id, top}]) / userScrolledAway(bool) / copyText / openLink
```

当前 JS→原生的 `scrollState.docHeight` 可作诊断日志，但不参与原生布局；
铁律 3 限制的是**以内容高度驱动原生布局**，不是禁止任何诊断字段。

---

## 4. 为什么不是全原生（osaurus 路线）

调研报告把 osaurus 排在借鉴价值第 1 位，这个判断在「参考实现质量」维度上是对的。
但作为**目标架构**，我不推荐走全原生，理由有三条：

### 4.1 成本与收益不成比例

osaurus 为了达到「能渲染 agent transcript」，写了：

```text
NativeMarkdownView.swift          1644 行
SelectableTextView.swift          1228 行
MessageTableRepresentable.swift   1673 行
ScrollAnchorManager.swift          236 行
StreamingMarkdownBalancer.swift    205 行
+ NativeCodeBlockView / NativeToolCallGroupView / NativeFileDiffView / …
```

近 5000 行 AppKit，换来的能力，其中**排版、代码高亮、表格布局、列表嵌套**这几项，
markdown-it + highlight.js + CSS 是免费给的。
而 NewPi 是**编码 agent**——代码块密度极高，正是 CSS/highlight.js 优势最大的内容类型。

### 4.2 全原生反而拿不到几个关键 UX

- **跨块文本选择**：osaurus 每个 block 一个 `SelectableTextView`，跨 block 选择在 AppKit 里是出了名的难题。
  单文档提供浏览器连续选择的基础条件；折叠内容、虚拟化及复制边界仍需实际验证。
- **全文查找**：需要自己实现跨 cell 的搜索与高亮（osaurus 的 Agent 参考项目单独写了 `Search.swift`）。
  单文档可利用 CSS Custom Highlight API 表达高亮（历史探测见 §5），但搜索、计数、跳转与 Cmd+F 接入仍需实现和验收。

### 4.3 最有力的一条：osaurus 的大部分复杂度是在**重新实现浏览器**

`ScrollAnchorManager`（锚定）、`heightCache`（布局缓存）、diffable block ID（增量）、
`updateTextStorageIncrementally`（脏区最小化）——
这些是浏览器引擎里**已经存在且经过十几年打磨**的机制。

osaurus 重写它们是合理的，因为它选择了不用 Web 引擎。
**但 NewPi 已经在用 Web 引擎了**——只是用它来「画一个个孤岛」，而不是「管一整篇文档」。

> 结论：全原生的**性能天花板**更高，但单文档 Web 的**投入产出比**和**近期 UX 收益**明显更好。
> 如果将来真要走全原生，单文档架构也是更好的起点——
> 那时替换的是一个边界清晰的 `TranscriptView`，而不是散在 SwiftUI 各处的高度表与滚动补丁。

---

## 5. 平台能力实测（不是查表，是本机跑的）

> **历史探测记录**：保留原环境、链接及结果，不代表当前所有部署版本或产品功能已验收；本次未重跑探测。

搜索结果对 `overflow-anchor` 的支持状态互相矛盾
（[caniuse](https://caniuse.com/css-overflow-anchor) 说 Safari 不支持，
但 [WebKit 已合入 `ScrollAnchoringController`](https://github.com/WebKit/WebKit/commit/b19a8ecd83e6c20215a86dc28725fc62fd9ca976)），
因此直接在本机 WKWebView 上探测：

| 特性 | 实测 | 对方案的影响 |
|---|:--:|---|
| `content-visibility: auto` | ✅ | **免费虚拟化**，替代手动窗口化 |
| `contain-intrinsic-size` | ✅ | 未渲染内容的高度预留，滚动条长度稳定 |
| `overflow-anchor` | ❌ | **必须自己在 JS 里实现锚定**（约 40 行，算法同 osaurus） |
| `scrollend` 事件 | ✅ | 滚动状态机的 `userScrolling → idle` 迁移有了准确信号 |
| CSS Custom Highlight API | ✅ | 为不改 DOM 的搜索高亮提供基础，不等于全文查找已实现 |
| `:has()` 选择器 | ✅ | 工具卡状态样式可纯 CSS 表达 |
| 容器查询单位 `cqw` | ✅ | 代码块/表格按容器宽度自适应 |
| `text-wrap: pretty` | ✅ | 正文断行质量 |

`content-visibility` 于 Safari 18 起默认开启
（[WebKit 发布说明](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)），
NewPi 部署目标为 macOS 15.0，恰好覆盖。

**两个必须注意的坑：**

1. `overflow-anchor` 不可用 → 锚定必须手写。这**不削弱**方案：
   手写锚定在单文档里是同步的，比现在跨异步边界的「尽力而为」更可靠。
2. Safari 18.0 存在 `<details>` + `content-visibility: auto` 展开失效的回归
   （[WebKit #277573](https://bugs.webkit.org/show_bug.cgi?id=277573)，18.3 起修复）。
   → **工具卡折叠不要用原生 `<details>`**，用 JS 切 class；或对 `<details>` 不施加 `content-visibility`。

---

## 6. UX 设计细则

> **设计目标，不是完成清单**：文档内工具/思考卡、滚动意图及 rail 比例数据已落地；
> sticky header、聚合摘要、选择/查找等细则不能仅凭架构迁移完成推定已完整实现或验收。

架构之外，以下是我认为真正决定「用起来舒不舒服」的具体决策。

### 6.1 流式期间的阅读稳定性

```text
用户在底部        → 跟随尾部（followingStream）
用户向上滚动任意距离 → 立即停止跟随，显示「跳到最新 ↓」浮标（带未读增量提示）
用户在中部阅读     → 上方内容变化时锚定不动（这是 overflow-anchor 要手写的原因）
点击浮标          → 回到底部并恢复跟随
```

关键：**「是否跟随」由用户的滚动动作决定，不由内容变化决定。**
迁移前的问题正是内容变化会触发钉底，把用户从阅读位置拽走。

### 6.2 Sticky turn header（长会话最高性价比的一项）

在一个长回答里向下滚动时，把对应的**用户提问**以紧凑条的形式 `position: sticky` 吸顶。

编码 agent 的单次回答经常几屏长，滚到中间时「这是在回答我哪个问题」是高频困惑。
CSS 一行的事，收益很大。

### 6.3 工具过程：折叠的活动带，而不是内联噪音

长 agent 运行里 transcript 常有 90% 是工具调用。建议：

```text
折叠态（默认）：  ▸ 读取 12 个文件 · 运行 3 条命令 · 编辑 2 处 · 24s
展开态：          完整时间线，每项可再展开看输出
例外：            失败的工具调用默认展开；用户 pin 的保持展开
运行中：          尾部 3 行预览 + 状态色（借鉴 hanlin-ai 的 blur/fade 分层）
```

把**连续的成功工具调用合并成一行摘要**，是相对当前 NewPi 和大多数调研项目的实质改进——
当时 `NewPiToolTranscriptView.swift` 已有 per-call 的 `collapsedSummary()`，故提出 per-run 聚合。
该原生视图现已删除；本段保留需求动机，不是要求继续改旧视图。

### 6.4 **[与调研报告的结论相反]** 工具卡应该在文档内，不是原生

调研报告 §4 P1 / §7 建议「把工具过程移出正文，做成轻量原生卡片」。
**在迁移前架构下这是对的**（避免为高频更新再开 WebView）。
**在单文档架构下这是错的**，必须反过来：

- 原生卡片插在 Web 内容之间 = 又制造出「原生布局依赖内容高度」的边界，正是要消灭的东西
- 单文档里一次工具状态更新 = **对一个 DOM 元素打补丁**，比现在「一个原生视图 + 周围 WebView 重新协商高度」便宜得多
- 折叠/展开只影响该元素的布局，浏览器自己处理，不需要 `noteHeightOfRows` 之类的补测

**语义分层的主张仍然成立**（正文 / 过程事件必须分离），
但分层应体现为**文档内的结构与样式**，而不是**原生 vs Web 的实现差异**。

### 6.5 代码块（编码 agent 的核心内容类型）

- 长代码块内 `position: sticky` 的语言标签 + 复制按钮（滚动时始终可见）
- 横向滚动**限制在代码块内**，不影响文档
- 「复制」只取代码，不含行号与 chrome（现在的 `copyText` 通道已具备）
- 可选行号；`prefers-reduced-motion` 下禁用高亮动画
- 流式尾块跳过 highlight（**已实现**，`renderBlockNode` 的 `streamingRenderDepth`）

### 6.6 全文查找

原设想：Cmd+F 配合 CSS Custom Highlight API 表达高亮，再实现计数与前后结果跳转。
单文档提供跨条目搜索的基础条件；API 支持不等于搜索流程已完成，也不能据此保证跳转不影响锚定。
本提案不声称 Cmd+F、隐藏/折叠内容检索及跨消息选择已完整验收。

### 6.7 Rail 升级为状态 minimap

Rail 保持原生浮层（不在流内 → 不违反铁律 3），但数据源从高度表换成 JS 上报的 turn offsets
（真实布局值，比高度表更准）。可顺带表达 turn 状态：出错 / 长耗时 / 有 diff。

### 6.8 动画克制

- 只给尾块与新 turn 插入做动画
- 不做逐字符 transition（同意调研报告 P3）
- 尊重 `prefers-reduced-motion`
- 历史建议为保留流式 ✦ 光标与终态淡出；当前 `createMarkdownRenderer` 的 `enableCaret = false`，不再生成光标

---

## 7. 迁移路径（每步可独立发布、可回退）

> **迁移计划归档**：Spike 已 GO，核心迁移已收官，生产 feature flag 与旧路径均已删除。
> 以下为原阶段设计，不再重启；Phase 3/4 的 UX 扩展不因核心迁移完成而自动算作验收通过。
> 删除的是原生 preheater，不是现行 JS Warmer/Poller；实施偏差见 ADR §4.3。

当时要求**不做大爆炸重写**，迁移期用 feature flag 与旧实现并行。

### Phase 0 · Spike（1 个 flag，不动生产路径）

搭一个最小单文档原型，灌入真实的长会话（≥200 turn），量四个数：

```text
冷挂载到首屏可读的耗时
流式期间每帧主线程占用
200 / 500 turn 时的内存占用
滚动流畅度（是否掉帧）
```

**这是 go/no-go 的闸门。** 如果 500 turn 单文档内存或滚动不可接受，
先加 JS 侧窗口化（DOM 只保留最近 N 个 turn，其余留高度占位 stub）再评估。

### Phase 1 · 文档外壳 + 渲染迁移

> **实施偏差**：实际完成 per-root 工厂化，未沿用原生持久 replay 缓存；以下保留原估计。

- 一个 WKWebView 承载 `<main id="transcript">`
- `renderStreaming` 的 `root` 参数改为 turn 的 `<article>`（**核心改动，很小**）
- 已完成 turn 从现有 replay 产物直出（已持久化，可直接用）
- `content-visibility: auto` + `contain-intrinsic-size` 接管虚拟化
- **删除预热器**；高度表退出布局路径
- flag 切换，与现有实现 A/B

### Phase 2 · 滚动收敛

> **实施偏差**：当前恢复使用条目 id + delta 锚点与 offset 兜底，不是仅一个 scrollTop 数字。

- 锚定 + 状态机移入文档内，单 writer
- 原生侧只发意图，`scrollend` 驱动状态迁移
- Rail 改用 JS turn offsets
- 会话切换 = 换文档内容 + 恢复一个 `scrollTop` 数字

### Phase 3 · 工具过程进文档

- 工具时间线 / diff / artifact 改为文档内组件
- per-run 聚合摘要（§6.3）
- `NewPiToolTranscriptView` 退役

### Phase 4 · 收割新能力

- 跨消息选择打磨（复制时剥离 chrome）
- 全文查找（Highlight API）
- Sticky turn header
- Rail 状态 minimap

---

## 8. 风险与对策（诚实清单）

> **原风险评估**：spike/双路径维护项已收官；JS 窗口化为当时条件备选，未据此成为当前 backlog。
> 进程恢复已改为重建外壳 + 最新 transcript 快照重新 upsert + 锚点恢复，非扩展旧 HTML replay watchdog；
> 下表“用户无感”为设计目标，不是完整验收结论。平台、无障碍和真实长会话性能仍需按场景验证。

| 风险 | 严重度 | 对策 |
|---|:--:|---|
| 长会话单文档内存/性能不可接受 | **高** | Phase 0 闸门先验证；备选：JS 侧 turn 窗口化 + 高度 stub |
| `overflow-anchor` 不可用 | 中 | 已确认，手写锚定（同步执行，反而更可靠） |
| 单点故障：一个 WebView 崩溃 = 整条 transcript 白屏 | **高** | 扩展现有白屏 watchdog：崩溃后从 replay 产物重建 + 恢复 scrollTop，用户无感 |
| Safari 18.0 `<details>` + content-visibility 回归 | 低 | 不用 `<details>`，JS 切 class |
| 原生右键菜单 / 拖拽 / 服务菜单 | 中 | 逐项桥接；`copyText` 通道已有先例 |
| 无障碍 | 中 | 加 ARIA role/landmark；WebKit AX 树质量尚可，需实测 VoiceOver |
| 输入法 / 选择手感与原生不一致 | 低 | transcript 是只读区，风险主要在选择，需实测 |
| 迁移期两套实现并存的维护成本 | 中 | flag 生命周期设上限，Phase 2 结束即删旧路径 |

### 明确不做的事

- **不**回退到 per-message WebView 的任何变体
- **不**把原生视图插进 transcript 滚动流（这会重新制造边界）
- **不**为了「原生感」而把正文渲染搬回 SwiftUI Text/AttributedString
- **不**引入 CDN 资源（现有本地化 + CSP 约束保持）
- **不**在流式期间每 delta 写持久模型（现有边界正确，保持）

---

## 9. 验收指标

以下是**原提案目标，不是已通过的验收清单**；已记录的验证范围以 ADR 和具体回归文档为准。
单文档为跨消息选择/查找提供基础条件，不证明这些目标已满足。
架构提案要能被证伪，可按实际需求将指标纳入 CI 或手动回归：

```text
正确性
  滚动条长度在整条会话滚动过程中单调稳定（不出现「越滚越短」）
  会话切换后视口位置与切走时一致，误差 < 2px
  流式期间用户滚到中部阅读，上方内容变化不移动视口
  窗口 resize 后阅读位置保持（锚定生效）

能力（原提案目标，不能由迁移完成推定已验收）
  可从一条消息正文连续选择到下一条消息
  Cmd+F 可在整条 transcript 内查找并跳转
  长回答滚动时可见所属提问（sticky header）

性能
  流式期间主线程每帧 < 8ms
  500 turn 会话冷挂载首屏可读 < 500ms
  500 turn 会话常驻内存增量 < 现有实现

代码
  原生侧不存在任何「消费内容高度」的路径（铁律 3 的静态检查）
```

最后一条是最重要的：**它把架构主张变成了一条可以持续检查的约束。**

---

## 10. 如果只做一件事

> **历史决策建议与未启用 fallback**：下面的未知数已通过当时 spike 闸门，执行状态见 ADR §4.2–§4.3；
> 旧原生路径已删除，核验报告三项旧待办不是当前 backlog。未来若需复议，应重新决策而非照此回退。

在提案尚未验证时，如果排期只允许做一件事，建议先做 **Phase 0 的 spike**。

因为这个方案的全部收益都建立在「单文档在 500 turn 规模下性能可接受」这一假设上，
而这个假设**我没有验证过**——它是本提案最大的未知数。
花一两天证实或证伪它，比按现有架构再修三个滚动 bug 的信息量大得多。

若 spike 证伪，退路很清晰：
维持迁移前架构，执行当时核验报告 §5 的三项待办（滚动状态机 → engineFingerprint → block 级高度表），
并把本文 §6 的 UX 细则（sticky header 除外）在现有架构上逐条落地。
