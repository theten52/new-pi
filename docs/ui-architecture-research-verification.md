# UI 架构调研报告 —— 源码核验记录

> 核验日期：2026-08-30
>
> 核验对象：[`docs/ui-architecture-research.md`](./ui-architecture-research.md)（13/13 源码级调研报告）
>
> 核验方法：对 `research-repos/` 下 13 个克隆仓库逐条比对 commit / 文件路径 / 行号 / 具体数值；
> 对报告中关于 NewPi 自身现状的论断，逐条比对 `NewPiApp/` 实际代码。
>
> 核验目的：调研报告直接决定后续排期。若它对 NewPi 现状的判断有偏差，会导致重做已完成的工作。

---

## 0. 总体结论

**外部仓库部分可信，可直接作为参考资料使用。问题集中在报告对 NewPi 自身现状的描述——它把三项已经落地的能力当成了待办。**

| 维度 | 结论 |
|---|---|
| 13 个 commit SHA + remote URL | 全部精确匹配 |
| 外部源码引用（路径 / 行号 / 数值） | 抽查覆盖 13 个仓库，基本准确；3 处小疏漏 |
| 报告主动标注的 3 处"修正" | 全部成立，且其中 1 处比报告写的更严重 |
| 关于 NewPi 现状的论断 | **有实质性偏差**：报告内部自相矛盾，§0 承认已有的能力在 §4/§5/§7 又被列为缺口 |
| 报告提出的真实缺口 | 3 项成立（见 §4），但其中 1 项的建议方案不如 NewPi 现有机制 |

---

## 1. 外部调研部分：核验通过

### 1.1 仓库身份

13 个仓库的 `git rev-parse HEAD` 与 `remote get-url origin` 均与报告 §1 表格一致：

```text
SwiftStreamingMarkdown  95bb755   microsoft/SwiftStreamingMarkdown
stream-chat-swift-ai    8b43140   GetStream/stream-chat-swift-ai
markdown-webview        d1c3e0a   tomdai/markdown-webview
MLXCode                 fe8634e   kochj23/MLXCode
SwiftChat               d6f54cc   sachaservan/SwiftChat
osaurus                 a176057   osaurus-ai/osaurus
Agent                   89af9de   macOS26/Agent
hanlin-ai               f3782a7   CherryHQ/hanlin-ai
OmniChat                058fa47   bowenyu066/OmniChat
ChatGPTSwiftUI          bda026e   alfianlosari/ChatGPTSwiftUI
AICat                   9f978cd   Panl/AICat
mlx-swift-chat          b0763e6   preternatural-explore/mlx-swift-chat
swift-markdown-ui       8371aeb   gonzalezreal/swift-markdown-ui
```

### 1.2 源码论断抽查

| 报告论断 | 核验结果 | 实际位置 |
|---|---|---|
| SwiftStreamingMarkdown convenience path 固定 `speculativeRewrite: false` | ✅ | `MarkdownParser.swift:25,38` |
| `ParagraphViewCache` maxCacheSize = 50，只复用脱离 window/superview 的实例 | ✅ | `ParagraphViewCache.swift:11,35-37` |
| `MarkdownRenderable` 因 `NSMutableAttributedString` 非线程安全（源码注释明示） | ✅ | `MarkdownRenderable.swift:14` |
| GetStream `letterInterval = 0.005`（5ms 字符队列） | ✅ | `StreamingMessageView.swift:27` |
| GetStream 代码块按语言路由到 chart renderer | ✅（列表少写 1 项，见 §2.4） | `StreamingMessageView.swift:22` |
| markdown-webview 全量 `innerHTML` 替换 | ✅ | `Resources/template:99` |
| markdown-webview 依赖 CDN（KaTeX / Font Awesome / texmath） | ✅ | `Resources/template:58-62` |
| markdown-webview 用 ResizeObserver 回报高度 | ✅ | `Resources/template:129` |
| MLXCode 用 `id: \.offset` 作 block identity | ✅ | `MarkdownTextView.swift:45`、`EnhancedMessageView.swift:100` |
| MLXCode 逐字 Timer 10ms | ✅ | `EnhancedMessageView.swift:127`（0.01） |
| SwiftChat `completedChunks` + `workingBuffer` + `working_current`/`working_table` | ✅ | `StreamingMarkdownChunker.swift:36-37,50-51` |
| SwiftChat completed id 混入 `Date().timeIntervalSince1970` + `hashValue` | ✅ | `:91,127,143,159,182` |
| SwiftChat 两级高度缓存（IndexPath + message id） | ✅ | `MessageTableView.swift:268-269` |
| SwiftChat 负 bottom content inset | ✅ | `MessageTableView.swift:423` |
| SwiftChat at-bottom 判定 150pt slack | ✅ | `MessageTableView.swift:526` |
| SwiftChat `ChunkView` 完成态只比较 id/darkMode | ✅ | `MessageView.swift:1085-1096` |
| osaurus 头注释写 automatic row heights，实际设为 `false` | ✅ **报告的修正正确** | `MessageTableRepresentable.swift:9` vs `:367` |
| osaurus 锚点 = topmost visible row + offset from row top | ✅ | `ScrollAnchorManager.swift:13-15,95-97` |
| osaurus 目标差值 ≤1pt 跳过（断反馈环） | ✅ | `ScrollAnchorManager.swift:112-115,134` |
| osaurus `bottomThreshold = 50` | ✅（行号归错段，见 §2.5） | `ScrollAnchorManager.swift:30` |
| osaurus 展开折叠后 50ms / 350ms 两次补测高度 | ✅ | `MessageTableRepresentable.swift:675,678` |
| osaurus `StreamingMarkdownBalancer` 只处理最后一个非 fenced 段的最后段落 | ✅ | `StreamingMarkdownBalancer.swift:11-14,40-43` |
| osaurus balancer 策略（裸 list marker、新开无内容标记、odd backtick/`**`） | ✅ | `StreamingMarkdownBalancer.swift:59-91` |
| osaurus `updateTextStorageIncrementally` 首个差异块 + damage start | ✅ | `SelectableTextView.swift:230-301` |
| Agent 64 字符窗口校验 prefix 未被破坏 | ✅ | `Update.swift:87` |
| Agent 遇 table 全量 rebuild | ✅ | `Update.swift:100-116` |
| Agent tab 缓存 textStorage/length/hash/scrollY | ✅ | `Cache.swift:9-40` |
| Agent 滚动 100ms throttle + 仅在底部时执行 | ✅ | `Scroll.swift:57-62` |
| Agent 50K 日志上限 | ✅ | `Models/LogLimits.swift:9`、`ScriptTab.swift:285` |
| hanlin 默认显示最后 20 条 | ✅ | `ChatView.swift:164-166` |
| hanlin matched message 向上取整到 10 的倍数 | ✅ | `ChatView.swift:164` |
| hanlin 折叠态 tail 3 行 + blur/opacity 分层 | ✅ | `ChatViewComponents.swift:508,525-527` |
| hanlin matched 后延迟 0.5s + 0.5s 再 center | ✅ | `ChatView.swift:681,684` |
| OmniChat 自适应 UI 频率 50/70/100/140ms | ✅ | `ChatView.swift:55-62` |
| OmniChat 高度 0/100/300ms 三次补测 | ✅ | `MarkdownView.swift:419-421` |
| OmniChat streaming 降级为 `Text`，完成后才用 WKWebView | ✅ | `MessageView.swift:161,171` |
| OmniChat 每次 `loadHTMLString` 全量 reload | ✅ | `MarkdownView.swift:109` |
| ChatGPTSwiftUI `ResponseParsingTask` 是 actor | ✅ | `ResponseParsingTask.swift:11` |
| ChatGPTSwiftUI 64 字符阈值 / code fence 触发 parse | ✅ | `ViewModel.swift:133,142` |
| AICat 仅在含 ``` 时走 MarkdownUI | ✅ | `MessageView.swift:141` |
| AICat 每 delta `upsertMessage` 并 sort | ✅ | `ConversationView.swift:105,288` |
| swift-markdown-ui `Indexed` = index + value 组成 Hashable | ✅ | `Utility/Indexed.swift:3-9` |
| swift-markdown-ui 处于维护模式，新开发在 Textual | ✅ | `README.md:1-5` |
| mlx-swift-chat 是 prompt/completion 工作台而非多轮 chat | ✅ | `ContentView.swift:100-131` |
| SwiftChat 有独立 web search / URL fetch 过程卡片 | ✅ | `Views/WebSearchBox.swift`、`Views/URLFetchBox.swift` |

### 1.3 报告主动标注的三处"修正"

报告在 §2.1、§2.5、§2.6 主动指出了三处"README/注释与代码不符"，全部成立：

1. 微软 `StreamedMarkdownView` 默认路径**没有**启用 speculative rewrite ✅
2. osaurus 文件头注释与 `makeTableView()` 实际设置矛盾 ✅
3. SwiftChat completed chunk id 混入时间戳、且 `hashValue` 随进程随机种子变化，不可用作持久缓存 key ✅

这三处是报告质量的加分项——它没有停留在注释和 README 层面。

---

## 2. 发现的错误

### 2.1 `Markup.id` 的描述不准（报告 §2.1，第 100-103 行）

报告写：

> 它的 id 来自 `Markup.id`，而 `Markup.id` 是从根节点到当前节点的 parent/index 路径

实际代码（`Sources/MarkdownText/Models/Markup+ID.swift:11-19`）：

```swift
var id: String {
  var parentNode = self.parent
  var path = [String]()
  while parentNode != nil {
    path.append(String(self.indexInParent))   // ← 始终是 self，从不推进到 parentNode
    parentNode = parentNode?.parent
  }
  return path.joined(separator: "-")
}
```

循环体内 append 的永远是 `self.indexInParent`，游标 `parentNode` 只用于控制循环次数。所以 id 实际是
**"同一个数字重复 depth 次"**（如深度 3、索引 2 的节点得到 `"2-2-2"`），而不是一条真正的路径。
后果：同深度同 indexInParent 的不同子树节点会直接**碰撞**。

报告的结论（"不能盲目标榜为跨任意 re-parse 的永久身份"）方向正确，但**低估了严重程度**——
它连"结构稳定的前缀"都不能可靠保证。

**修正方式**：已在报告 §2.1 就地改写。

### 2.2 报告把 NewPi 已完成的工作列为待办（报告 §0 / §4 / §5 / §7）

这是本次核验最主要的发现，详见 §3。

### 2.3 "NewPi：已有 NSCache + preheater"不准（报告 §4 P0 高度缓存 key 一节）

`MarkdownRenderingCache` 用的不是 `NSCache`，而是嵌套字典 + `lastAccess` 时间戳做 LRU，
并持久化到 `~/.new-pi/agent/markdown-height-cache.json`：

- `NewPiApp/NewPiMarkdownWebRenderer.swift:43-44` —— `buckets: [String: [String: Entry]]`
- `NewPiApp/NewPiMarkdownWebRenderer.swift:55-56` —— 持久化文件路径

差异有实质意义：`NSCache` 会在内存压力下自动驱逐且不跨启动存活，而当前实现是**跨启动持久**的，
这正是冷恢复预热能生效的前提。

**修正方式**：已在报告 §4 就地改写。

### 2.4 GetStream chart 语言列表少写一项（报告 §2.2）

报告写 `json/chart/chartjs/echarts/highcharts/vega-lite`（6 项），
实际（`StreamingMessageView.swift:22`）是 7 项，末尾还有 `vegalite`（无连字符写法）。

**修正方式**：已在报告 §2.2 补齐。

### 2.5 osaurus `bottomThreshold` 行号归错段（报告 §2.6）

报告把"bottom threshold 50pt"写在"见 `ScrollAnchorManager.swift:120-162`"之下，
但该常量实际在 `ScrollAnchorManager.swift:30`。数值本身正确。

**修正方式**：已在报告 §2.6 就地改写。

### 2.6 仓库内路径前缀不一致（报告 §2.5、§2.7）

报告对多数仓库使用仓库内真实路径，但 SwiftChat 与 Agent 两处少写了一层同名目录：

| 报告写法 | 实际路径 |
|---|---|
| `SwiftChat/Services/StreamingMarkdownChunker.swift` | `SwiftChat/SwiftChat/Services/StreamingMarkdownChunker.swift` |
| `SwiftChat/Views/MessageTableView.swift` | `SwiftChat/SwiftChat/Views/MessageTableView.swift` |
| `Agent/Views/ActivityLog/Update.swift` | `Agent/Agent/Views/ActivityLog/Update.swift` |

不影响结论，但直接复制路径会找不到文件。

**修正方式**：已在报告 §1 增加路径约定说明。

---

## 3. 关于 NewPi 现状的偏差（核心问题）

报告 §0 第 1 条承认 NewPi "已经有本地资源、块级增量、render-once / replay-forever、高度预热和滚动转发"，
但 §4 P0、§5 第二步、§7 又把其中三项写成缺口。按报告的"实现顺序"执行，会重做已有代码。

### 3.1 块级增量 + 冻结前缀：**已实现**

报告 §5「第二步：JS API 从 document render 改为 block patch」描述的是待办。
实际 `NewPiApp/MarkdownRenderer/markdown-renderer.js:405-462` 的 `renderStreaming()` 已经在做：

```js
// 与上一帧的公共前缀（冻结块逐字节对齐）
let common = 0;
const maxCommon = Math.min(renderedBlocks.length, blockCount);
while (common < maxCommon && renderedBlocks[common].source === blocks[common]) {
  common += 1;
}

// 冻结前缀分叉（源变短 / 内容被编辑）：退回全量重渲染
if (common < frozenLimit && common < renderedBlocks.length) { /* 清空重来 */ }

for (let i = common; i < blockCount; i += 1) {
  const isTail = i === blockCount - 1;
  // 冻结块带 hljs 高亮；尾块流式渲染（无高亮 + 修复未闭合结构）
  const node = renderBlockNode(renderSource, !isTail);
  ...
}
```

已具备的性质：

- 顶层块切分，围栏代码块内部不切（`splitBlocks`，`:196-232`）
- 公共前缀逐字节冻结对齐，冻结块不重建 DOM
- 冻结前缀分叉时安全退回全量重渲染
- 源变短时裁掉多余尾节点
- 只有尾块跳过 hljs 高亮（`renderBlockNode`，`:318-341`）
- 重放页误收流式更新的防御分支（`:410-415`）

**相对报告建议仍缺的**：块没有显式 ID，靠数组下标 + source 逐字节比对对齐。
这是一种隐式 identity（ordinal + content），在"只追加/只尾部变化"的前提下成立，
且分叉时有全量兜底。报告 §4 P0 建议的显式 `RenderBlockID` 是**合理的加固，不是从零补齐**。

### 3.2 尾部规范化（tail normalization）：**已实现**

报告 §4 P0 与 §7 建议"补上 tail-only normalization"、"尾部规范化可参考 osaurus"。
实际 `markdown-renderer.js:237-297` 的 `repairTailSource()` 已经在做同一件事，
且在两个点上比 osaurus 的 `StreamingMarkdownBalancer` 更保守：

| 场景 | osaurus balancer | NewPi `repairTailSource` |
|---|---|---|
| 未闭合代码围栏 | 保留原样不动 | 补闭合行，让代码块正常渲染而非吞掉后续文本 |
| 未闭合行内代码 | odd backtick 补虚拟闭合 | 先剥掉已闭合代码段再计数，odd 则补 `` ` `` 并**就此止步** |
| 未闭合 `**` | 朴素计数 `**` 出现次数，odd 则补 | 要求最后一次出现后**紧跟非空白**才补（`2 ** 3` 不误判） |
| `__` / `~~` | 未处理 | 均处理 |
| 是否改动原始 source | 否 | 否（注释明示"仅作用于渲染副本"） |

osaurus 自己的注释也承认它的朴素计数在"行内代码里出现字面 `**`"时会多补一个虚拟闭合符
（`StreamingMarkdownBalancer.swift:87-89`）。NewPi 的 `withoutCodeSpans` 预处理正好规避了这一点。

**结论**：这一项 NewPi 领先于报告推荐的参考实现，不应列为待办。

### 3.3 rail 跳转的高度未就绪等待 + 有界校正：**已实现**

报告 §4 P1 建议"rail jump 必须等目标 block 高度 ready，再做有界校正"、
"目标高度未 ready 时的 pending jump 状态"。实际已存在：

- `NewPiApp/NewPiChatView.swift:58-63` —— `RailTarget` 结构 + `pendingRailTarget` 状态
- `NewPiApp/NewPiChatView.swift:403-424` —— `applyPendingRailCorrection()`，
  预热仍在填充几何时跟进校正，数据稳定后清空，**且用户接管滚动时主动放弃不打断**

### 3.4 报告对 NewPi 的其余描述属实

以下均已核对属实，可放心引用：

- 本地资源、无 CDN：`NewPiApp/MarkdownRenderer/` 内含 `markdown-it.min.js`、`highlight.min.js`、
  `highlight-github.min.css`、`github-markdown-light.css`，模板中无外链
- render-once / replay-forever：`postRenderedSnapshot()`（`:147`）+ `window.replayRendered()`（`:175`）
- ResizeObserver 高度桥：`observeRootHeight()`（`:102`）+ `scheduleHeightPost()`（`:91`）
- 高度预热：`NewPiMarkdownHeightPreheater.swift`，屏幕内 alpha=0 窗口承载探针 WKWebView，
  串行、单行 3s 看门狗、上限 120 条
- 手动窗口化 + 高度表：`NewPiChatView.swift:45-46,97`，用 `VStack` 而非 `LazyVStack`，
  可见区外用表内精确高度占位（注释明示 LazyVStack 估算是 rail 与滚动条问题的根）

---

## 4. 真实成立的待办（已与代码交叉验证）

去掉已完成项后，报告中真正有效的缺口是以下三项。

### 4.1 高度缓存 key 未纳入引擎指纹 —— 有实际隐患

`MarkdownRenderingCache` 的两个查询路径对"渲染器变更"的处理不一致：

| 查询 | 引擎校验 | 位置 |
|---|---|---|
| `renderedHTML(for:engine:)` | ✅ `entry.engine == engine`，注释明示"渲染器/样式变更后旧产物整体作废" | `NewPiMarkdownWebRenderer.swift:101-110` |
| `height(for:)` / `height(for:width:)` | ❌ 无任何引擎校验 | `NewPiMarkdownWebRenderer.swift:60-78` |

**后果**：改动 `MarkdownRenderer/` 下的 js/css 后，HTML 产物会正确失效并重新渲染，
但**旧高度仍然命中**——高度表、窗口占位、rail y 坐标会全部基于过期几何。

**注意**：报告 §4 P0 建议在 key 中加 `rendererVersion: Int`（手工维护版本号），
但 NewPi 已有更好的机制——`NewPiMarkdownWebDocument.engineFingerprint()`
（`NewPiMarkdownWebRenderer.swift:313-333`）对整个 `MarkdownRenderer/` 目录的
js/css 内容做 SHA256，**无需手工维护版本号**。

因此正确的动作不是"引入 rendererVersion"，而是**把已有的 `engineFingerprint` 接进高度查询路径**。

同时，报告提到的 theme / fontScale 目前确实完全不在 key 内（当前 key 仅 = 宽度桶 + 内容 SHA256）。

### 4.2 高度表停留在 message 级，未下沉到 block 级

预热与缓存都以整条 transcript item 为单位算 SHA256：

- `NewPiMarkdownHeightPreheater.swift:49-52` —— 按 `item.body` 整体查 miss
- `NewPiMarkdownWebRenderer.swift:158` —— `SHA256.hash(data: Data(markdown.utf8))`

JS 侧也只上报 root 整体高度（`scheduleHeightPost` / `measureRootHeight`），不带 blockID。

**后果**：一条长消息内任一块变化，整条的高度缓存即失效；
块级折叠/展开无法只失效单块（对应报告 §5 第五步"展开只 invalidate 单个 block 高度"）。

报告 §5 第三步「高度表接入 blockID」成立。

### 4.3 滚动写入未收敛为显式状态机

`NewPiChatScrollHelper.swift` 仅 101 行，实质是 per-session 锚点持久化（`Entry: rowID/delta/offset`）
与两个 PreferenceKey，**不含滚动意图状态**。

实际滚动写入分散在 `NewPiChatView.swift` 的 4 处执行点、6 个 `onChange` 驱动：

```text
写入点：:216 (rail jump)  :371 (冷启动恢复)  :423 (rail 有界校正)  :452 (钉底)
驱动：  :283 transcript.map(\.id)   :286 geometry.size.width   :301 runtime.isStreaming
        :312 transcript.last?.id    :316 transcript.last?.body  :320 composerHeight
```

代码注释本身已记录过这类竞争的症状（`:65` "自动钉底会在恢复 scrollTo 落地后把会话又拽回底部——
原位恢复失效的根因"；`:364` "冷启动时内容布局/门控/钉底都在并发进行，单次 scrollTo 可能被时序吞掉"）。

报告 §4 P1 的 `ChatScrollIntent` 状态机与"同一时刻只有一个 writer"约束成立，
是三项待办中最有价值的一项。

---

## 5. 给后续排期的净结论

```text
已完成，不要重做：
    块级增量渲染 + 冻结前缀对齐        markdown-renderer.js:405-462
    尾部规范化（优于 osaurus 参考实现） markdown-renderer.js:237-297
    rail pending jump + 有界校正        NewPiChatView.swift:58-63,403-424
    本地资源 / replay / ResizeObserver / 高度预热 / 手动窗口化

待办（按价值排序）：
    1. 滚动写入收敛为显式状态机          4 个写入点 + 6 个 onChange 驱动
    2. engineFingerprint 接进高度查询     height(for:) 缺引擎校验（有实际隐患）
       并考虑把 theme / fontScale 纳入 key
    3. 高度表下沉到 block 级              JS 高度上报需带 blockID

可选加固：
    块的隐式 identity（下标 + source 比对）改为显式 RenderBlockID
```

---

## 6. 方法备注

本次核验遵循 `code-review-lessons` 的三条要求：完整阅读、用实际代码交叉验证、检查反证。

具体做法：不接受报告中任何"见 xxx.swift:N-M"的引用而不打开对应文件；
对报告关于 NewPi 的每一条论断，都在 `NewPiApp/` 中找到对应实现或确认其不存在。
§3 的全部发现都来自后一步——**只核对外部仓库不会发现这类问题**。
