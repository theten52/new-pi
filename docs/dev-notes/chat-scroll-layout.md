# NewPi 聊天滚动与布局：Agent 参考手册

> **受众**：后续 Agent / 开发者。在 macOS SwiftUI 聊天界面中实现「底对齐、流式不跳、不被状态栏遮挡」之前，请先读本文再改代码。
>
> **当前基线**：分支 `feat/streaming-markdown-blocks`（2026-08-27，基于 `5354447` 之后的重构）
>
> **设计史与调研**：[`2026-08-28-streaming-markdown-rendering-context.md`](./2026-08-28-streaming-markdown-rendering-context.md) 记录了本轮渲染重构的设计意图、行业调研、踩坑与审查核查，改代码前建议先读。
>
> **相关文件**：
> - `NewPiApp/NewPiChatView.swift` — 布局 + 滚动
> - `NewPiApp/NewPiChatScrollHelper.swift` — 锚点 ID、composer 高度 / 底部锚点位置 PreferenceKey
> - `NewPiApp/NewPiAgentStatusView.swift` — 输入区状态条 / 工具栏图标
> - `NewPiApp/NewPiMarkdownText.swift` — 消息行布局（助手全宽 / 用户气泡）
> - `NewPiApp/NewPiMarkdownWebRenderer.swift` — WKWebView 渲染器（流式 + 终态统一）
> - `NewPiApp/MarkdownRenderer/markdown-renderer.js` — 块级增量渲染、尾部修复、流式光标
> - `NewPiApp/NewPiViewModel.swift` — `agentActivity`、`isStreaming`
> - `NewPiApp/NewPiApp.swift` — RootView、Session 高亮

---

## 1. 目标行为（产品预期）

用户期望的聊天布局：

1. **短对话**：最新消息贴在输入区/状态栏上方，留白在上方（类似 iMessage / ChatGPT 底对齐）
2. **长对话 / 流式输出**：最新内容始终可见，与状态栏保持固定间距（默认 **16pt**）
3. **发送时**：输入气泡不应先跳到标题栏下方，再被拉回中间
4. **流式时**：回复气泡不应「跳一下」；不应出现「被挡住 → 滚回来 → 再被挡住」的循环
5. **内容未溢出视口时**：不应有多余的上下滚动

---

## 2. 最终架构（当前可用方案）

```
GeometryReader
└── VStack(spacing: 0)
    ├── ScrollViewReader
    │   └── ScrollView
    │       └── VStack (minHeight = viewport - composer, alignment: .bottom)
    │           ├── Spacer(minLength: 0)          // 始终保留：短对话底对齐
    │           ├── messages (ForEach transcript)
    │           ├── Color.clear (16pt)            // 间距必须在锚点 *上方*
    │           └── anchor (1px, id: chat-scroll-bottom)
    └── chatComposer（与 ScrollView 平级，固定底部）
        ├── NewPiAgentStatusBar ("NewPi is ready/thinking/writing…")
        ├── Divider
        └── TextField + Stop / Send
```

### 关键常量

```swift
private let messageBottomGap: CGFloat = 16

let scrollViewportHeight = max(0, geometry.size.height - composerHeight)
```

composer 高度通过 `ComposerHeightPreferenceKey` 在 `chatComposer` 上实测。

### Markdown 渲染分工（2026-08-27 起，本分支）

| 阶段 | 渲染方式 | 原因 |
|------|----------|------|
| 流式输出中 | WKWebView + markdown-it（`streaming: true`，块级增量渲染） | 单引擎，消除完成时的换引擎跳变 |
| 输出完成 | 同一 WKWebView，一次全量重渲染 + hljs 高亮 | 归一化块结构、补高亮 |

要点：

- JS 侧按顶层块切分（围栏感知），已完成的块冻结不动，每帧只重渲染尾部块；尾部块的未闭合语法（围栏 / 行内代码 / 加粗）在**渲染副本**上修复。
- 流式期间尾块跳过 hljs，冻结块带高亮；完成时一次全量高亮归一化。
- 流式光标 ✦（渐变流光）；完成后进入静止终态（静态停留后淡出，绝对定位不参与布局）。
- 旧方案「流式原生 Text、完成切 WebView」已废弃 —— 换引擎跳变是它解决不了的问题（见 §3.6 更新）。
- 滚动跟随由 ChatView 监听 `transcript` 变化驱动；高度通知 `newPiStreamingContentDidGrow` 已删除（曾是只发不收的死代码）。

---

## 3. 踩坑清单（按严重程度）

### 3.1 ❌ `safeAreaInset` 在 macOS 上不能可靠地「让出」滚动区域

**现象**：滚动条延伸到状态栏后面；最新 Markdown 被「NewPi is writing…」挡住。

**原因**：macOS 上 `ScrollView` + `safeAreaInset(edge: .bottom)` 不会像 iOS 那样严格缩小 clip 区域，内容仍可滚到 inset 下方。

**教训**：聊天输入区用 **VStack 平级布局**（ScrollView 在上、composer 在下），不要用 ZStack 叠加或单独依赖 `safeAreaInset` 防遮挡。

---

### 3.2 ❌ 底部 padding 放在滚动锚点 *之后* = 视觉上等于没有

**错误结构：**

```
messages
anchor (scrollTo 定在这里)
.padding(.bottom, 48)   ← 滚到底时 padding 在视口下方，看不见
```

**现象**：代码写了 16pt/48pt，截图里只有 4–8px。

**正确结构：**

```
messages
Color.clear.frame(height: 16)   ← 间距在锚点上方
anchor (1px, id: chat-scroll-bottom)
```

**教训**：`scrollTo(anchor, anchor: .bottom)` 把锚点贴在视口底边；**可见间距必须放在锚点上方**。

---

### 3.3 ❌ 两套（或多套）滚动机制互相打架

曾同时使用：

- `ScrollViewProxy.scrollTo`
- `NSScrollView.scrollToBottom()`（AppKit hack）
- 多次 `DispatchQueue.main.async` 延迟滚动
- `scrollPosition(id:anchor:)`

**现象**：「不跳了但遮挡」或「跳一下再回来」的循环。

**教训**：

- macOS 只保留 **一种** 主机制：`ScrollViewReader` + `scrollTo(anchor, anchor: .bottom)`
- **不要**再用 NSScrollView hack（坐标系与 SwiftUI 不一致，易与 scrollTo 打架）
- **不要**多次 async scrollTo；一次同步即可（流式时 `disablesAnimations = true`）

> ⚠️ 早期笔记（`2026-08-26-streaming-markdown-scroll-ux.md`）曾推荐 AppKit 滚屏 helper，已在 `5354447` **废弃**。

---

### 3.4 ❌ `scrollPosition` 在 macOS 上内容变高时不持续跟随

**现象**：绑定同一 ID 后，WebView/气泡长高但滚动不更新，最新行被挡。

**教训**：流式场景用 **`scrollTo` 主动滚**，不要依赖 `scrollPosition` 自动 maintain。同一 ID 重复赋值可能不触发重新滚动。

---

### 3.5 ❌ `isStreaming` 切换时改变布局策略

曾做：

```swift
if !isStreaming { Spacer() }
minHeight: isStreaming ? 0 : scrollViewportHeight
```

**现象**：

- `send()` 里立刻 `isStreaming = true` → 去掉 Spacer/minHeight → 输入气泡跳到标题栏下
- 助手回复出现后内容变长 → 再被 scroll 拉回中间

**教训**：**布局策略必须恒定**——始终 `Spacer + minHeight`，不要随 streaming 切换。流式与非流式只差别在「是否 pinScroll」，不差别在 layout 模式。

---

### 3.6 ⚠️ WebView 流式渲染导致高度突变（回复气泡「跳一下」）— 已被新架构取代

**现象**：助手气泡首次出现时突然跳变。

**原因链**：

1. 新 `NewPiMarkdownText` 挂载，初始 `webHeight = 44`
2. 曾有 `+64` 缓冲 → 首帧 ~108px
3. HTML 加载 + JS 报高 → 一次跳到 200px+
4. 同时 `onChange(last?.id)`、`onGeometryChange`、Notification 多次 scrollTo

**当时的方案**：流式期间用原生 Text，输出结束后再切 WebView。

**2026-08-27 更新**：该方案因「完成瞬间换引擎跳变 + 流式裸语法外露」被废弃。当前实现为**单引擎**（流式/终态同一 WKWebView），靠 JS 侧块级增量渲染 + 高度只增不减（流式）+ 终态光标绝对定位来消除跳变。若未来要改回原生流式，需先解决双引擎样式不一致问题。

> ⚠️ 早期方案「流式与终态统一 WebView + throttle」曾在 `b458f1a` 时代证明易跳，但当时的根因是全量 `innerHTML` 重绘 + 双轨滚屏；本分支的块级增量渲染已消除该根因，不可直接套旧结论。

---

### 3.7 ❌ `minHeight: geometry.size.height` 未扣除 composer 高度

**现象**：内容很少时仍可上下滚动；消息浮在中间。

**原因**：`GeometryReader` 测的是整窗高度，composer 占掉底部；内容 minHeight 比可见滚动区大约一个 composer 高度。

**正确**：

```swift
scrollViewportHeight = geometry.size.height - composerHeight
.frame(minHeight: scrollViewportHeight, alignment: .bottom)
```

---

### 3.8 ❌ `scrollTo(lastMessageID, anchor: .bottom)` 与间距 spacer 冲突

把消息底对齐视口底会 **跳过** 锚点上方的 16pt 间距。

**教训**：只 `scrollTo(bottomAnchorID, anchor: .bottom)`，不要先滚 message 再滚 anchor。

---

### 3.9 ❌ Swift 字符数估算高度 + `.clipped()`（历史严重回归）

**现象**：长文流式时对话区空白，只见底部状态条在跳。

**原因**：估算高度与 WebView 实测不一致，滚到底时视口落在空白区。

**教训**：**不要用字符数估算代替实测或 intrinsic 高度**；WebView 方案要跟紧实测高度。

---

### 3.10 ⚠️ 不要把消息列表从 LazyVStack 改回 VStack

`62c4226` 重新引入了 `LazyVStack`（早于它的 `5354447` 曾把 LazyVStack → VStack 作为修复项）。

**在单引擎 WebView 架构下，VStack 是有害的**：每条消息常驻一个 WKWebView，VStack 会急切挂载全部历史消息的 WebView → 内存压力 → WebContent 进程被杀 → 白屏（渲染器已对进程终止做一次自动重建 + 原生兜底，但不应主动制造压力）。

原始失败机制（"LazyVStack 导致底部锚点未布局"）已不存在：**底部锚点在 LazyVStack 之外**，`scrollTo` 不依赖 LazyVStack 的惰性布局。

---

### 3.11 ❌ rail 跳转 `scrollTo(id, .top)` 在长对话中定位不准（已修）

**现象**：多轮长对话中点击消息轨道横线，输入气泡落点偏离视口顶部。

**根因**（三层叠加）：

1. `LazyVStack` 对未布局行只有估算高度，长距离 `scrollTo` 的目标偏移一开始就建立在错误的累计高度上
2. WebView 行高异步实测：滚动动画按"半成品高度"算落点，动画结束后上方行陆续撑高把目标往下推
3. 一次性滚动，无收敛机制

**修复（2026-08-28）**：

- **收敛校正**：目标行用行内 `GeometryReader.onChange(of: minY, initial: true)` 直接回调写回面板状态（**不用** `PreferenceKey`——LazyVStack 惰性容器内的 preference 不向父级传播，`onPreferenceChange` 收不到）；`guard isActive` 隔离后台面板，连续 2 次达标提前结束，`jumpCorrectionCountLimit=6` + `jumpCorrectionWindow=1.8s` 双保险防振荡，偏差 >2pt 时无动画重滚贴顶
- **高度缓存足够准**：`MarkdownRenderingCache` 按"内容 SHA256 + 实测宽度"缓存行高并持久化到 `~/.new-pi/agent/markdown-height-cache.json`，冷重建首帧即正确高度，LazyVStack 的估算误差大幅缩小。注意 `String.hashValue` 每次启动都会变，**不能**用作持久化 key

**教训**：`scrollTo` 在长列表 + 异步测高场景必须配收敛校正；高度缓存的 key 要内容哈希 + 宽度。

---

## 4. 滚动触发策略（当前实现）

### 应触发 `pinScrollToBottom`

- `onAppear`
- 流式时 `transcript.last?.body` 变化
- 流式时 `transcript.last?.id` 变化（新气泡）
- 流式结束 `isStreaming → false`（切 WebView 后对齐）
- `composerHeight` 变化

### 不应触发

- ~~WebView 高度 Notification~~（`newPiStreamingContentDidGrow` 已于 2026-08-27 删除，滚动跟随只认 transcript 变化）
- 每行 `onGeometryChange`（易抖动）
- 多次 async scrollTo
- 非流式时每次 id 变化（短对话靠 Spacer 底对齐）

### 贴底检测与「Jump to latest」（2026-08-27 新增）

- 底部锚点通过 `ChatBottomAnchorPreferenceKey` 上报在滚动坐标系中的 minY，`isNearBottom = anchorY - viewportHeight <= 100`
- 流式时只在贴底才自动钉底；用户上翻超过阈值即释放钉底，并浮出 "Jump to latest" 胶囊（点击回底并重新吸附）
- 消息轨道跳转的 `suppressAutoPinDuringStreaming` 仍然有效，与贴底检测是「且」的关系

### 实现模板

```swift
private func pinScrollToBottom(using proxy: ScrollViewProxy) {
    let anchor = NewPiChatScrollSupport.bottomAnchorID
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        proxy.scrollTo(anchor, anchor: .bottom)
    }
}
```

---

## 5. 状态栏 UI 经验

- **「NewPi is thinking/writing/…」** 放在 **composer 内部顶部**（`NewPiAgentStatusBar`），不是 transcript 里的一条消息
- Toolbar 图标与输入区状态条 **始终可见**；idle 时显示 `"NewPi is ready"`
- `NewPiViewModel.agentActivity`：`idle | thinking | writing | runningTool(String)`
- 导航标题：`"Chat"` / `"Chat (branch)"`；状态信息下沉到输入区
- 组件见 `NewPiAgentStatusView.swift`（`NewPiAgentStatusPresentation`、`NewPiAgentStatusBar`、`NewPiAgentStatusIcon`）

---

## 6. 给其他 Agent 的检查清单

改聊天布局前，逐项确认：

- [ ] composer 是否与 ScrollView **平级**（VStack），而非 ZStack 叠加？
- [ ] 间距 spacer 是否在 **锚点上方**？
- [ ] `minHeight` 是否 = **视口高 − composer 高**？
- [ ] 是否 **始终** 使用 Spacer + minHeight（不随 `isStreaming` 切换）？
- [ ] 是否只有 **一种** scroll 机制（无 NSScrollView hack）？
- [ ] 流式与终态是否仍走**同一个** WebView（不要恢复双引擎切换）？
- [ ] 是否避免 `scrollTo(messageID)` 与 anchor scroll 并用？
- [ ] 改完后手动测：空对话首条、长 MD 流式、多轮对话、未溢出不可滚、气泡底与状态栏 16pt

---

## 7. 建议验证清单（手动）

- [ ] 发送首条消息：输入气泡在状态栏上方，不跳到标题下
- [ ] 助手开始回复：回复气泡无首次挂载大跳
- [ ] 长 Markdown 流式：最新行始终可见，不被状态栏挡
- [ ] 气泡底与「NewPi is writing…」间距约 16pt
- [ ] 仅两条短消息时：不可无意义上下滚动
- [ ] 流式结束：WebView 终态渲染，无明显布局崩溃
- [ ] 多轮对话：历史在上方，最新一轮贴底
- [ ] 长对话 rail 跳转：目标气泡顶部对齐视口顶部，无二次漂移

---

## 8. 已知未解决问题（截至 2026-08-27）

| 项 | 说明 |
|---|---|
| Sessions 侧边栏空 | 磁盘有 jsonl 但列表不显示 |
| `defaultMaxTurns` | 若需 200，确认是否在独立 commit |

已解决（勿再当 open issue 处理）：

- ~~`rebuildTranscript` 丢 UUID~~ → `preservedTranscriptID` 按 entryID / messageIndex / 流式 assistant id 复用
- ~~流式结束切 WebView 闪屏~~ → 单引擎渲染，完成时只做一次全量高亮归一化
- ~~流式完成时 `+12` 高度缓冲移除导致闪缩~~ → 缓冲已删；终态光标绝对定位不参与布局，淡出移除时高度不二次收缩

---

## 9. 历史迭代摘要（避免重复踩坑）

| 阶段 | 做法 | 结果 |
|------|------|------|
| debounce 流式 JS | 150ms debounce | 长时间空白，整段一次性出现 |
| 统一 WebView 流式 | throttle + 实测高度 | 滚屏有改善，换行仍跳 |
| AppKit NSScrollView helper | 双轨 scrollTo | 滚屏可用但与 SwiftUI 打架 |
| 字符数估算高度 + clipped | Swift 侧估算 | **长文空白页**，已回退 |
| safeAreaInset + ZStack composer | 叠加输入区 | macOS 遮挡 |
| scrollPosition | 绑定 anchor id | 长高不跟随 |
| isStreaming 切换 layout | 去 Spacer | 发送/回复跳位 |
| 双引擎（原生流式 Text + 终态 WebView） | 完成时换引擎 | 换引擎跳变、流式裸语法外露，已废弃 |
| **当前** | VStack 固定 composer + 锚点上 spacer + 单引擎 WebView 块级增量渲染 | 见分支 `feat/streaming-markdown-blocks` |

更细的时间线见：`docs/dev-notes/2026-08-26-streaming-markdown-scroll-ux.md`（部分结论已被本文 supersede）。

---

## 10. 相关提交

| Commit | 说明 |
|--------|------|
| `b458f1a` | 流式/终态统一 WebView + throttle（全量 innerHTML，换行仍跳） |
| `c504ab0` | 滚屏抖动、AppKit helper（helper 已移除） |
| `beaf002` | Tool approval sheet 修复 |
| `5354447` | 聊天布局、状态栏、原生流式 Text、滚动修复（旧基线） |
| `62c4226` | 消息轨道 + LazyVStack 回归（本分支保留 LazyVStack，见 §3.10） |
| 分支 `feat/streaming-markdown-blocks` | 单引擎块级增量渲染、✦ 流式光标、贴底检测 + Jump to latest、滚轮监听单例化、WebContent 进程终止恢复 + 渲染器日志埋点 |

---

## 11. 一句话原则

> **macOS 聊天 UI：composer 固定底部、间距在锚点上方、布局策略恒定、流式与终态同一引擎（块级增量）、滚动只滚 anchor、一种 scroll 机制。**

任何一条被打破，都容易复现「跳、挡、多余滚动」三类问题。

---

*最后更新：2026-08-27*
