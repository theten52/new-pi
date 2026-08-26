# 开发笔记：流式 Markdown + 聊天滚屏 UX（2026-08-26）

> ⚠️ **本文档为历史迭代记录，部分结论已过时。**
>
> **当前 Agent 请以 [`chat-scroll-layout.md`](./chat-scroll-layout.md) 为准**（基线 commit `5354447`）。
>
> 下文保留早期试错时间线，供追溯；勿按本文「AppKit 滚屏 helper / 流式 WebView 统一渲染」等建议改代码。

本文记录 NewPi 聊天界面在 **WKWebView 流式 Markdown 渲染** 与 **自动滚屏** 迭代过程中暴露的问题、已尝试的修复、当前状态与待办。

相关文件：

- `NewPiApp/NewPiMarkdownText.swift`
- `NewPiApp/NewPiMarkdownWebRenderer.swift`
- `NewPiApp/NewPiChatScrollHelper.swift`
- `NewPiApp/NewPiApp.swift`（`NewPiChatView`）
- `NewPiApp/MarkdownRenderer/markdown-renderer.js`

---

## 背景与目标

- **目标**：流式与终态均用同一套 WebView（markdown-it + highlight.js），保证样式一致；输出时自动滚到底；尽量减少闪烁和换行跳动。
- **平台特性**：macOS 上 SwiftUI `ScrollViewReader.scrollTo` 在内容增高但锚点 id 不变时**不会继续滚动**，需 AppKit `NSScrollView` 辅助。

---

## 问题时间线

### 1. 流式长时间空白、整段一次性出现

| 项 | 说明 |
|---|---|
| **现象** | 流式阶段几乎不更新，停顿或结束后整段 Markdown 一次性渲染 |
| **根因** | 早期实现为 **debounce（150ms）** 而非 throttle：每个 token 重置计时器，连续输出期间很少触发 `evaluateJavaScript` |
| **修复** | 改为 **throttle（50ms → 后调至 100–120ms）**；流式与终态统一走 WebView |
| **提交** | `b458f1a` — Unify streaming/final Markdown via throttled WebView |

---

### 2. 快速输出时整页跳动、「NewPi is thinking…」频繁闪动

| 项 | 说明 |
|---|---|
| **现象** | 模型输出很快时对话页跳动感强；底部 thinking 指示器频繁被滚入/滚出视口 |
| **根因** | 每个 token 触发 `scrollTo` + 动画；WebView 高度频繁变化（阈值过小）；thinking 与内容滚动锚点竞争 |
| **修复尝试** | thinking 在 assistant 输出后隐藏；滚动节流 + 无动画；WebView 高度 debounce + 阈值；统一 AppKit 滚屏控制器 |
| **提交** | `c504ab0` — Reduce chat scroll jitter |
| **后续调整** | 用户要求 thinking **始终显示在最后一条消息下方**，又改回固定展示 |

---

### 3. 自动滚屏不生效

| 项 | 说明 |
|---|---|
| **现象** | 内容增长但页面不跟着往下滚 |
| **根因** | `scrollPosition(id:anchor:)` 在 macOS 上内容增高、id 不变时不会重新滚动；`LazyVStack` 可能导致底部锚点未布局 |
| **修复** | `ScrollViewReader` + 底部锚点 `chat-bottom`；`LazyVStack` → `VStack`；新增 `NewPiChatScrollHelper.swift` 直接操作 `NSScrollView`；WebView 高度变化发 `newPiStreamingLayoutDidChange` 通知触发滚屏 |
| **结果** | 用户反馈「基本达到预期，滚屏效果有了」 |

---

### 4. 输出时页面闪烁

| 项 | 说明 |
|---|---|
| **现象** | 滚屏有了但整体仍闪 |
| **根因** | SwiftUI `scrollTo` 与 AppKit 滚屏重复触发；`scrollTrigger` 递增导致频繁 layout；WebView 高度上下波动；隐式动画 |
| **修复** | 流式期间仅 AppKit 滚屏；120ms 节流；流式高度只增不减；加大高度阈值；`.animation(nil, value: webHeight)`；`.transaction { disablesAnimations }` |

---

### 5. 换行时「一跳一跳」

| 项 | 说明 |
|---|---|
| **现象** | 软换行/换段时布局周期性跳动 |
| **根因** | WebView 全量 `innerHTML` 重绘导致高度塌陷再撑开；highlight.js 重复计算；高度/滚屏更新过频 |
| **修复尝试** | JS `streaming: true`：保留 `minHeight`、跳过 highlight、流式不用 ResizeObserver；Swift 侧高度阈值 + debounce；滚屏仅随高度变化 |

---

### 6. Swift 侧估算高度 + `.clipped()` → 长内容页面空白（严重回归）

| 项 | 说明 |
|---|---|
| **现象** | 持续输出长内容时对话区空白，只能看到底部 「NewPi is thinking…」在跳 |
| **根因** | 用字符数 **估算** 气泡高度并按 3 行一桶跳增，与 WebView 实测高度不一致；`.clipped()` 裁切；自动滚到底时视口落在**估算撑出的空白区域**，正文在视口上方 |
| **修复** | **回退**估算方案：恢复 WebView 实测高度驱动布局；去掉 `.clipped()`；流式 JS 恢复 `scheduleHeightPost`；Swift 流式 `height = max(当前, 实测)` + 阈值 debounce |
| **状态** | 已回退，Build 通过；换行微跳与用户反馈的其它问题仍可能 exist |

---

## 代码审查发现的待修问题（截至会话末，未全部落地）

### 高优先级

| ID | 问题 | 位置 | 建议修复 |
|---|---|---|---|
| UX-REBUILD-ID | `agentEnd` 后 `rebuildTranscript` 为每条消息 **新建 UUID**，流式期间保留的 `id` 丢失，导致全部 WebView remount、高度重置、闪屏 | `NewPiViewModel.syncTranscriptMessageIndices` / `rebuildTranscript` | 按 `sessionEntryID` 或 message index **复用已有 `NewPiTranscriptItem.id`** |
| UX-HEIGHT-CLIP | 固定 `frame(height: webHeight)` + JS 20px + Swift 18px 双重阈值 + 150ms debounce，实测高度被挡时 **最新 token 被裁切** | `NewPiMarkdownText` + `NewPiMarkdownWebRenderer.Coordinator` | 降低/去掉流式 Swift 阈值；或流式用 `minHeight`；JS 流式更积极上报 |
| UX-SCROLL-MONITOR | **每个 Markdown 气泡** 注册一个 `NSEvent` 全局滚轮监听器，消息多时重复处理滚轮 | `NewPiMarkdownWebRenderer.Coordinator.installScrollWheelForwarding` | 改为单例监听器，或仅 hover 时转发 |

### 中优先级

| ID | 问题 | 位置 | 建议修复 |
|---|---|---|---|
| UX-FLUSH-HEIGHT-RACE | 切 `flush` 时未 cancel `heightWorkItem`，流式 pending 高度可能与终态竞争 | `scheduleUpdate(flush: true)` | flush 时 cancel `heightWorkItem` |
| UX-FLUSH-SHRINK | 流式高度只增不减，flush 时 `height = reportedHeight` 可能 **突然变矮** | `scheduleHeightUpdate` flush 分支 | flush 时一次测量；或 `height = max(streamingPeak, reported)` 再动画过渡到精确值 |
| UX-SCROLL-BODY | 滚动仅绑 `newPiStreamingLayoutDidChange`，高度阈值挡住时 **内容涨但不滚** | `NewPiChatView` | 高度更新与滚屏同源；或仅在「用户已在底部」时跟随 |
| UX-THINKING-LAYOUT | 流式期间 thinking 始终占位，底部布局持续变化 | `NewPiChatView` | 产品决策：输出开始后隐藏 vs 固定占位 + 稳定滚屏 |

### 低优先级 / 设计债

| ID | 问题 | 建议 |
|---|---|---|
| UX-NC-COUPLING | WebRenderer 通过 `NotificationCenter` 耦合 Chat | 改为 Binding/回调或专用 `ScrollFollowModel` |
| UX-DUAL-HEIGHT | JS `minHeight` 与 Swift `webHeight` 两套高度 | 流式只信一侧，flush 再对齐 |

---

## 有效经验总结

1. **macOS 聊天滚屏**：不要单靠 SwiftUI `scrollPosition` / `scrollTo`；内容增高需 AppKit `NSScrollView` 滚到底，锚点放在列表最底部（thinking 下方）。
2. **流式 WebView**：用 **throttle** 不用 debounce；流式跳过 highlight 可减闪；**不要用 Swift 字符估算代替实测高度**（长文必翻车）。
3. **固定 frame + clipped**：实测高度滞后时必然裁切最新内容；要么跟紧实测，要么用 native 叠层流式显示。
4. **Transcript 身份稳定**：`ForEach` 依赖 `id`；`rebuildTranscript` 必须 preserve UUID，否则 WebView 全量 remount。
5. **全局 NSEvent 监听器**：按 View 实例注册会泄漏/叠加，应单例或弱引用集合。

---

## 建议验证清单（手动）

- [ ] 长段落快速流式输出：正文可见、不空白、能跟滚
- [ ] 软换行 / 代码块 / 列表：跳动可接受
- [ ] 流式结束：无高度闪缩、highlight 正常
- [ ] 多条历史消息：滚轮在气泡上仍滚外层聊天
- [ ] `agentEnd` 后：同一条 assistant 消息无 WebView 闪一下

---

## 相关提交（本会话附近）

| Commit | 说明 |
|---|---|
| `b458f1a` | 流式/终态统一 WebView + throttle |
| `c504ab0` | 滚屏抖动、thinking、高度 debounce（部分逻辑后续又改） |
| （未提交 → 本次提交） | 估算高度方案（已回退）、AppKit 滚屏 helper、streaming JS 模式；**跳动问题仍 open** |

---

*最后更新：2026-08-26*

## 当前状态（提交时）

> **已 supersede**：见 [`chat-scroll-layout.md`](./chat-scroll-layout.md) 与 commit `5354447`。

- ~~自动滚屏：AppKit helper + 底部锚点~~ → 现仅 `ScrollViewReader.scrollTo(anchor)`
- ~~流式 WebView 统一渲染~~ → 现流式 native Text，完成后再 WebView
- 换行/布局跳动：通过原生流式 Text **大幅缓解**；终态切 WebView 仍可能有轻微高度调整

