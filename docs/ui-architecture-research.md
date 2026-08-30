# NewPi UI 架构调研报告（13/13 源码级）

> 调研日期：2026-08-30
>
> 调研根目录：`./`（本仓库根）
>
> 固定克隆目录：`./research-repos`
>
> 调研目标：逐个阅读 13 个 Swift 仓库源码，聚焦 NewPi 最关心的 UI 展现：流式 Markdown、消息列表、高度、滚动恢复、rail 定位、工具过程与代码块。
>
> 结论状态：13 个仓库均已克隆并阅读源码；本文不再依赖 README 推断。
>
> **核验状态（2026-08-30）**：本文已通过源码级核验，见
> [`ui-architecture-research-verification.md`](./ui-architecture-research-verification.md)。
> 13 个 commit 与外部源码引用核验通过；关于 NewPi 自身现状的描述发现实质偏差，已在本文就地修正。
>
> **后续状态（2026-08-30）**：本调研驱动的单文档迁移已完成（Spike GO → Phase 1/2 →
> dogfood 验收 → 遗留路径删除）。本文中关于 NewPi「现状」的描述均为迁移前状态，
> 仅作历史记录；现行架构见 [`ui-architecture-decision.md`](./ui-architecture-decision.md)。
> 修正处均标注 `[已核验]` 或 `[核验修正]`。
>
> **后续提案（2026-08-30）**：本文的建议均以「保留当前 per-message WKWebView 架构」为前提。
> 若允许调整架构前提，另有一份目标架构提案主张**收拢为单文档 transcript**：
> [`ui-target-architecture.md`](./ui-target-architecture.md)。
> 该提案在若干点上**与本文结论相反**（最明显的是工具卡该原生还是该进文档，见其 §6.4），
> 分歧源于架构前提不同，不是本文有错。两文对照阅读。

---

## 0. 先说结论

> **[核验修正]** 本节初版把三项 NewPi 已落地的能力同时写进了"待借鉴"，与 §4/§5/§7 自相矛盾。
> 现按"已完成 / 待办"重新表述。净待办清单见 §4.0 与核验报告 §5。

NewPi 当前方向是对的，而且比大多数参考项目更接近问题的核心：

1. **不要放弃 WKWebView 路线**。NewPi 已经有本地资源、块级增量、render-once / replay-forever、高度预热和滚动转发；这比 OmniChat 的“每次重新 load HTML”和 markdown-webview 的“每次全量 innerHTML”更强。**[已核验]**
2. **渲染粒度已经在 block 级，缺的是显式 identity**。`renderStreaming()` 已实现公共前缀冻结对齐 + 只重渲染尾块 + 分叉时全量兜底（`markdown-renderer.js:405-462`）**[已核验]**。SwiftChat 的 `completedChunks + workingBuffer` 与 osaurus 的稳定 block ID 值得借鉴的**只剩显式 ID 这一层**——当前靠数组下标 + source 逐字节比对做隐式对齐，属可选加固而非缺口。
3. **流式尾部规范化已经实现，且优于参考实现**。`repairTailSource()`（`markdown-renderer.js:237-297`）**[核验修正：初版误列为待办]** 处理未闭合围栏 / 行内代码 / `**` / `__` / `~~`，并且先剥离已闭合代码段、要求标记后紧跟非空白才修复——osaurus 的 `StreamingMarkdownBalancer` 自己的注释承认它的朴素 `**` 计数在这两种场景下会多补虚拟闭合符（`StreamingMarkdownBalancer.swift:87-89`）。此项无需再借鉴。
4. **高度表是 NewPi 的正确资产，但 key 有实际隐患**。SwiftChat 的两级高度缓存和 osaurus 的 block 高度缓存都验证了这个方向。**[核验修正]** 真正的问题不是"引入 rendererVersion"——NewPi 已有更好的 `engineFingerprint()`（对整个 `MarkdownRenderer/` 目录 js/css 做 SHA256，无需手工维护版本号）；问题是**它只约束了 HTML 产物查询、没有约束高度查询**，改动渲染器后旧高度仍会命中。详见 §4 P0 与核验报告 §4.1。
5. **滚动必须显式建模**。参考 osaurus 的规则：snapshot 前保存锚点，snapshot 后恢复；只有用户原本在底部才 pin-to-bottom；程序滚动要能取消用户滚动意图。
6. **工具过程不要混进正文 Markdown**。MLXCode、osaurus、Agent 都把工具执行、diff、活动日志做成独立卡片 / timeline / activity log。NewPi 也应把“语义消息”和“过程事件”分层。
7. **简单 SwiftUI chat 示例不能解决 NewPi 的问题**。ChatGPTSwiftUI、AICat 这类项目的历史规模、富文本复杂度和 rail 需求远低于 NewPi；它们只适合作为 baseline 和反面参照。

最重要的一句话：

> NewPi 应该把 WKWebView 当成 **document renderer**，把 SwiftUI 当成 **容器与状态编排层**，把高度表和滚动 coordinator 当成唯一布局/滚动事实源；高频过程 UI 则逐步下移到更轻的原生视图。

---

## 1. 仓库清单与定位

| # | 仓库 | Clone commit | UI 核心路线 | 对 NewPi 的主要价值 |
|---|---|---:|---|---|
| 1 | microsoft/SwiftStreamingMarkdown | `95bb755` | snapshot re-parse + block renderable + AppKit/UIKit text view | block identity、推测性重写、段落实例池 |
| 2 | GetStream/stream-chat-swift-ai | `8b43140` | SwiftUI + MarkdownUI + character queue | streaming message API、代码块语言路由 |
| 3 | tomdai/markdown-webview | `d1c3e0a` | WKWebView + markdown-it + JS bridge | WebView 生命周期、高度同步、滚动转发 |
| 4 | kochj23/MLXCode | `fe8634e` | SwiftUI macOS coding assistant | 工具结果卡片、代码块、本地模型状态 |
| 5 | sachaservan/SwiftChat | `d6f54cc` | UITableView + UIHostingConfiguration + chunker | 块级分片、高度缓存、流式 row 更新 |
| 6 | osaurus-ai/osaurus | `a176057` | NSTableView + diffable block ID + 纯 AppKit 渲染 | 最接近 NewPi 的高级形态：block diff、高度、锚点、工具组 |
| 7 | macOS26/Agent | `89af9de` | NSTextView activity log | 过程日志增量 append、tab 缓存、滚动保持 |
| 8 | CherryHQ/hanlin-ai | `f3782a7` | SwiftUI iOS chat + MarkdownUI/LaTeX | 历史窗口、推理/工具折叠、状态尾部预览 |
| 9 | bowenyu066/OmniChat | `058fa47` | macOS SwiftUI + WKWebView | 同路线对照；流式 UI 节流与 SwiftData 解耦 |
| 10 | alfianlosari/ChatGPTSwiftUI | `bda026e` | SwiftUI cross-platform baseline | 简单 baseline；显示无滚动 guard 的局限 |
| 11 | Panl/AICat | `9f978cd` | SwiftUI multiplatform chat | 产品层结构、MarkdownUI/Splash、性能取舍 |
| 12 | preternatural-explore/mlx-swift-chat | `b0763e6` | SwiftUI prompt/completion + model manager | 模型加载/生成进度状态，而非 chat 渲染 |
| 13 | gonzalezreal/swift-markdown-ui | `8371aeb` | cmark AST → SwiftUI blocks | Markdown API、主题、代码块扩展点；维护模式 |

**[核验修正] 路径约定**：下文 §2 各节的源码引用是「仓库内路径」，需拼在 `research-repos/<仓库名>/` 之后。
其中 SwiftChat 与 Agent 两个仓库的源码在同名子目录下，引用时少写了一层，实际为：

| 本文写法 | 实际路径 |
|---|---|
| `SwiftChat/Services/…`、`SwiftChat/Views/…` | `research-repos/SwiftChat/SwiftChat/…` |
| `Agent/Views/ActivityLog/…` | `research-repos/Agent/Agent/Views/ActivityLog/…` |

目录索引：

```text
research-repos/
├── SwiftStreamingMarkdown/
├── stream-chat-swift-ai/
├── markdown-webview/
├── MLXCode/
├── SwiftChat/
├── osaurus/
├── Agent/
├── hanlin-ai/
├── OmniChat/
├── ChatGPTSwiftUI/
├── AICat/
├── mlx-swift-chat/
└── swift-markdown-ui/
```

---

## 2. 逐仓库源码发现

### 2.1 microsoft/SwiftStreamingMarkdown

**本地路径**：`research-repos/SwiftStreamingMarkdown/`

#### 核心架构

```text
AsyncStream<String> complete snapshot
  → MarkdownParserImpl.parse
  → RenderableDocument([MarkdownRenderable])
  → DocumentView / BlockView
  → paragraph/code/list/table views
```

`StreamedMarkdownSource` 明确要求每次输出是完整 Markdown snapshot，不是 delta：

- `Sources/MarkdownText/StreamedMarkdownView.swift:10-16`
- `StreamedMarkdownController.start()` 每次收到 snapshot 后重新 parse，并替换 `markdownToRender`：`Sources/MarkdownText/StreamedMarkdownView.swift:84-95`

#### 对 NewPi 有价值的点

**① Block renderable 自带 ID**

- `MarkdownRenderable` 是 `Identifiable`，每个 paragraph/code/table/list 都有 id：`Sources/MarkdownText/Models/MarkdownRenderable.swift:16-61`
- `BlockView` 用 `ForEach(renderables)` 渲染块：`Sources/MarkdownText/UI/BlockView.swift:19-24`

需要注意：它的 id 来自 `Markup.id`，不是 parser 内置的持久 UUID。
**[核验修正]** 初版把它描述为"从根节点到当前节点的 parent/index 路径"，但实际实现比这更弱
（`Sources/MarkdownText/Models/Markup+ID.swift:11-19`）：

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

循环体内 append 的永远是 `self.indexInParent`，游标 `parentNode` 只用于控制循环次数。
所以 id 实际是**同一个数字重复 depth 次**（深度 3、索引 2 的节点得到 `"2-2-2"`），并非真正的路径——
同深度同 `indexInParent` 的不同子树节点会直接**碰撞**。

因此它连“结构稳定的前缀”都不能可靠保证，更不能标榜为跨任意 re-parse 的永久身份。NewPi 应把 **ordinal + block kind + frozen content fingerprint** 组合起来，而不是只复制 path id。

**② 推测性重写能力存在，但默认流式路径没有启用**

parser 支持：

- partial emphasis rewrite
- partial table rewrite

见：

- `Sources/MarkdownText/Parser/MarkdownParseOption.swift:7-14`
- `Sources/MarkdownText/Parser/MarkdownParserImpl.swift:26-40`
- `Sources/MarkdownText/Parser/Scanners/MarkupPostParsingRewriter.swift:19-52`

但 `StreamedMarkdownController` 走的是 `parse(text:config:)` convenience path，而这个 path 固定 `speculativeRewrite: false`：

- `Sources/MarkdownText/Parser/MarkdownParser.swift:28-39`

这是一个重要修正：**能力值得借鉴，但不能说它的默认 StreamedMarkdownView 已经自动处理不完整 emphasis/table**。NewPi 若引入类似 rewrite，应显式打开并补测试。

**③ 预处理结果尽量离开 SwiftUI diff**

`MarkdownRenderable` 的注释明确说 parsing/processing 已完成，以减少 UI thread rendering overhead：

- `Sources/MarkdownText/Models/MarkdownRenderable.swift:13-16`

这与 NewPi 的“渲染结果 replay”方向一致。

**④ 段落视图实例池**

`ParagraphViewCache` 最多缓存 50 个段落视图，只复用不在 window/superview 中的实例：

- `Sources/MarkdownText/UI/Paragraph/ParagraphViewCache.swift:8-38`

这对 NewPi 的启发不是直接池化 WKWebView，而是池化更轻的元素：

- tool status row
- diff header
- terminal-like output
- future native paragraph renderer

WKWebView 成本高，池化策略必须配合进程池、页面保活和内容 key，否则容易换来更差的状态污染。

**⑤ 段落高度缓存**

`ParagraphUIView` 有 `cachedSize`，宽度变化时失效：

- `Sources/MarkdownText/UI/Paragraph/UIKit/ParagraphUIView.swift:78-100`

NewPi 已有类似思想，但应继续把高度缓存细化到 block，而不是只到 message。

**⑥ 流式动画**

它有两种层次的动画：

- SwiftUI `TextRenderer` glyph fade：`Sources/MarkdownText/TextTransition/FadeInTextTransition.swift`
- UIKit/AppKit text view 内部按 range 淡入：`Sources/MarkdownText/UI/Paragraph/*/Paragraph*View.swift`

NewPi 目前的问题不是“没有动画”，而是布局和滚动抢写；动画应放在稳定块之后的 tail，避免整段重排。

#### 不建议照搬

- 每次 snapshot 全量 re-parse，长输出成本高。
- `MarkdownRenderable` 内含 `NSMutableAttributedString`，源码注释明示非线程安全。
- 默认 path 不启用 speculative rewrite。

---

### 2.2 GetStream/stream-chat-swift-ai

**本地路径**：`research-repos/stream-chat-swift-ai/`

#### 核心架构

`StreamingMessageView` 的输入是：

```swift
content: String
isGenerating: Bool
```

它不是 delta API，而是完整 snapshot API；内部自行计算新增文本：

- `Sources/StreamChatAI/StreamingMessageView.swift:10-32`

streaming 时：

1. 保存 `displayedText`
2. 保存 `characterQueue`
3. `getNewChunk(oldText:newText:)` 找新增后缀
4. append 到 character queue
5. Timer 每 5ms 弹出一个字符

见：

- `Sources/StreamChatAI/StreamingMessageView.swift:74-105`
- `Sources/StreamChatAI/StreamingMessageView.swift:108-129`

#### 对 NewPi 有价值的点

**① 组件 API 很清晰**

`content + isGenerating + letterInterval` 让调用方不必理解 streaming 细节。NewPi 的 UI 层也可以暴露：

```swift
StreamingDocumentView(
    blocks: renderBlocks,
    streamingBlockID: tailBlockID,
    phase: .streaming
)
```

**② 代码块按语言路由**

`markdownBlockStyle(\.codeBlock)` 中，如果语言命中 chart 语言表，会尝试解析 chart spec 并渲染 `USpecChartView`；解析失败则回退普通代码块：

- 语言表（**[核验修正]** 共 7 项，初版漏写末项 `vegalite`）：`Sources/StreamChatAI/StreamingMessageView.swift:22`

  ```swift
  ["json", "chart", "chartjs", "echarts", "highcharts", "vega-lite", "vegalite"]
  ```

- 路由实现：`Sources/StreamChatAI/StreamingMessageView.swift:34-55`

NewPi 可以借鉴为：

```text
code → source code block
json/chart → chart renderer
diff → diff card
mermaid → diagram renderer
bash output → terminal output card
```

**③ 代码块 chrome 完整**

语言 label + copy + horizontal scroll + Splash highlight：

- `Sources/StreamChatAI/StreamingMessageView.swift:131-175`

#### 不建议照搬

`Markdown(displayedText)` 会随着每个字符更新而重建整份 Markdown view。短内容可接受，NewPi 的长 agent 输出会放大布局成本。它的字符队列是 UI 动画层，不是布局增量层。

---

### 2.3 tomdai/markdown-webview

**本地路径**：`research-repos/markdown-webview/`

这是与 NewPi 同路线的最小 WKWebView renderer。

#### 核心架构

```text
WKWebView
  → local HTML template loaded once
  → markdown-it + highlight.js + KaTeX
  → base64 content update
  → markdownIt.render
  → innerHTML replace
  → ResizeObserver reports height
```

关键实现：

- Coordinator 持有同一个 `CustomWebView`，`makeNSView/updateNSView` 不重建：`Sources/MarkdownWebView/MarkdownWebView.swift:32-48`
- HTML template 和 JS/CSS 只在初始化时加载：`Sources/MarkdownWebView/MarkdownWebView.swift:98-116`
- 首次 `didFinish` 后写入内容：`Sources/MarkdownWebView/MarkdownWebView.swift:119-122`
- 后续更新通过 `callAsyncJavaScript` 调 `window.updateWithMarkdownContentBase64Encoded`：`Sources/MarkdownWebView/MarkdownWebView.swift:192-196`
- JS 端 `markdownIt.render` 后全量替换 `innerHTML`：`Sources/MarkdownWebView/Resources/template:95-102`

#### 高度同步

JS 端：

```js
new ResizeObserver((entries) => {
  window.webkit.messageHandlers.sizeChangeHandler.postMessage(
    entries[0].borderBoxSize[0].blockSize
  )
})
```

见 `Sources/MarkdownWebView/Resources/template:129-130`。

Swift 端收到后更新 `contentHeight` 并 `invalidateIntrinsicContentSize()`：

- `Sources/MarkdownWebView/MarkdownWebView.swift:146-153`
- `Sources/MarkdownWebView/MarkdownWebView.swift:170-175`

这比 OmniChat 的固定 `0/100/300ms` 三次测量更稳，NewPi 已采用类似 ResizeObserver/JS bridge 思路。

#### 滚动与键盘转发

- iOS：关闭 `scrollView.isScrollEnabled`
- macOS：`scrollWheel` 同时传给 `super` 和 `nextResponder`
- macOS：keyboard event 转发给 responder chain

见：

- `Sources/MarkdownWebView/MarkdownWebView.swift:76-82`
- `Sources/MarkdownWebView/MarkdownWebView.swift:177-224`

#### 代码复制

JS 每次渲染后给所有 `pre` 添加 copy button，通过 `copyToPasteboard` message 回 Swift：

- `Sources/MarkdownWebView/Resources/template:104-125`
- `Sources/MarkdownWebView/MarkdownWebView.swift:161-163`

#### 局限

- 每次全量 `innerHTML`
- 无 block identity
- 无稳定前缀 / tail 后缀
- 无流式 Markdown normalization
- template 依赖 CDN KaTeX / Font Awesome，离线和隐私风险高

NewPi 不应回退到这个形态，但可以把它当作 WKWebView 生命周期和 JS bridge 的最小参考。

---

### 2.4 kochj23/MLXCode

**本地路径**：`research-repos/MLXCode/`

#### 消息列表

`ChatView.messagesArea`：

- `ScrollViewReader + ScrollView + LazyVStack`
- `ForEach(conversation.messages)` 用 message id
- message count 变化时滚动到最后一条

见 `MLX Code/Views/ChatView.swift:379-441`。

这是一个普通 SwiftUI baseline，没有用户滚动 guard、高度表或 rail。

#### 消息内容路由

`MessageRowView.messageContent` 按消息类型路由：

```text
assistant 空 content → ThinkingIndicator
collapsible tool result → CollapsibleToolResultView
raw tool call → DisclosureGroup + MarkdownTextView
普通消息 → MarkdownTextView
```

见 `MLX Code/Views/MessageRowView.swift:88-125`。

这正符合 NewPi 需要的“语义消息 vs 过程事件”分层。

#### 自定义 Markdown block renderer

`MarkdownTextView` 自己 parse：

- code block
- heading
- list
- paragraph
- separator

然后：

```swift
ForEach(Array(blocks.enumerated()), id: \.offset)
```

见 `MLX Code/Views/MarkdownTextView.swift:42-78`。

问题：offset 不是稳定 identity。前缀插入或 block 合并会导致后续 row 被视为同一个 ID 但内容变化。NewPi 不应采用 offset 作为核心 ID。

#### EnhancedMessageView 的流式模拟

`EnhancedMessageView`：

- `displayedText` 从空增长
- Timer 10ms 逐字 append
- 每次重新 `parseMarkdownBlocks(displayedText)`
- `ForEach(..., id: \.offset)`

见 `MLX Code/Views/EnhancedMessageView.swift:70-136`。

这个实现演示了 block 化思路，但性能和 identity 都不成熟。

#### 代码块

`CodeBlockView`：

- header：语言 + copy
- horizontal/vertical ScrollView
- regex 做语法高亮
- `.textSelection(.enabled)`

见 `MLX Code/Views/CodeBlockView.swift:19-98`。

#### 工具结果卡片

`CollapsibleToolResultView`：

- status 来自 message metadata
- 三态：`success / running / error`
- running 显示 ProgressView
- 可折叠，展开后用 MarkdownTextView 渲染详情
- glass background + status tint border

见 `MLX Code/Views/CollapsibleToolResultView.swift:25-158`。

NewPi 可以直接借鉴视觉与状态模型，但把展开状态放进外部 coordinator，并只 invalidate 对应 row/block 高度。

---

### 2.5 sachaservan/SwiftChat

**本地路径**：`research-repos/SwiftChat/`

这是 NewPi 的关键参考之一。

#### StreamingMarkdownChunker

核心状态：

```swift
private var completedChunks: [ContentChunk]
private var workingBuffer: String
private var isInCodeBlock: Bool
private var isInTable: Bool
```

见 `SwiftChat/Services/StreamingMarkdownChunker.swift:35-42`。

`getAllChunks()` 返回：

```text
completedChunks
++ working_current / working_table（isComplete = false）
```

见 `SwiftChat/Services/StreamingMarkdownChunker.swift:44-59`。

完成规则：

- code block：遇到闭合 fence
- table：空行或后续行不再含 `|`
- paragraph：`\n\n`

见：

- `SwiftChat/Services/StreamingMarkdownChunker.swift:62-139`
- finalize path：`142-192`

#### Chunk identity

completed chunk id 由类型 + 内容 hash + 时间戳组成：

- paragraph：`SwiftChat/Services/StreamingMarkdownChunker.swift:124-135`
- code：`142-149`
- table：`156-165`

working chunk 使用固定 id：

- `working_current`
- `working_table`

优点：

- stable prefix 冻结
- tail 有稳定保留位

缺点：

- completed id 混入时间戳，重放/重算时不可复现
- hash 随机种子不稳定，不适合持久缓存 key

NewPi 应改成：

```text
identity = messageID + ordinal + kind + frozenContentDigest
cache key = contentDigest + width + theme + rendererVersion
```

identity 保持稳定，cache key 负责失效。

#### Chunk 渲染优化

`ChunkedContentView`：

- `ForEach(chunks)` 用 chunk id
- `ChunkView: Equatable`
- completed chunk 只比较 id/dark mode，不比较全文
- incomplete chunk 才比较 content/isStreaming

见 `SwiftChat/Views/MessageView.swift:1065-1112`。

这就是 NewPi 需要的 diff 边界：**stable block 不因 tail 增长而重新参与 equality 比较**。

#### UITableView-backed 消息列表

`MessageTableView`：

- `UITableView` + `UIHostingConfiguration`
- automatic row height
- estimated height fallback 100

见 `SwiftChat/Views/MessageTableView.swift:28-48` 和 `303-347`。

流式更新时不 reload 整表，而是更新最后一个 message 的 wrapper：

```swift
} else if isLoading && !messages.isEmpty {
    if let lastMessage = messages.last,
       let wrapper = messageWrappers[lastMessage.id] {
        wrapper.update(...)
    }
}
```

见 `SwiftChat/Views/MessageTableView.swift:118-158`。

#### 两级高度缓存

```swift
heightCache: [IndexPath: CGFloat]
messageHeightCache: [String: CGFloat]
```

- `estimatedHeightForRowAt` 先查 IndexPath cache
- 再查 message id cache，跨 reloadData 存活
- `willDisplay` 时写回两级 cache

见 `SwiftChat/Views/MessageTableView.swift:349-370`。

NewPi 的高度表已经是更完整的模型，但可以借鉴“布局位置 cache”和“语义对象 cache”分层。

#### 流式缓冲区

为了避免 row 高度频繁增长导致滚动跳动，它给正在流式的最后一条消息预分配一块缓冲高度：

- `bufferMultiplier`
- `actualContentHeight`
- `extendBufferIfNeeded`
- `resetBuffer`

见 `SwiftChat/Views/MessageTableView.swift:542-624` 和 `636-699`。

并通过负 bottom content inset 抵消未使用缓冲：

```swift
let streamingInset = -max(0, unusedBuffer)
```

见 `SwiftChat/Views/MessageTableView.swift:409-443`。

这是有效但激进的 UIKit 技巧。NewPi 目前用高度表 + 预热更干净；不建议直接照搬负 inset，因为会复杂化 rail 的 y 坐标和滚动条长度。

#### 用户滚动状态

`scrollViewWillBeginDragging`：

- 设置 `userHasScrolled`
- 取消 pending bottom/user-message scroll

见 `SwiftChat/Views/MessageTableView.swift:455-480`。

`checkIfAtBottom()` 用 150pt slack 判断是否在底部：

- `SwiftChat/Views/MessageTableView.swift:514-537`

NewPi 的 coordinator 也应有类似显式状态迁移，而不是多个 onChange 各自判断。

---

### 2.6 osaurus-ai/osaurus

**本地路径**：`research-repos/osaurus/`

这是对 NewPi 价值最高的仓库。

#### 总体结构

```text
SwiftUI outer view
  → MessageTableRepresentable (NSViewRepresentable)
  → NSScrollView + NSTableView
  → NSDiffableDataSource<MessageSection, String(blockID)>
  → NativeMessageCellView
  → NativeMarkdownView / NativeToolCallGroupView / NativeFileDiffView / ...
```

源码注释明确列出设计：

- block ID diffable data source
- no-change early return
- IDs 不变时 in-place reconfigure
- full snapshot + scroll anchoring
- streaming height debounce

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:1-17`。

注意：文件头部注释提到 automatic row heights，但实际 `makeTableView()` 设置 `usesAutomaticRowHeights = false`，改用 height delegate：

- `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:353-369`

以实际代码为准。

#### 三条更新路径

`applyBlocksImpl`：

1. no-change early return
2. width-only / in-place reconfigure
3. diffable full snapshot

关键判断：

- width/theme 变化时清空 height cache
- block id 和 content lookup 判断是否变化
- streaming block 单独处理高度

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:748-923`。

Path 2 只 reconfigure changed cells：

- stable cell 直接 `configureCell`
- streaming row 走 `scheduleStreamingHeightUpdate`
- 非 streaming row 立即 `noteHeightOfRows`
- 如果原本 pinned bottom，才 coalesce scroll bottom

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:953-993`。

Path 3：

- snapshot apply 前保存 scroll anchor
- snapshot apply 后 reconfigure stable changed ids
- 处理 pinned / restore
- streaming 结束后做一次 final height fix

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:995-1081`。

这几乎就是 NewPi 需要的状态机蓝本。

#### 高度治理

关键状态：

```swift
heightCache: [String: CGFloat]
lastNotedHeight: [String: CGFloat]
toolGroupViewCache: [String: NativeToolCallGroupView]
```

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:473-535`。

高度只在 delta 后通知 AppKit，并在动画组中调用 `noteHeightOfRows`：

- `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:698-719`

展开/折叠工具组时：

- 从 height cache 移除该 block
- reconfigure 单个 cell
- 50ms / 350ms 两次补测高度

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:654-681`。

这对 NewPi rail 和折叠卡片的启发是：**局部 UI 状态变化不要触发全列表布局，只失效一个 block 的高度并安排有界校正**。

#### ScrollAnchorManager

它把锚点定义为：

```text
topmost visible row + offset from row top
```

见 `Packages/OsaurusCore/Views/Chat/ScrollAnchorManager.swift:1-15`。

保存/恢复：

- snapshot 前保存 row + offset
- snapshot 后用新的 row rect 重算 y
- 如果目标差值 <= 1pt 就跳过，避免 SwiftUI update → scroll → update 的反馈环

见 `Packages/OsaurusCore/Views/Chat/ScrollAnchorManager.swift:82-118`。

pin-to-bottom：

- bottom threshold 50pt —— **[核验修正]** 该常量在 `ScrollAnchorManager.swift:30`（`var bottomThreshold: CGFloat = 50`），
  初版误归到下面的 `120-162` 行段

streaming 高频更新：

- 目标已在 1pt 内则跳过
- coalesce 到下一个 runloop

见 `Packages/OsaurusCore/Views/Chat/ScrollAnchorManager.swift:120-162`（1pt 跳过在 `:134`）。

post-snapshot 规则：

```text
streaming 且新 turn 出现 → 滚到 turn header
原本 pinned bottom → bottom
否则 → restore anchor
```

并且只在 streaming 时自动 homing 到 header，流结束后不会因清理空 turn 而 yank 视口：

见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:1084-1125`。

NewPi 可直接吸收这个优先级表。

#### NativeMarkdownView

定位：

```text
纯 AppKit markdown renderer
普通文本 → SelectableNSTextView
mixed content → text/code/image/math segment views
```

源码头部说明：

- `Packages/OsaurusCore/Views/Chat/NativeMarkdownView.swift:1-14`

configure 有 no-op guard：

- text / width / theme / streaming state 均未变化则直接 return

见 `Packages/OsaurusCore/Views/Chat/NativeMarkdownView.swift:522-543`。

混合内容按 segment id 复用 view：

- text segment 复用 `NativeMarkdownView`
- code segment 复用 `NativeCodeBlockView`
- trailing code 在 streaming 时跳过高频 highlight

见 `Packages/OsaurusCore/Views/Chat/NativeMarkdownView.swift:1000-1078`。

增量文本更新：

`SelectableTextView.updateTextStorageIncrementally`：

1. 找 first differing block
2. 用 cached block lengths 计算 prefix length
3. 删除 common prefix 之后的 tail
4. 只 render/append changed/new blocks
5. 返回 damage start，限制脏区

见 `Packages/OsaurusCore/Views/Chat/SelectableTextView.swift:223-301`。

这是“stable prefix 不重算”的源码级范本。

#### StreamingMarkdownBalancer

它只处理尾部，不动已提交段落：

- open code fence 时保留原样
- 只处理最后一个非 fenced segment 的最后 paragraph

见 `Packages/OsaurusCore/Views/Chat/StreamingMarkdownBalancer.swift:9-46`。

具体策略：

- 裸 list marker 先隐藏
- 新打开但还没有内容的 `*` / `**` / backtick 先删掉
- odd backtick 补虚拟闭合
- odd `**` 补虚拟闭合

见 `Packages/OsaurusCore/Views/Chat/StreamingMarkdownBalancer.swift:58-94` 和 `97-191`。

这比“全文档 speculative rewrite”更贴近 NewPi：已冻结块不动，只规范化 tail。

#### 工具组视图

`NativeToolCallGroupView` 是纯 AppKit 视图，配合 coordinator cache 复用：

- `Packages/OsaurusCore/Views/Chat/NativeToolCallGroupView.swift`
- cache 注入见 `Packages/OsaurusCore/Views/Chat/MessageTableRepresentable.swift:300-320`

特点：

- NSStackView 布局
- CALayer 做背景/动画
- 展开状态外部管理
- 测量高度回传 coordinator
- streaming terminal / subagent feed 有专门生命周期

NewPi 不必马上重写全部 UI，但可以把 tool timeline / status card / diff card 做成轻量 NSView 或 SwiftUI + `EquatableView` 的局部组件，避免每 delta 重建。

---

### 2.7 macOS26/Agent

**本地路径**：`research-repos/Agent/`

#### ActivityLog 形态

`ActivityLogView` 是单个 `NSTextView` backed 的活动日志，不是消息列表：

- `NSViewRepresentable`
- 手工 `NSTextContainer + NSLayoutManager + NSTextStorage`
- rich text selectable
- 渲染、滚动、搜索、缓存全部在 Coordinator 扩展中拆分

见 `Agent/Views/ActivityLog/ActivityLogView.swift:35-95`。

#### 增量更新

`performRender()` 先判断：

- text length
- search
- tab switch
- appearance

无变化直接 return。

见 `Agent/Views/ActivityLog/Update.swift:8-67`。

append 场景：

1. 比较 new length 与 last length
2. 检查前 64 字符确认 prefix 未被 trim/edit 破坏
3. 只取出新增 suffix
4. 对非 table 内容 append 已渲染 NSAttributedString
5. mutation 前保存 scroll y，若用户不在底部则恢复

见 `Agent/Views/ActivityLog/Update.swift:82-139`。

如果新增内容涉及 table，则全量 rebuild，因为 table 布局无法安全 append：

- `Agent/Views/ActivityLog/Update.swift:100-116`

这个“append 快路径 + table 全量重建例外”对 NewPi 的工具输出/日志很有价值。

#### Tab 缓存

每个 tab 缓存：

```text
NSTextStorage
text length
text hash
scrollY
```

命中时直接 `replaceTextStorage`，恢复 scroll y，避免重排：

- `Agent/Views/ActivityLog/Cache.swift:4-40`

NewPi 已有面板保活和高度缓存，可以补充类似的“可复用渲染结果 + 恢复位置”模型，但要注意 WKWebView 数量和内存成本。

#### Markdown 渲染

`renderMarkdown` 生成 `NSAttributedString`：

- read_file 输出识别为代码
- 看起来像 source output 的文本走代码高亮
- fenced code 先拆出来
- 普通 text 走 inline markdown
- code block 内嵌 copy button attachment
- table 用 `NSTextTable`

见 `Agent/Views/ActivityLog/MarkdownBlock.swift:8-125` 和后续 table 实现。

#### 滚动

`throttledScrollToEnd`：

- 只在 user at bottom 时执行
- 100ms throttle
- streaming 用 snap，不用动画，避免与布局竞争

见 `Agent/Views/ActivityLog/Scroll.swift:57-77`。

#### 适用边界

这个项目证明 NSTextView 适合 tool/activity log，但不适合 NewPi 的完整富聊天文档。NewPi 可以把它作为“过程事件面板”的实现参考。

---

### 2.8 CherryHQ/hanlin-ai

**本地路径**：`research-repos/hanlin-ai/`

#### 消息列表与历史窗口

加载历史时：

1. 全量取 SwiftData messages
2. 按时间排序
3. 默认只显示最后 20 条
4. 如有 matched message，则按目标距离底部向上取整到 10 的倍数
5. `refreshable` 继续加载更多

见 `AI_HLY/ChatView.swift:120-200`。

列表：

- `ScrollViewReader + ScrollView + LazyVStack`
- `ForEach(chatTemps)` 用 message id
- `defaultScrollAnchor(ifScroll ? .top : .bottom)`
- matched message 出现后延迟 0.5s + 0.5s 再 center

见 `AI_HLY/ChatView.swift:629-690`。

这是一个“数据窗口”方案，但没有高度表，也没有精确 offset，依赖延时。NewPi 的 rail 高度表算术定位明显更可靠。

#### Composer 动态底部留白

`dynamicBottomPadding()` 根据附件、图片、文档、prompt 等 UI 状态增加底部 padding，并用动画跟随：

- `AI_HLY/ChatView.swift:193-214`
- `AI_HLY/ChatView.swift:652-658`

NewPi 已经历过 composer 高度变化抢滚动的问题；hanlin 的做法视觉简单，但不能保证恢复锚点期间不被钉底覆盖。

#### Markdown / LaTeX

assistant 内容：

```swift
if mathMode {
    LaTeX(text)
} else {
    Markdown(text)
}
```

见 `AI_HLY/Views/Components/ChatViewComponents.swift:1543-1556`。

这是 message 级全量渲染，没有 block 增量。

#### 工具 / 推理 UI

工具内容是可折叠区：

- title + tool name
- `isToolContentExpanded`
- 展开后纯 Text 展示

见 `AI_HLY/Views/Components/ChatViewComponents.swift:1851-1874`。

推理过程：

- 可折叠
- streaming 折叠时只显示最后 3 行
- 三行分别用不同字号/透明度/blur，形成“越旧越淡”的层次

见 `AI_HLY/Views/Components/ChatViewComponents.swift:1797-1849`。

operational state 也显示最后 3 行，并用 blur/opacity 区分新旧：

- `AI_HLY/Views/Components/ChatViewComponents.swift:493-543`

这个“tail 3-line status preview”非常适合 NewPi 的工具运行中状态：折叠态不必展示完整日志，只保留最近事件。

#### 代码运行结果

`CodeBlockRow` 是“程序运行结果”卡片：

- header：程序运行结果 + 查看源码
- output 用 monospaced Text
- error 用红色
- sheet 展示完整源码

见 `AI_HLY/Views/Components/ChatViewComponents.swift:2434-2482`。

---

### 2.9 bowenyu066/OmniChat

**本地路径**：`research-repos/OmniChat/`

这是与 NewPi 同为 macOS + WKWebView 的直接对照。

#### 流式状态与持久化解耦

ChatView 使用独立 `streamingContent` buffer：

- streaming 期间频繁更新 `@State streamingContent`
- SwiftData message 只在流结束时写一次

见 `OmniChat/Views/Chat/ChatView.swift:30-41` 和 `OmniChat/Views/Chat/ChatView.swift:1163-1192`。

这避免了每个 delta 触发 SwiftData observation，是 NewPi 应继续保持的边界。

#### 自适应 UI 更新频率

根据已流式字符数降低 UI 频率：

```text
<3k       50ms
3k–8k     70ms
8k–16k   100ms
>16k     140ms
```

见 `OmniChat/Views/Chat/ChatView.swift:52-64`。

实现上：

- `contentParts` 保存原始 chunk，避免反复拼接大字符串
- `pendingUIChunk` 聚合 delta
- 达到 interval 才把 pending delta append 到 UI state

见 `OmniChat/Views/Chat/ChatView.swift:1095-1161`。

这个策略可与 NewPi 的块级更新叠加：**stable block 不更新，tail block 再按长度/复杂度自适应节流**。

#### Streaming 时降级为 Text，完成后才用 WKWebView

`MessageView`：

```swift
if isStreaming {
    Text(displayedText)
} else {
    MarkdownView(content: displayContent)
}
```

见 `OmniChat/Views/Chat/MessageView.swift:159-176`。

优点是明显降低 CPU；缺点是流式过程没有 Markdown 排版，完成时会经历一次视觉切换。NewPi 已经选择更难的“流式也 Markdown”，应继续优化而不是退回 Text。

#### WKWebView renderer

`NonScrollingWebView`：

- 缓存 parent NSScrollView
- scroll wheel 转发给外部 scroll view

见 `OmniChat/Views/Components/MarkdownView.swift:4-37`。

`UnifiedMessageWebView`：

- 每条消息一个 WebView
- `heightUpdate` / `copyCode` message handler
- `updateNSView` 每次 `generateHTML()` 并 `loadHTMLString`

见 `OmniChat/Views/Components/MarkdownView.swift:40-110`。

高度：

- didFinish 后测 `document.body.scrollHeight`
- JS load 后 0/100/300ms 各测一次

见 `OmniChat/Views/Components/MarkdownView.swift:123-148` 和 `387-423`。

局限：

- 全量 HTML reload
- 无 block identity
- KaTeX 从 CDN 加载
- 高度靠定时补测而非 ResizeObserver
- 自己用 regex/parser 拼 Markdown HTML

NewPi 的本地模板 + 块级 JS 更新 + 高度预热明显更强。

#### 滚动

streaming 内容变化时 100ms throttle scroll bottom：

见 `OmniChat/Views/Chat/ChatView.swift:285-316`。

但没有看到“用户已滚离底部则停止跟随”的完整 guard；NewPi 需要显式 `followingStream` 条件。

---

### 2.10 alfianlosari/ChatGPTSwiftUI

**本地路径**：`research-repos/ChatGPTSwiftUI/`

#### 消息列表

标准 SwiftUI baseline：

- `ScrollViewReader + ScrollView + LazyVStack`
- `ForEach(vm.messages)`
- last responseText 变化时 `scrollToBottom`

见 `Shared/ContentView.swift:22-48` 和 `113-116`。

没有：

- 用户滚动检测
- 高度缓存
- 恢复锚点
- rail
- 长历史窗口化

因此它解释了为什么简单示例没有 NewPi 的痛点，但不能作为目标架构。

#### iOS streaming Markdown

iOS path 使用 actor 异步 parse：

- `ResponseParsingTask` 是 actor
- Apple `Markdown.Document` → `MarkdownAttributedStringParser`

见 `Shared/ResponseParsingTask.swift:8-20`。

ViewModel：

- 每 64 字符或遇到 code fence 时 parse 全量 snapshot
- 未 parse 的 suffix 追加到当前最后一个 block
- stream 结束后最终 parse

见 `Shared/ViewModel.swift:111-187`。

这是一个“全量 parse + tail append”的折中，但没有稳定 block ID。

#### 平台差异

`MessageRowView`：

- iOS code block 使用 `CodeBlockView`
- 非 iOS 直接 `Text(parsed.attributedString)`

见 `Shared/MessageRowView.swift:126-147`。

macOS 基本是 raw text baseline，不适合 NewPi。

#### CodeBlockView

- language label
- copy button
- horizontal ScrollView
- monospaced text

见 `Shared/CodeBlockView.swift:15-78`。

---

### 2.11 Panl/AICat

**本地路径**：`research-repos/AICat/`

#### 消息渲染策略

`AICatMessageView`：

- 空 content → typing dots
- content 包含 ``` 时 → MarkdownUI
- 否则 → 普通 Text bubble

见 `AICat/Views/MessageView.swift:71-115`。

这是一个明显性能取舍：为了避免 Markdown renderer 成本，只有包含代码块的消息才走 Markdown。代价是普通 Markdown formatting 在 Text 中不渲染。NewPi 不应牺牲正文格式，但可以借鉴“内容能力路由”。

#### MarkdownUI + Splash

代码高亮：

```swift
ChatCodeSyntaxHighlighter
  → highlightedCodeBlock
  → Text(AttributedString(content))
```

见 `AICat/Markdown/SyntaxHighlighter/SplashCodeSyntaxHighlighter.swift:4-21`。

主题中 code block：

- horizontal ScrollView
- language label
- copy button overlay
- rounded background

见 `AICat/Extension/Theme+Extension.swift:32-70`。

#### Streaming

Combine stream：

- `receive(on: RunLoop.main)`
- 每个 delta `responseMessage.content += content`
- `upsertMessage(responseMessage)`

见 `AICat/Pages/ConversationView.swift:245-294`。

`upsertMessage` 每次 find index、replace、sort messages：

见 `AICat/Pages/ConversationView.swift:105-115`。

这对流式长输出不友好；NewPi 不应每个 delta 更新持久 message 数组。

#### 滚动

消息列表：

- `ScrollViewReader + ScrollView + LazyVStack`
- bottom sentinel id `"Bottom"`
- messages 变化或输入 focus 时滚到底

见 `AICat/Pages/ConversationView.swift:741-810`。

没有用户滚动 guard / 高度表 / 精确恢复。

#### 产品层结构

它有较完整的：

- sidebar / conversation list
- prompt presets
- message actions
- settings
- share/export

NewPi 的重点不是复制产品层，而是保持自己的 coding agent transcript 结构。

---

### 2.12 preternatural-explore/mlx-swift-chat

**本地路径**：`research-repos/mlx-swift-chat/`

#### 实际形态

当前源码不是多轮 chat UI，而是 prompt/completion 工作台：

```text
Prompt GroupBox
Completion GroupBox
Right inspector: model/config
```

见 `mlx-swift-chat/ContentView.swift:100-136`。

completion 是一个 `Text(completionText ?? "")`，支持选择和复制：

- `mlx-swift-chat/ContentView.swift:219-227`

对 NewPi 的 Markdown/rail/滚动参考价值低。

#### 有价值的状态 UI

RunButton 根据 runner status 展示：

- no model selected
- loading model spinner
- generating progress
- ready/failed

见 `mlx-swift-chat/ContentView.swift:64-97`。

StatusView：

- `Preparing...` / `Generating...`
- progress
- ready 后显示 tokens/s
- failed 显示错误

见 `mlx-swift-chat/UI/StatusView.swift:8-63`。

ModelsView：

- model download progress
- downloaded state
- failed error popover

见 `mlx-swift-chat/UI/ModelsView.swift:126-229`。

这些适合 NewPi 的模型加载、本地推理、后台任务状态展示，但不是 chat renderer 参考。

---

### 2.13 gonzalezreal/swift-markdown-ui

**本地路径**：`research-repos/swift-markdown-ui/`

#### Markdown API

`Markdown` view 可以接收：

- Markdown string
- pre-parsed `MarkdownContent`
- DSL builder

文档明确说明 `MarkdownContent` 可以在 model layer 预 parse，避免 view layer 做 parse：

见 `Sources/MarkdownUI/Views/Markdown.swift:60-72` 和 `191-239`。

这对 NewPi 的启发是：渲染输入应该是已经解析/分段/冻结好的 `RenderDocument`，而不是让 SwiftUI body 每次从 raw string 开始。

#### Parser

它直接使用 cmark GFM extensions：

- autolink
- strikethrough
- tagfilter
- tasklist
- table

见 `Sources/MarkdownUI/Parser/MarkdownParser.swift:224-259`。

#### Block → View

`BlockNode: View` 将：

- paragraph → `ParagraphView`
- codeBlock → `CodeBlockView`
- heading → `HeadingView`
- table → `TableView`
- list → corresponding list view

见 `Sources/MarkdownUI/Views/Blocks/BlockNode+View.swift:3-29`。

`BlockSequence` 用：

```swift
ForEach(self.data, id: \.self)
```

其中 data 是 `Indexed<BlockNode>`，hash 由 `index + value` 组成：

- `Sources/MarkdownUI/Views/Blocks/BlockSequence.swift:14-34`
- `Sources/MarkdownUI/Utility/Indexed.swift:3-15`

对 append-only 输出，前缀 index/value 不变，有较好复用；一旦结构重排或前面 block 合并，identity 会变化。它是静态 Markdown renderer，不是 streaming stable-prefix 方案。

#### Code block 扩展点

`CodeBlockView` 从 environment 读取：

- `theme.codeBlock`
- `codeSyntaxHighlighter`

然后把 language/content/label 打包成 `CodeBlockConfiguration`：

见 `Sources/MarkdownUI/Views/Blocks/CodeBlockView.swift:3-29`。

AICat 正是用这个扩展点实现 Splash + copy button。NewPi 的 WKWebView 侧也可以定义同等能力的 Swift 配置对象，再序列化给 JS。

#### 维护状态

README 明确：

```text
MarkdownUI is in maintenance mode.
New development is happening in Textual.
```

见 `README.md:1-5`。

不建议把 NewPi 核心迁到 MarkdownUI；更适合作为 API/主题/代码块扩展设计参考。

---

## 3. 横向对比

### 3.1 流式 Markdown

| 项目 | 输入模型 | 更新粒度 | 不完整 Markdown 处理 | 高频性能策略 |
|---|---|---|---|---|
| SwiftStreamingMarkdown | complete snapshot | block renderable | parser 有能力，默认流式 path 未启用 | 预处理成 renderable；段落视图池 |
| GetStream | complete snapshot | 字符队列 + MarkdownUI 全渲染 | 无 | 5ms character timer |
| markdown-webview | complete markdown | document innerHTML | 无 | WebView 不重建，但 DOM 全替换 |
| MLXCode | full message / displayedText | 自定义 block，offset id | 无 | 10ms 逐字 |
| SwiftChat | token → chunker | completed chunks + working buffer | table/code/paragraph 边界识别 | frozen chunk Equatable；UITableView 只更新最后 row |
| osaurus | content blocks | block diff + segment diff | tail Markdown balancer | NSTextStorage incremental append，bounded dirty rect |
| Agent | log text append | text storage append | table 时全量重建 | prefix intact check + append |
| OmniChat | delta → state buffer | message state | 无 | adaptive interval；streaming 用 Text |
| ChatGPTSwiftUI | delta → full streamText | parser results，间隔 parse | code fence 触发 parse | actor parse，64 字符阈值 |
| AICat | delta append message | message 级 | 无 | 无代码时降级 Text |
| swift-markdown-ui | static string/content | block view | 无 | pre-parsed MarkdownContent |

**结论**：NewPi 应采用 SwiftChat/osaurus 的 stable prefix + tail 模型，而不是 GetStream/MLXCode 的字符动画模型。

### 3.2 消息列表与高度

| 项目 | 列表载体 | 高度管理 | 长历史策略 |
|---|---|---|---|
| NewPi 当前 | SwiftUI 手动窗口 + 高度表 | block/message 高度预热 | 可见区外占位 |
| SwiftChat | UITableView | IndexPath cache + message id cache | 无完整高度表 |
| osaurus | NSTableView diffable | block height cache + noteHeightOfRows debounce | cell recycle + view cache |
| Agent | 单个 NSTextView | TextKit layout | 50K log bound + tab storage cache |
| hanlin-ai | LazyVStack | SwiftUI 自动 | suffix 20，refresh load more |
| OmniChat | LazyVStack | WebView height state | SwiftUI lazy |
| ChatGPTSwiftUI | LazyVStack | SwiftUI 自动 | 无 |
| AICat | LazyVStack | SwiftUI 自动 | 无 |

**结论**：NewPi 的高度表方向正确；下一步是把高度 key 与失效规则做严格化，并把 block 高度也纳入表内。

### 3.3 滚动

| 项目 | 用户是否可脱离底部 | 恢复策略 | 高频滚动写入 |
|---|---|---|---|
| SwiftChat | 是，dragging 取消 pending | 用户消息钉顶模式 + inset | at-bottom 检查 + buffer |
| osaurus | 是，pinned state | row + offset anchor | coalesce + 1pt skip |
| Agent | 是 | append 前保存 y，append 后恢复 | 100ms throttle |
| OmniChat | 未见完整 guard | 无复杂恢复 | 100ms throttle bottom |
| ChatGPTSwiftUI | 否 | 无 | responseText 每变化 |
| AICat | 否 | 无 | message/focus 变化即 bottom |
| hanlin-ai | 部分 | matched id center | 延时 scroll |

**结论**：NewPi 的 scroll coordinator 应吸收 osaurus/Agent/SwiftChat 三者的规则，而不是 SwiftUI 示例的直接 scrollTo bottom。

### 3.4 工具过程 UI

| 项目 | 形态 | 值得借鉴 |
|---|---|---|
| MLXCode | collapsible tool result card | success/running/error 三态、默认折叠 |
| osaurus | native tool call group / activity group / diff / artifact | 展开状态外部管理、单 row 高度失效、级联动画 |
| Agent | NSTextView activity log | 过程日志 append、tab cache、搜索 |
| hanlin-ai | tool/reasoning collapsible | 折叠态显示最近 3 行，旧行 blur/fade |
| SwiftChat | web search / URL fetch card | 独立过程卡片，不混入正文 |

---

## 4. 对 NewPi 的落地建议

### 4.0 现状台账 **[核验修正]**

> **🗑 2026-08-30 归档声明**：下表中标注「✅ 已完成」的遗留路径能力（预热 / 窗口化 /
> 高度表 / replay / 高度桥 / rail pending jump）已随单文档 transcript 迁移**整体删除**
> （commit `3e890a4`，净减 2834 行）；「⬜ 待办」中的显式滚动状态机以更彻底的形式落地
> （文档内单 writer，见 `transcript-document.js` 的 Scroll 模块），engineFingerprint /
> block 级高度表随高度表机制本身消亡而失去对象。本表仅作历史决策记录留存；
> 现行实现见 CLAUDE.md 与 [`ui-architecture-decision.md`](./ui-architecture-decision.md) §4.3。
>
> 初版本节的建议是在**未核对 NewPi 实际代码**的前提下写的，其中三项已经落地。
> 直接按 §5「实现顺序」执行会重做 `renderStreaming()` 与 `repairTailSource()`。
> 下表为交叉验证后的净结论，逐条依据见
> [核验报告 §3 / §4](./ui-architecture-research-verification.md)。

| 建议项 | 状态 | 依据 |
|---|---|---|
| 块级增量渲染 + 冻结前缀对齐 | ✅ 已完成 | `markdown-renderer.js:405-462` |
| 流式尾部规范化（tail-only normalization） | ✅ 已完成，优于参考实现 | `markdown-renderer.js:237-297` |
| rail pending jump + 有界校正 | ✅ 已完成 | `NewPiChatView.swift:58-63,403-424` |
| 本地资源 / render-once replay / ResizeObserver 高度桥 | ✅ 已完成 | `markdown-renderer.js:91,102,147,175` |
| 高度预热 / 手动窗口化 + 高度表 | ✅ 已完成 | `NewPiMarkdownHeightPreheater.swift`、`NewPiChatView.swift:45-46,97` |
| **显式滚动状态机** | ⬜ 待办 · 价值最高 | 4 个写入点 + 6 个 onChange 驱动，无统一意图状态 |
| **engineFingerprint 接进高度查询** | ⬜ 待办 · 有实际隐患 | `height(for:)` 无引擎校验（`NewPiMarkdownWebRenderer.swift:60-78`） |
| **高度表下沉到 block 级** | ⬜ 待办 | 当前按整条 `item.body` 算 SHA256；JS 高度上报不带 blockID |
| 块的显式 `RenderBlockID` | ◻︎ 可选加固 | 现为下标 + source 比对的隐式 identity，分叉时有全量兜底 |

以下 P0–P3 保留完整设计推导（对未完成项仍然有效，对已完成项可作为回溯依据），
但**请先读上表再排期**。

### P0：建立稳定的 RenderBlock 模型

> **[核验状态]** ◻︎ 可选加固，非缺口。`renderStreaming()` 已用「数组下标 + source 逐字节比对」
> 做隐式对齐，并在冻结前缀分叉时退回全量重渲染。下面的显式 ID 方案是加固，不是从零补齐。

不要让 UI 直接消费原始 transcript 字符串。建议分成：

```swift
enum RenderBlockKind {
    case markdownTail
    case markdownFrozen(contentDigest: String)
    case code(language: String?)
    case toolTimeline(eventID: String)
    case diff(fileID: String)
    case artifact(id: String)
    case status(state: ToolState)
}

struct RenderBlock: Identifiable {
    let id: RenderBlockID
    let kind: RenderBlockKind
    let isFrozen: Bool
}
```

identity 建议：

```text
messageID
+ blockOrdinal
+ blockKind
+ frozenContentDigest (只对已完成 block)
```

不要：

- 只用数组 offset（MLXCode 问题）
- 只用 content hash（tail 每次变化）
- 只用 AST path（结构重排会变）
- completed id 混入时间戳（SwiftChat 不可重放）

规则：

```text
frozen block: identity 和内容都不变，不参与 tail equality
tail block: 固定保留位，例如 messageID + “tail”
complete 时: tail 冻结，生成最终 digest，下一帧从 tail 变成 frozen block
```

### P0：流式 Markdown 只更新 tail

> **[核验修正]** ✅ 本项已完成，保留于此仅作设计回溯。
> `renderStreaming()`（`markdown-renderer.js:405-462`）已实现下面整条管线；
> `repairTailSource()`（`:237-297`）已实现下面的尾部规范化，且在两点上比 osaurus 更保守：
> 先剥离已闭合的行内代码段再计数（避免把代码里的反引号当标记）、
> 要求标记最后一次出现后紧跟非空白才补闭合（`2 ** 3` 不误判为加粗）。
> osaurus 的注释自承其朴素 `**` 计数在这两种场景下会多补虚拟闭合符
> （`StreamingMarkdownBalancer.swift:87-89`）。**此项不需要再借鉴 osaurus。**

推荐管线：

```text
provider delta
  → append to tail buffer
  → normalize only tail
  → parse only tail
  → update only tail DOM block
  → report tail height delta
  → height table append/patch
```

尾部规范化可参考 osaurus：

- 未闭合 inline code / bold 补虚拟闭合
- 刚打开但无内容的 marker 先隐藏
- 裸 list marker 先隐藏
- open code fence 保留为 streaming code card
- 不修改任何 frozen block

SwiftStreamingMarkdown 的 partial emphasis/table rewriter 可以作为第二阶段增强，但必须显式启用并加 snapshot tests。

### P0：高度缓存 key

> **[核验修正]** ⬜ 待办，但**方案需要改**。初版建议引入手工维护的 `rendererVersion: Int`，
> 而 NewPi 已有更好的机制：`NewPiMarkdownWebDocument.engineFingerprint()`
> （`NewPiMarkdownWebRenderer.swift:313-333`）对整个 `MarkdownRenderer/` 目录的 js/css
> 做内容 SHA256，渲染器或样式任何变化都会改变指纹，**无需手工维护版本号**。
>
> 真正的缺陷是它只接进了产物查询、没有接进高度查询：
>
> | 查询 | 引擎校验 | 位置 |
> |---|---|---|
> | `renderedHTML(for:engine:)` | ✅ `entry.engine == engine` | `NewPiMarkdownWebRenderer.swift:101-110` |
> | `height(for:)` / `height(for:width:)` | ❌ 无 | `NewPiMarkdownWebRenderer.swift:60-78` |
>
> **后果**：改动渲染器 js/css 后，HTML 产物会正确失效重渲染，但**旧高度仍然命中**——
> 高度表、窗口占位、rail y 坐标会全部基于过期几何。
>
> 因此正确动作是**把已有的 `engineFingerprint` 接进高度查询路径**，而不是新造版本号。
> theme / fontScale 则确实完全不在 key 内（当前 key = 宽度桶 + 内容 SHA256），可一并纳入。

建议（`rendererVersion` / `markdownEngineVersion` 两项以现有 `engineFingerprint` 替代）：

```swift
struct MarkdownLayoutKey: Hashable {
    let contentDigest: String     // 已有：内容 SHA256
    let width: CGFloat            // 已有：宽度桶
    let engineFingerprint: String // 已有机制，待接入高度查询
    let themeID: String           // 缺失
    let fontScale: CGFloat        // 缺失
}

struct MarkdownLayoutValue {
    let messageHeight: CGFloat
    let blockHeights: [CGFloat]
    let layoutVersion: Int
}
```

失效规则：

- width 变化
- theme/font scale 变化
- renderer script / HTML / CSS version 变化
- markdown parser version 变化
- block 从 incomplete 变 complete
- session restore 后内容 digest 不匹配

可借鉴：

- SwiftChat：IndexPath cache + message id cache
- osaurus：width/theme change 全量失效，block 级局部失效
- NewPi：**[核验修正]** 初版写"已有 NSCache"不准。实际是嵌套字典 `buckets: [String: [String: Entry]]`
  + `lastAccess` 做 LRU，并**持久化**到 `~/.new-pi/agent/markdown-height-cache.json`
  （`NewPiMarkdownWebRenderer.swift:43-44,55-56`）。差异有实质意义：`NSCache` 在内存压力下自动驱逐
  且不跨启动存活，而当前实现跨启动持久——这正是冷恢复预热能生效的前提。

### P1：显式滚动状态机

> **[核验状态]** ⬜ 待办，**三项待办中价值最高**。
> `NewPiChatScrollHelper.swift` 仅 101 行，实质是 per-session 锚点持久化（`Entry: rowID/delta/offset`）
> 与两个 PreferenceKey，**不含滚动意图状态**。实际滚动写入分散在 `NewPiChatView.swift`：
>
> ```text
> 写入点：:216 (rail jump)  :371 (冷启动恢复)  :423 (rail 有界校正)  :452 (钉底)
> 驱动：  :283 transcript.map(\.id)   :286 geometry.size.width   :301 runtime.isStreaming
>         :312 transcript.last?.id    :316 transcript.last?.body  :320 composerHeight
> ```
>
> 代码注释本身已记录过这类竞争的症状：`:65`「自动钉底会在恢复 scrollTo 落地后把会话又拽回底部——
> 原位恢复失效的根因」、`:364`「冷启动时内容布局/门控/钉底都在并发进行，单次 scrollTo 可能被时序吞掉」。
> 下面的状态机与"同一时刻只有一个 writer"约束正是针对这一点。

建议：

```swift
enum ChatScrollIntent {
    case idle
    case userScrolling
    case pinnedToBottom
    case followingStream
    case restoringAnchor
    case jumpingToRailTarget
    case layoutSuppressed
}
```

规则：

1. 同一时刻只有一个 writer。
2. `userScrolling` 取消所有 pending bottom/rail 跟进。
3. `followingStream` 只有进入流前用户在底部才允许。
4. `restoringAnchor` / `layoutSuppressed` 期间 composer 高度变化不得触发 pin-to-bottom。
5. snapshot 前保存 anchor，snapshot 后恢复。
6. rail jump 必须等目标 block 高度 ready，再做有界校正。
7. 程序滚动目标差值小于 1pt 时跳过，避免反馈环。
8. 高频 bottom follow coalesce 到同一 runloop。

这综合了 osaurus、SwiftChat、Agent 的最佳实践。

### P1：rail 继续基于高度表

NewPi 已经从 geometry/PreferenceKey 转向高度表，这是正确的。应继续保证：

```text
rail y = heightTable.prefixHeight(before: target)
```

不要回退到：

- row minY PreferenceKey
- ScrollViewReader id anchor
- 延时 scrollTo

需要补强 **[核验修正：后两项已完成]**：

- ⬜ block 级高度表 —— 待办，当前按整条 `item.body` 算 SHA256
  （`NewPiMarkdownHeightPreheater.swift:49-52`、`NewPiMarkdownWebRenderer.swift:158`），
  JS 侧也只上报 root 整体高度、不带 blockID
- ⬜ preheat 完成度状态 —— 待办
- ✅ rail jump 后的有限次数高度校正 —— 已完成：`applyPendingRailCorrection()`
  （`NewPiChatView.swift:403-424`），且用户接管滚动时主动放弃不打断
- ✅ 目标高度未 ready 时的 pending jump 状态 —— 已完成：`RailTarget` + `pendingRailTarget`
  （`NewPiChatView.swift:58-63`）

### P1：过程事件与语义消息分层

```text
semantic transcript:
    user message
    assistant final markdown
    assistant summary

process timeline:
    tool call
    approval
    bash output
    diff
    file read
    error
    artifact
```

视觉建议：

- 正文：WKWebView Markdown document
- 工具状态：原生 status chip / card
- 运行中日志：默认折叠 + 最近 3 行 preview
- diff：专用 diff card
- artifact：artifact card
- 错误：独立 error card

hanlin 的 3-line faded tail、MLXCode 的三态工具卡、osaurus 的 native tool group 都可以直接组合。

### P2：WKWebView 继续作为 document renderer

必须保持：

- 本地 HTML/JS/CSS，不依赖 CDN
- 页面模板加载一次
- block 级 DOM patch
- ResizeObserver / JS height bridge
- scroll wheel forwarding
- watchdog / white-screen gate
- process pool / panel keep-alive
- rendererVersion 参与高度缓存

避免 OmniChat/markdown-webview 的问题：

- 不每次 `loadHTMLString`
- 不全量 innerHTML
- 不用远端 KaTeX/highlight
- 不靠固定延时猜测高度

### P2：高频 UI 下移到轻量原生视图

优先级：

1. tool status row
2. tool group header
3. terminal-like output tail
4. diff header
5. artifact card

这些不需要 WKWebView。可以用：

- AppKit NSView + CALayer（osaurus 路线）
- SwiftUI + `Equatable` + 固定尺寸 header

正文 Markdown 仍留在 WKWebView。

### P2：会话切换与重放

NewPi 已有面板保活和高度缓存，可继续借鉴 Agent：

```text
sessionID
  → rendered result handle
  → block heights
  → scroll anchor
```

切换时：

1. 保存当前 session anchor
2. 恢复目标 session 高度表
3. 挂载 replay document
4. 等首屏高度 ready
5. 恢复 anchor
6. 才允许 bottom follow

不要让 session switch、composer layout、stream follow 三者同时写 scroll。

### P3：动画策略

只给 tail 做动画：

- 新 block 插入：opacity/move
- tail text：cursor / fade
- tool status：状态色过渡
- diff：行级 reveal

不做：

- 整个 message 每字符 transition
- stable block 高度变化动画
- scroll 与 layout 同帧竞争动画

---

## 5. 建议的实现顺序

> **[核验修正] 本节顺序已作废，按下表执行。**
> 初版第一、二步描述的能力已在 JS 侧落地（见 §4.0 台账），照原顺序执行会重做既有代码。
> 修正后的顺序：
>
> | 顺序 | 事项 | 对应初版 |
> |---|---|---|
> | 1 | 滚动写入收敛为显式状态机（4 写入点 + 6 驱动） | 原第四步 |
> | 2 | `engineFingerprint` 接进 `height(for:)`；theme/fontScale 纳入 key | 原第三步（部分） |
> | 3 | 高度上报带 blockID，高度表下沉到 block 级 | 原第三步 |
> | 4 | 工具过程卡片化 | 原第五步（不变） |
> | — | ~~抽出 MarkdownBlockBuilder~~ | 原第一步：JS 侧 `splitBlocks` 已承担 |
> | — | ~~JS API 改为 block patch~~ | 原第二步：`renderStreaming` 已是 block patch |
>
> 原第一步若要做，价值在于**把切块逻辑从 JS 挪到 Swift 以获得单元测试覆盖**
> （当前 `splitBlocks` / `repairTailSource` 无 Swift 侧测试），而不是"补齐缺失能力"。

### 第一步（已由 JS 侧承担）：抽出纯 Swift MarkdownBlockBuilder

目标：

- input：raw markdown snapshot / delta buffer
- output：`[RenderBlock] + tail`
- 不依赖 SwiftUI / WKWebView
- 可单测

验收：

```text
append “**bold”  → frozen prefix 不变，tail normalized
append code fence → tail 变 streaming code
close code fence → 生成 frozen code block
finish stream → 所有 block frozen，digest 稳定
replay same text → block identity/digest 一致
```

### 第二步（已完成）：JS API 从 document render 改为 block patch

> **[核验修正]** ✅ `window.renderMarkdown(source, {streaming: true})` → `renderStreaming()`
> 已经是 block patch：冻结前缀不重建 DOM、只替换尾块、分叉时全量兜底、源变短时裁尾节点。
> 下面的 `upsertBlock`/`freezeBlock` 接口形态是另一种设计（Swift 侧持块），
> 当前实现选择"传完整 source、JS 侧切块比对"，二者等效；**唯一真实差距是 height report 不带 blockID**
> （见修正后的第 3 项）。

建议接口（供参考，非待办）：

```js
window.newPi.upsertBlock({
  id,
  kind,
  markdown,
  isStreaming,
  version
})

window.newPi.freezeBlock({
  id,
  finalMarkdown,
  digest
})
```

约束：

- frozen block DOM 不重建
- tail block 只替换自身
- height report 带 blockID
- rendererVersion 不匹配时拒绝 replay

### 第三步（修正后排第 2–3 位）：高度表接入 blockID

```text
messageHeight = sum(blockHeights) + blockSpacing
```

rail 与恢复锚点都从这张表读取。

> **[核验补充]** 本步实际含两件可拆分的事，优先级不同：
>
> - **先做**：把已有的 `engineFingerprint` 接进 `height(for:)`（当前无引擎校验，改渲染器后旧高度仍命中，
>   有实际隐患）——见 §4 P0「高度缓存 key」
> - **后做**：JS 高度上报带 blockID、高度表下沉到 block 级（当前按整条 `item.body` 算 SHA256）

### 第四步（修正后排第 1 位）：完成滚动状态机

先收敛 writer，再处理体验细节：

1. 禁止 restore 期间 bottom follow
2. streaming follow 只在原本 bottom 时生效
3. ~~rail jump pending until height ready~~ —— **[核验修正]** ✅ 已完成，见 §4 P1「rail 继续基于高度表」
4. programmatic scroll 差值 <1pt 跳过
5. 高频 scroll coalesce

> **[核验补充]** 这是三项待办中价值最高的一项：当前 4 个滚动写入点由 6 个 `onChange` 驱动，
> 无统一意图状态，代码注释已记录过由此产生的"恢复被钉底覆盖""冷启动 scrollTo 被时序吞掉"两类症状。

### 第五步（修正后排第 4 位）：工具过程卡片化

从最痛的工具输出开始：

- running/success/error 三态
- collapsed by default
- tail 3-line preview
- click 展开
- 展开只 invalidate 单个 block 高度

---

## 6. 风险与不要做的事

### 不要把 NewPi 改成纯 SwiftUI LazyVStack

参考项目已经证明：一旦有长历史、复杂 Markdown、精确 rail、恢复锚点，SwiftUI 自动高度和 id scroll 会变成时序黑盒。

### 不要照搬 SwiftChat 的负 content inset

它解决了 UIKit row growth 抖动，但会让 rail y、scrollbar length、bottom threshold 复杂化。NewPi 的高度表方案更符合自身目标。

### 不要把 osaurus 全量重写进 NewPi

osaurus 强，但复杂度极高。NewPi 应分块吸收：

1. block diff
2. height cache
3. scroll anchor
4. native process UI

而不是一次性替换整个 chat 层。

### 不要在流式期间每 delta 写持久模型

OmniChat 的 `streamingContent` 与 SwiftData 分离值得保留。NewPi 应确保：

```text
provider delta → volatile render state
stream complete → transcript/persistence final content
```

### 不要引入网络 CDN 渲染资源

markdown-webview / OmniChat 都依赖远端资源。NewPi 作为本地 coding agent 必须保持离线可用、可版本化、无隐私泄漏。

### 不要把工具 JSON 塞进 assistant Markdown

工具过程是 timeline event，不是正文。混排会导致：

- parser 成本增加
- 高度不可预测
- 复制正文被污染
- 工具状态无法独立更新

---

## 7. 最终判断

如果按借鉴价值排序：

1. **osaurus**：block diff、高度、锚点、纯 AppKit 过程 UI 的完整答案。
2. **SwiftChat**：stable chunks + tail buffer 的最直接可复制思想。
3. **markdown-webview**：WKWebView 生命周期 / JS bridge / 高度同步的最小正确实现。
4. **MLXCode**：工具卡、代码块、macOS coding assistant 的 UI 结构。
5. **Agent**：活动日志增量 append 与 tab 缓存。
6. **OmniChat**：macOS WKWebView 反例与流式节流参考。
7. **SwiftStreamingMarkdown**：block renderable / rewrite / paragraph view 池。
8. **hanlin-ai**：历史窗口和 tail status preview。
9. **GetStream**：streaming component API 与 code/chart 路由。
10. **swift-markdown-ui**：静态 Markdown API 和主题设计。
11. **AICat**：产品层与性能取舍。
12. **ChatGPTSwiftUI**：简单 baseline。
13. **mlx-swift-chat**：模型加载/生成状态，基本不涉及 chat 渲染。

NewPi 最合理的路线不是推倒重来，而是：

```text
保留 WKWebView document renderer
保留高度表 + 手动窗口化
保留已有的块级增量与 tail-only normalization（已优于参考实现）
补上显式 scroll state machine          ← 价值最高
把 engineFingerprint 接进高度查询       ← 有实际隐患
把高度表下沉到 block 级
把工具过程移出正文，做成轻量原生卡片
```

> **[核验修正]** 初版此处写"补上稳定 block identity / 补上 tail-only normalization/update"，
> 与 §0 第 1 条自相矛盾，且与代码不符：tail-only normalization 已完成
> （`markdown-renderer.js:237-297`），block identity 为隐式但有全量兜底，属可选加固。
> 完整台账见 §4.0 与 [核验报告 §5](./ui-architecture-research-verification.md)。

这既符合 NewPi 已经付出的工程投入，也吸收了 13 个项目中真正经过源码验证的经验。

---

## 8. 核验记录

本文已于 2026-08-30 通过源码级核验，核验范围、逐条比对结果与全部修正依据见：

**[`ui-architecture-research-verification.md`](./ui-architecture-research-verification.md)**

核验摘要：

- 13 个 commit SHA 与 remote URL 全部精确匹配
- 外部源码引用（路径 / 行号 / 数值）抽查覆盖 13 个仓库，基本准确；3 处小疏漏已在本文修正
- 本文主动标注的 3 处"注释/README 与代码不符"的修正全部成立，其中 `Markup.id` 一处比初版写的更严重
- **关于 NewPi 自身现状的描述发现实质偏差**：3 项已落地能力被列为待办，已在 §0 / §4.0 / §4 / §5 / §7 修正

---

## 9. 目标架构提案（架构前提不同）

本文全部建议以**保留当前 per-message WKWebView 架构**为前提，
在该前提下净待办为 §4.0 台账中的三项。

若允许调整前提，另有一份提案主张把整条 transcript 收拢进**单个 WKWebView**，
让 Web 引擎同时拥有布局权与滚动权：

**[`ui-target-architecture.md`](./ui-target-architecture.md)**

其核心论点是：本文 §4.0 的三项待办（滚动状态机、engineFingerprint、block 级高度表）
**都是「原生持布局权、Web 持内容尺寸」这条异步边界的补偿工作**；
移除该边界后其中两项直接消失，同时换来当前架构做不到的三项能力——
跨消息文本选择、全文查找、诚实的滚动条。

需注意该提案有两处与本文结论相反，分歧均源于架构前提：

| 议题 | 本文（当前架构下） | 目标架构提案 |
|---|---|---|
| 工具卡的实现 | 原生轻量视图（避免再开 WebView） | 文档内组件（原生视图插进流会重造边界） |
| osaurus 的借鉴地位 | 借鉴价值第 1 位 | 参考实现质量第 1，但不作为目标架构（其复杂度多在重新实现浏览器已有机制） |

该提案已用本机 WebKit 实测了所依赖的平台能力（`content-visibility` ✅ / `overflow-anchor` ❌ 等），
并明确标注其最大未验证假设为「单文档在 500 turn 规模下的性能」，
建议以一次 spike 作为 go/no-go 闸门。
