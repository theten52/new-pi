# NewPi 聊天滚动与布局：Agent 参考手册

> **受众**：后续 Agent / 开发者。在 macOS SwiftUI 聊天界面中实现「底对齐、流式不跳、不被状态栏遮挡」之前，请先读本文再改代码。
>
> **当前基线提交**：`5354447`（2026-08-26）
>
> **相关文件**：
> - `NewPiApp/NewPiChatView.swift` — 布局 + 滚动
> - `NewPiApp/NewPiChatScrollHelper.swift` — 锚点 ID、composer 高度 PreferenceKey
> - `NewPiApp/NewPiAgentStatusView.swift` — 输入区状态条 / 工具栏图标
> - `NewPiApp/NewPiMarkdownText.swift` — 流式原生 Text / 完成 WebView
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

### Markdown 渲染分工

| 阶段 | 渲染方式 | 原因 |
|------|----------|------|
| 流式输出中 | 原生 `Text` / `AttributedString`（`flushRendering == false`） | 高度连续、无 WebView 挂载跳变 |
| 输出完成 | WKWebView + markdown-it（`flushRendering == true`） | 代码高亮、完整 MD 特性 |

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

### 3.6 ❌ WebView 流式渲染导致高度突变（回复气泡「跳一下」）

**现象**：助手气泡首次出现时突然跳变。

**原因链**：

1. 新 `NewPiMarkdownText` 挂载，初始 `webHeight = 44`
2. 曾有 `+64` 缓冲 → 首帧 ~108px
3. HTML 加载 + JS 报高 → 一次跳到 200px+
4. 同时 `onChange(last?.id)`、`onGeometryChange`、Notification 多次 scrollTo

**最终方案**：

- **流式期间用原生 Text** → 高度随文字 intrinsic 增长
- **输出结束后**再切 WebView
- 去掉行级 `onGeometryChange` 触发滚动；流式路径不依赖 WebView 高度 Notification

**教训**：`NSViewRepresentable`（WKWebView）**不适合**做流式实时高度布局；流式用 SwiftUI Text，WebView 仅终态。

> ⚠️ 早期方案「流式与终态统一 WebView + throttle」已在实践中证明易跳、易挡，见 `b458f1a` 时代；当前以原生流式为准。

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

**教训**：**不要用字符数估算代替实测或 intrinsic 高度**；若必须用 WebView，跟紧实测；流式优先 native Text。

---

## 4. 滚动触发策略（当前实现）

### 应触发 `pinScrollToBottom`

- `onAppear`
- 流式时 `transcript.last?.body` 变化
- 流式时 `transcript.last?.id` 变化（新气泡）
- 流式结束 `isStreaming → false`（切 WebView 后对齐）
- `composerHeight` 变化

### 不应触发

- WebView 高度 Notification（流式已不用 WebView）
- 每行 `onGeometryChange`（易抖动）
- 多次 async scrollTo
- 非流式时每次 id 变化（短对话靠 Spacer 底对齐）

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
- [ ] 流式是否避免 WebView 固定高度布局？
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

---

## 8. 已知未解决问题（截至 5354447）

以下在本轮 **未** 修复，勿与滚动/layout 混为一谈：

| 项 | 说明 |
|---|---|
| `rebuildTranscript` 丢 UUID | `agentEnd` 后 remount WebView，可能闪屏 |
| Sessions 侧边栏空 | 磁盘有 jsonl 但列表不显示 |
| 流式结束切 WebView | 可能有轻微高度调整（可接受或后续 cross-fade） |
| `defaultMaxTurns` | 若需 200，确认是否在独立 commit |

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
| **当前** | VStack 固定 composer + 锚点上 spacer + 原生流式 Text | 见 `5354447` |

更细的时间线见：`docs/dev-notes/2026-08-26-streaming-markdown-scroll-ux.md`（部分结论已被本文 supersede）。

---

## 10. 相关提交

| Commit | 说明 |
|--------|------|
| `b458f1a` | 流式/终态统一 WebView + throttle（后被原生流式替代） |
| `c504ab0` | 滚屏抖动、AppKit helper（helper 已移除） |
| `beaf002` | Tool approval sheet 修复 |
| **`5354447`** | **聊天布局、状态栏、原生流式 Text、滚动修复（当前基线） |

---

## 11. 一句话原则

> **macOS 聊天 UI：composer 固定底部、间距在锚点上方、布局策略恒定、流式用原生 Text、滚动只滚 anchor、一种 scroll 机制。**

任何一条被打破，都容易复现「跳、挡、多余滚动」三类问题。

---

*最后更新：2026-08-26*
