# 流式 Markdown 输出渲染：设计、调研与实现全记录（2026-08-27 ~ 08-28）

> **本文档性质**：功能上下文全记录（设计意图 + 调研 + 踩坑 + 审查核查），供后续 Agent / 开发者理解「为什么是现在这样做」。
>
> **操作层面的滚动/布局规范**仍以 [`chat-scroll-layout.md`](./chat-scroll-layout.md) 为准；本文是它的上游设计史。
>
> **实现所在分支**：`feat/streaming-markdown-blocks`（基于 main 的 `dd64847` 附近）。

---

## 1. 起点：旧架构的结构性问题

改造前（`5354447` 基线）的渲染是**双引擎切换**：

| 阶段 | 渲染方式 |
|------|----------|
| 流式中 | 原生 SwiftUI `Text`，`AttributedString` `.inlineOnly` 轻解析（只渲染行内格式） |
| 完成后 | 切换为 WKWebView（markdown-it + highlight.js）完整渲染 |

三个绕不开的问题：

1. **完成瞬间的"换引擎跳变"** —— 布局、字体渲染、高度全部突变；还引出了 `webHeight = 44` 重置这类补丁代码。
2. **流式阶段裸语法外露** —— 未闭合的 `**`、半个代码块以原始字符呈现。
3. **每条消息一个 WKWebView 的固有成本** —— 高度同步握手、scroll wheel 转发 hack 等。

另外当时刚发生过一次**白屏**（详见 §6），且渲染层没有任何日志。

---

## 2. 调研：行业已收敛的模式

调研覆盖终端 Agent（Claude Code / Codex CLI / Gemini CLI / glow）、IDE Agent 面板（Cursor / Zed / Windsurf）、macOS 原生 AI 应用（ChatGPT / Claude / Raycast / Enchanted 等）与两个关键开源实现（Textual、Vercel Streamdown、微软 SwiftStreamingMarkdown）。

### 2.1 流式渲染的核心算法：块终结模型（Block Finality）

来源：[Will McGugan — Efficient streaming of Markdown in the terminal](http://willmcgugan.github.io/streaming-markdown/)、[tigerabrodi — How To Build a Performant AI Markdown Renderer](https://tigerabrodi.blog/how-to-build-a-performant-ai-markdown-renderer)、[Vercel streamdown](https://github.com/vercel/streamdown)、[remend](https://vercel.com/changelog/new-npm-package-for-automatic-recovery-of-broken-streaming-markdown)。

- Markdown 文档切成**顶层块**（段落、标题、代码围栏、表格）；流式时**只有最后一个块在变化**，前面的块全部冻结、不再重解析。
- 尾块**类型可能中途变化**（段落变成表格）——只有此时整块替换，否则就地更新。
- 只从尾块起点重解析（tail-only parsing），解析成本与文档长度无关。
- **合并 token 突发（coalescing）**：token 到达快于渲染时，永远渲染最新状态，不回放中间状态（React 侧对应 `startTransition`）。
- **修复未闭合语法再渲染**（在副本上，不动原始串）：补全未闭合的 `**`、`` ` ``、代码围栏、链接、`$$math`。**必须围栏上下文感知** —— Python 的 `2 ** 3` 不能被当成加粗。修复优先级：围栏 > 粗斜体 > 行内代码 > 链接 > math。
- **块级 memoization 用稳定索引做 key**，不用内容 hash（会导致 unmount/remount）。
- 典型反模式：每个 token 全量 re-parse + re-render（卡顿）；按 chunk 无状态渲染（跨 chunk 边界的格式被破坏，见 goose#7223）。

### 2.2 各产品的具体做法（值得借鉴的模式）

- **Claude Code**：工具调用单行折叠（`⏺ Tool(arg)` + `⎿` 结果）、重复命令折叠（"Ran N shell commands"）、长路径**中间截断**、spinner 旋转动词 + 耗时、可疑 markdown 链接降级为纯文本（安全）。
- **Cursor**：diff 块可点击跳转到文件对应行；per-hunk Keep/Reject 是**信任 UX 的核心**（曾因移除引发用户反对）；checkpoint 按钮内嵌在时间线里。
- **Zed**：Review Changes 手风琴条（N 文件 / N 行改动，展开为 multi-buffer diff）；"Open Thread as Markdown" 逃生口。
- **Windsurf**：工具调用透明卡片（参数和返回值可见）+ 执行前 plan 预览 + diff staging。
- **glow/glamour（Charm）**：stylesheet 驱动的渲染，引用用 `▌` 排水沟竖条、链接渲染为 `text (url)`；它是"终端 markdown 好不好看"的标杆，但其管线本身非流式。
- **ChatGPT / Claude / Cursor 桌面端**：流尾都有"活着"信号（脉冲圆点 / 小方块 / 细竖条）；**没有人做逐字打字机** —— 流畅感来自合并渲染，不是动画；首 token 应在 200–600ms 内出现。
- **自动滚动共识**：只在视口距底 ~100px 内时吸附；用户上翻立刻锁定位置并浮出 "Jump to latest"（[setproduct 的 AI chat 设计文](https://www.setproduct.com/blog/ai-chat-interface-ui-design)）。
- **布局共识**：内容列宽 ~720–768px 居中；**助手消息全宽、不用气泡**；hover 才显示消息操作按钮。
- **macOS 26 Liquid Glass**（[Apple HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)）：玻璃只属于 chrome 层（工具栏/侧栏/浮动输入框），**正文内容必须落在不透明表面上**；要为 Reduce Transparency / Increase Contrast 设计。
- **微软 [SwiftStreamingMarkdown](https://github.com/microsoft/swiftstreamingmarkdown)**（2026-08 开源）：Apple 平台上与 streamdown 对标的原生流式渲染器，是未来"全原生"方向的直接参照。
- **消息状态机**（不是两个状态）：queued shimmer → thinking（可折叠）→ streaming → complete（hover 操作）→ error（具体原因 + 一个恢复动作）→ stopped（保留部分输出，标中断）。

### 2.3 当时提出的三个方向

| 方向 | 内容 | 结论 |
|------|------|------|
| **A** | 保留 WKWebView，单引擎全程流式 + JS 块级增量渲染 + 尾部修复 + 流尾光标 | ✅ 采用 |
| **B** | 全原生 SwiftUI 渲染（参照 SwiftStreamingMarkdown），彻底抛弃 WKWebView | 留作长期选项 —— 若每消息一个 WebView 的成本（内存/进程数）成为瓶颈再迁移 |
| **C** | 聊天区视觉层：助手全宽无气泡、代码块头部栏（语言 + hover 复制）、贴底检测 + Jump to latest、克制的标题层级 | ✅ 采用，与 A 正交 |

**选择 A+C 的理由**：保留现有 WebView 安全基础设施（CSP、双重 JSON 编码、链接拦截），用块终结模型同时解决跳变和性能；视觉层重构投入小、收益直接。

---

## 3. 实现：方向 A（单引擎 + 块级增量渲染）

### 3.1 JS 渲染器（`NewPiApp/MarkdownRenderer/markdown-renderer.js`）

- **`splitBlocks(source)`**：按行扫描，空行是块边界；围栏代码块内部不切分（``` 或 ~~~，允许 0–3 空格缩进；闭合行必须**以相同标记开头**且归属于该代码块）。返回 `{ blocks, tailFenceMarker }`（扫描结束时仍处于围栏内则后者非空）。
  - 已知简化：` ``` ` 与 ` ```` ` 长度不匹配的围栏按三字符标记处理；松散列表会在空行处拆成多个块 —— 流式期间与最终全量渲染可能有细微差异，**完成时的全量重渲染会归一化**。
- **增量渲染**：`renderedBlocks`（source + DOM 节点）与 root 子节点一一对应。每帧计算与上一帧的**逐字节公共前缀**，冻结块不动；前缀分叉（源变短/被编辑）→ 清空全量重建；源变短 → 裁掉多余尾节点。
- **高亮策略**：冻结块带 hljs 高亮；流式尾块不带（`streamingRenderDepth` 开关，**try/finally 保护**，见 §7）；完成时一次全量重渲染带高亮（顺带归一化刚闭合的围栏）。
- **`repairTailSource(source, tailFenceMarker)`**（只作用于渲染副本）：
  - 尾块在围栏内 → 补一个闭合行（用真实的开放标记 ``` 或 ~~~）；
  - 否则先**剥掉已闭合的行内代码段**再数标记（防止 `2 ** 3` 被误判为奇数个 `**`）；
  - 反引号奇数个 → 补一个 `` ` `` 即止（其余标记可能在代码段内）；
  - `**` / `__` / `~~` 经 `needsClosingMarker` 判定：奇数次**且**最后一次出现后跟非空白才补（`2 ** 3` 两侧空白 → 不动）。
- **`window.onerror` 钩子**（内联 nonce 脚本）→ `rendererError` 消息通道，补 `evaluateJavaScript` 错误回调覆盖不到的路径（初始引导脚本异常）。

### 3.2 Swift 渲染桥（`NewPiApp/NewPiMarkdownWebRenderer.swift`）

- **单引擎**：`NewPiMarkdownText` 流式/终态都用 `NewPiMarkdownWebRendererView`；原生 AttributedString 仅为渲染器缺失/失败时的兜底（`.full` 解析）。删除了 `webHeight = 44` 重置补丁和 `.inlineOnly` 流式路径。
- `documentHTML` 的初始内联引导脚本复用 `renderJavaScript(for:streaming:)`，WebView 挂载即进入正确模式（CSP、双重 JSON 编码、链接拦截全部原样保留）。
- **`copyText` 消息通道**：file:// 源下 `navigator.clipboard` 不可靠，代码块复制走原生 `NSPasteboard`。
- **最终渲染去抖修复（重要 bug）**：`renderPending` 原先只比文本（`markdown != lastRenderedMarkdown`）。流式结束时若最终文本与最后一次流式渲染相同，**最终渲染被整个跳过** → 光标永远残留闪烁、代码块永远拿不到高亮。修复：同时比较文本 + flush 模式（`lastRenderWasFlush`），并在 JS 在途期间**本地捕获渲染模式**避免竞态。
- **WebContent 进程终止恢复**：`webViewWebContentProcessDidTerminate` → 用当前内容重建一次页面；再次崩溃 → `reportFailure` 退回原生文本。`loadInitial` 重置在途渲染状态（`isRenderingJavaScript` / `rerenderAfterFlight` / 节流任务）——进程若在 evaluateJavaScript 在途时死掉，不重置会永久卡死。
- **页面加载看门狗（10s）**：`loadHTMLString` 始终不回调 `didFinish` 时主动退回原生渲染（该场景无错误回调、永久白屏）。
- **`reportFailure(reason:)` 带原因写 error 日志**（原先静默失败，是诊断黑洞）。
- **滚轮转发单例化**：`MarkdownScrollWheelForwarder`（`@MainActor` 类单例 + `NSHashTable.weakObjects()`），全局只注册一个 `NSEvent` 滚轮监听，命中哪个 WebView 就转发给它的外层 NSScrollView。之前每条消息一个全局监听器。
  - 并发检查踩坑：enum 静态可变状态与 `NSEvent` 不可 Sendable 都会报错；最终与旧代码同构的 `@MainActor` 类单例可直接编译，无需 `@preconcurrency`。

### 3.3 流式光标

- **流式中**：`✦` 星形符号，蓝→紫渐变流光扫过（`background-clip: text` + `background-position` 动画）+ 轻微缩放缓冲（1s）。
- **静止终态**（用户明确要求"输出结束后整一个静止的终态"）：完成后流光与脉冲停止，`✦` 变静态纯紫，停留约 0.7s 后淡出（共 1.3s），再停 0.1s 从 DOM 移除。
- `hasStreamed` 区分"刚流式完的消息"与"会话恢复时直接完成态挂载的消息"——后者不闪终态光标。
- **终态光标用绝对定位**（落在流式光标原处，`.markdown-body` 为 `position: relative` 包含块），不参与布局；淡出期间上报高度包含其视觉范围（防 Swift 侧 frame 裁切）；移除后恢复精确内容高度。效果：完成瞬间无跳动，唯一一次高度变化（约一行高）发生在光标淡出后、内容已静止时。
- 未加文字（如"正在生成…"）：composer 上方状态栏已有 `NewPi is writing…`，避免重复。

### 3.4 高度上报

- 删除流式 `+12` 缓冲，上报值始终是实测值。
- 流式期间 Swift 侧高度**只增不减**（`applyStreamingHeight`），防抖跳。
- 完成的最终渲染由 JS `ResizeObserver` + 强制上报驱动，flush 分支按 4px epsilon 应用。

---

## 4. 实现：方向 C（聊天区视觉层）

- **`NewPiTranscriptRow`**：助手消息（NewPi/Summary/Error）全宽无气泡（≤760pt）；用户消息保留右对齐 accent 气泡（≤640pt）；复制/fork 按钮 hover 显示（流式中的行保持可见）；Error 保留红色文字。
- **CSS**（`markdown-renderer.css`，覆盖 github-markdown-light）：克制标题层级（h1–h3 ≈ 1.3/1.2/1.1em、semibold、无 h1 下边框）、引用左侧竖条、代码块头部栏（语言标签 + hover 复制按钮、点击后 1s ✓）、光标动画、`.markdown-block` 首末块边距对齐全量渲染。
- **贴底检测 + Jump to latest**（`NewPiChatView` + `NewPiChatScrollHelper`）：
  - 底部锚点经 `ChatBottomAnchorPreferenceKey` 上报 minY，`isNearBottom = anchorY - viewportHeight <= 100`；
  - 流式时只在贴底才钉底；上翻超阈值即释放并浮出 "Jump to latest" 胶囊（regularMaterial），点击清抑制并回底；
  - 与消息轨道的 `suppressAutoPinDuringStreaming` 是「且」的关系；
  - `schedulePinScrollToBottom` 的 `DispatchQueue.main.async` **是有意的**（onChange 时新内容未布局，同步 scrollTo 会拿到旧几何）——审查曾误判为不必要，见 §7。

---

## 5. 滚轮监听之外的已知边界

- 松散列表（loose list）流式期间按独立块渲染，与最终态可能略有差异，完成时全量重渲染归一化。若实测明显，再考虑把列表纳入围栏式跟踪。
- 流式高度只增不减：同一条消息内容中途变短时（当前流程不会发生），高度在最终 flush 时才回落。

---

## 6. 白屏事件：排查与加固（2026-08-27 晚）

**症状**：偶尔输出时白屏，输出结束后仍白屏。

**排查过程**：

1. 读日志：`~/.new-pi/agent/logs/newpi-debug.log`（全局）+ `<项目>/.new-pi/debug.log`（项目级）。白屏时段 agent 运行全部正常（LLM 流正常完成、无 ERROR）→ 问题在渲染层。
2. 发现渲染层是日志黑洞：`reportFailure` 静默失败；初始内联脚本异常无回调；页面加载失败无回调。
3. 最可能根因：方向 A 后每条消息常驻 WKWebView，**WebContent 进程被系统终止**（内存压力/进程数上限）时 WebView 永久白屏、不走任何错误回调。

**加固**（无论根因是否命中都值得做）：

- `webViewWebContentProcessDidTerminate` → 重建一次 → 再崩溃退回原生文本（**宁可降级不可白屏**）；
- `window.onerror` → `rendererError` 通道；
- 10s 页面加载看门狗；
- 所有失败路径带原因写 error 日志。

**下次复现的诊断路径**：查日志中 `Markdown web content process terminated`（进程被杀，已自动恢复）或 `Markdown renderer failed, falling back to native text` + 原因（具体失败路径）。加了埋点后这些场景表现为"样式突然变朴素"（原生兜底）而非白屏。

---

## 7. 对"Phase 6c 审查"的核查结论（2026-08-28）

审查列出 3 P0 + 2 P1 + 3 P2 + 3 P3。逐条对照代码、设计文档与 git 历史后的判定：

| # | 审查主张 | 核查结论 |
|---|----------|----------|
| P0-1 | LazyVStack 回归，应改回 VStack（"一行改动"） | **前提属实、建议错误**。`chat-scroll-layout.md` 确实记载 LazyVStack→VStack，git blame 确认 `62c4226` 带回了 LazyVStack。但原始失败机制（锚点未布局）已不存在（锚点在 LazyVStack 外）；且单引擎架构下 VStack 会急切挂载全部 WKWebView → 内存压力 → 加剧白屏。**LazyVStack 现在是保护措施，已写入 `chat-scroll-layout.md` §3.10 防再犯** |
| P0-2 | `newPiStreamingContentDidGrow` 只发不收 | ✅ 属实，已删（滚动由 transcript onChange 驱动，通知是旧架构残留） |
| P0-3 | 流式 `+12` 缓冲结束移除致闪烁 | ✅ 属实但轻微，与 P2-8 重复计数。已修（删 +12 + 终态光标绝对定位） |
| P1-4 | 每气泡一个全局滚轮监听 | ✅ 属实，已单例化 |
| P1-5 | 每 40ms 全量数组拷贝 O(n) | ⚠️ 夸大。Swift 数组 COW，赋值 O(1)；写时复制的是小结构体缓冲区，可忽略 |
| P2-6 | `schedulePinScrollToBottom` 的 async 不必要 | ❌ 错误。onChange 时布局未落定，同步 scrollTo 会拿旧几何 |
| P2-7 | `suppressAutoPinDuringStreaming` 锁定过久 | ⚠️ 部分成立，Jump to latest 胶囊点击已提供逃生通道 |
| P2-8 | 流式高度只增不减，结束收缩 | ✅ 同 P0-3，已修 |
| P3-9 | `flushRendering` 应改枚举 | 风格建议，未动 |
| P3-10 | `streamingRenderDepth` 无异常保护 | ✅ 属实，已加 try/finally |
| P3-11 | 滚动跟随与 transcript 耦合 | 架构观察，未动 |

**教训**：审查工具的"严重度定级"普遍偏高（死代码、12px 跳动标 P0）；修复建议必须结合当前架构验证，不能照单全收。

---

## 8. 验证记录

- **构建**：全程 `xcodebuild build -scheme NewPi -configuration Debug` 通过（每轮改完都跑）。
- **JS 逻辑**：node harness（临时文件，未入库）驱动真实 `markdown-renderer.js`，21 条断言：围栏感知切分、未闭合围栏修复（``` 和 ~~~）、`2 ** 3` 在围栏内外都不误判、反引号/加粗补全、冻结块 DOM 节点复用、前缀分叉全量重建、光标生命周期、空源只剩光标。
- **未覆盖**：真机流式的观感（完成瞬间是否还有跳变、高亮切换时机、Jump to latest 出现时机）需人工验证；白屏修复无法稳定复现，靠日志埋点等下次复现确认。

---

## 9. 文件地图（本分支）

| 文件 | 职责 |
|------|------|
| `NewPiApp/MarkdownRenderer/markdown-renderer.js` | 块级增量渲染、尾部修复、光标生命周期、代码块外框、高度上报、onerror 钩子 |
| `NewPiApp/MarkdownRenderer/markdown-renderer.css` | 排版覆盖、光标流光/终态、代码块头部栏 |
| `NewPiApp/NewPiMarkdownWebRenderer.swift` | HTML 壳（CSP）、Coordinator（节流、高度、copyText/rendererError 通道、进程终止恢复、看门狗、失败日志）、`MarkdownScrollWheelForwarder` |
| `NewPiApp/NewPiMarkdownText.swift` | `NewPiMarkdownText`（单引擎 + 原生兜底）、`NewPiTranscriptRow`（助手全宽 / 用户气泡 / hover 操作） |
| `NewPiApp/NewPiChatView.swift` | 滚动钉底、贴底检测、Jump to latest、composer |
| `NewPiApp/NewPiChatScrollHelper.swift` | 锚点 ID、坐标空间名、PreferenceKey |
| `NewPiApp/NewPiViewModel.swift` | 流式增量 40ms 节流合并（`enqueueStreamingDelta`/`flushStreamingDelta`）、转录身份保持（`preservedTranscriptID`） |

## 10. 后续可选方向

- **方向 B（全原生渲染）**：参照微软 SwiftStreamingMarkdown；触发条件是每消息一个 WebView 的内存/进程成本成为实测瓶颈。
- 暗色模式：当前 markdown CSS 只有 light 主题（`github-markdown-light.css`），App 若支持深色需补 `github-markdown-dark` + 媒体查询切换。
- P3-9（flushRendering 改枚举）、P3-11（滚动跟随解耦）等架构债。
- diff 的一等公民展示（Cursor/Zed 式 per-hunk 审阅）——Agent 信任 UX 的下一步，未做。

---

*作者：Kimi Code CLI 会话记录整理。相关规范文档：[`chat-scroll-layout.md`](./chat-scroll-layout.md)；历史时间线：[`2026-08-26-streaming-markdown-scroll-ux.md`](./2026-08-26-streaming-markdown-scroll-ux.md)（部分结论已过时）。*
