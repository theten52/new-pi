# 会话切换即时恢复方案（Session-Switch Instant Resume）

> 本文档记录用户遇到的问题、根因分析、业界参考，以及选定的解决方案与落地步骤。
> 供实现与后续复核对照。**第一部分是用户的原话问题，务必保留。**

---

## 一、用户的问题（原始描述，重点存档）

> "为什么 NewPi 的对话内容每次切换 Session 时都要重新加载呢？这个设计是不是有问题，包括 Markdown 预览，是不是可以
> 有其他格式很好的预览方式，现在虽然预览结果是我想要的，但是切换时重新加载这个过程用户体验很差，我想要切换时直接展示
> 最终的结果，没有实时的解析，且直接定位到上次离开的位置。帮我多查资料多查参考，看看有什么方案。"

**用户的核心诉求拆解：**
1. 切换 Session 时**不要重新加载**（当前会重载，体验差）。
2. 切换后**直接展示最终渲染结果**，不做实时/渐进解析。
3. **定位到上次离开的位置**（恢复滚动位置）。
4. 保留现有 Markdown 预览的观感（"现在虽然预览结果是我想要的"，不能因优化而视觉回归）。

---

## 二、根因分析（已核对代码）

**结论：慢的是视图层（WebView 重建 + 重解析 + 重测高），不是数据层（转录数据一直在 `SessionRuntime` 的 LRU 缓存里）。**

1. **每条 Markdown 消息 = 一个独立的 WKWebView**
   - `NewPiTranscriptRow` 对 `NewPi`/`Summary` 消息渲染 `NewPiMarkdownText`（`NewPiApp/NewPiMarkdownText.swift`），它内部走 `NewPiMarkdownWebRendererView`。

2. **每个 WebView 都是全新配置，无共享进程池**
   - `NewPiApp/NewPiMarkdownWebRendererView.swift` 的 `makeNSView` 每消息 `WKWebViewConfiguration()` 新建，`websiteDataStore = .nonPersistent()`，`userContentController.add(...)`，**没有共享 `WKProcessPool`**。
   - ⇒ N 条消息 ≈ N 个 WebKit 内容进程的内存/句柄开销。

3. **切 Session 时整棵消息视图树销毁重建**
   - 切会话 → `activeRuntime` 切换 → `reflectActive()` 将 `@Published transcript` 整体替换（`NewPiApp/NewPiViewModel.swift`）→ SwiftUI `ForEach` 按 `.id(item.id)` 全部失效 → 每条消息重新 `makeNSView`。此时：
     - 重新执行 `webView.loadHTMLString(...)`（`NewPiMarkdownWebRendererView.swift` 的 `loadInitial`）
     - 重新加载 HTML、重跑 markdown-it + highlight.js
     - 经 JS 回调重新测高（`webHeight` 从 0/44 起步 → 真实高度），造成渐进高度修正闪烁
     - 滚动位置未记录 → 丢失

4. **为什么用户感知"重新加载"**：因此每次切到未保活的会话，所有消息的 WebView 都冷启动一轮，慢且视觉跳动。

---

## 三、业界参考方案

| 做法 | 代表 | 要点 |
|---|---|---|
| 布局/渲染结果随数据缓存 | Telegram macOS | 每条消息的布局对象在数据入库时算好并随消息模型缓存；切会话只是把缓存布局绑定到复用 cell，不存在"解析"动作 |
| 视图保活 | Safari | WKWebView 只要不销毁，DOM/布局/滚动偏移全部保留，重新挂回窗口是瞬时的 |
| model/view 严格分离 | VS Code | 文本模型独立于视图存活；切 tab 只是把视图指向已有模型 + 恢复 view state |
| 进程池共享 | 多 WebView 应用 | 共享 `WKProcessPool`，消除每消息一个 web 内容进程 |
| 原生文本渲染 | —— | `NSAttributedString` + TextKit 2，KB 级缓存，非连续布局只渲染可见区（长期终态，见文末） |

---

## 四、选定方案（三级递进）

> 目标：**任意会话切换都"秒显示"；常切会话原位恢复；被淘汰会话用位图兜底。** 保留现有 Markdown 观感。

### ① 共享 WKProcessPool + 每消息高度/HTML 缓存（基础，必做）
- 把 `makeNSView` 里每消息新建的配置改为**共享一个配置**（共享 `WKProcessPool`），消灭每消息一个 web 进程的内存/句柄开销。
- 每条消息缓存**渲染后的 HTML + 实测高度**；冷重建时第一帧即用缓存高度，避免 0→真实高度的渐进测高闪烁。
- 收益：内存大降、冷加载更快；是放宽保活数量上限的前提。

### ② 会话视图保活 + LRU（上限 5）
- 把最近若干个会话的整个聊天面板（`ScrollView` + 全部 WebView）**保活**，切换 = 翻转显示/透明度。
- 收益：保活名单内的会话**零重载**，DOM、测高、**滚动位置全部免费保留**。
- 实现要点：
  - 隐藏视图用 `.opacity(0)` 保持真实 frame；**不要**用 `.hidden()` 或零尺寸（WKWebView 会停止渲染/加载）。
  - 后台会话的流式渲染暂停：事件循环继续收数据但不喂 WebView，切回时一次性 flush。
  - LRU 上限：**5**，超出按最久未使用淘汰；上限值可调（共享进程池后内存可控）。
  - 内存随保活会话数线性增长，因此必须配套 ① 的进程池共享。

### ③ 快照兜底（被淘汰会话）
- 切走时对会话面板 `takeSnapshot` 存位图；切回被淘汰的会话时**先瞬间显示位图**，后台异步水合活视图后再交叉淡入。
- 收益：弥补 ② 的 LRU 上限——切到未保活的第 6+ 个会话也是秒开一张静态位图，不再是空白转圈。
- 代价：Retina 下全屏快照约 10–30MB/张，快照缓存个数有限（对应 LRU 淘汰深度）；位图是静态的、不能选择文本。

---

## 五、落地步骤（实现顺序）

1. **① 进程池共享 + 高度/HTML 缓存**（`NewPiMarkdownWebRendererView.swift`）—— 改动小、可独立验证。
2. **② 会话保活 + LRU 上限 5**（`NewPiViewModel` + `NewPiChatView` + 会话面板管理）—— 核心重构。
3. **③ 快照兜底**（切走存快照 → 切回先显示快照再水合）。

每一步完成后 `xcodebuild` 验证编译；全部完成后人工点击测试切会话体验。

---

## 六、内存与权衡 / 风险

- **保活 + 进程池**：内存随保活会话数增长，配合共享进程池后增幅放缓；上限 5 为初值，可按实测内存调整（3–8）。
- **快照内存**：只缓存最近若干张，LRU 淘汰。
- **视觉回归**：①②③ 均**不改渲染引擎**，Markdown 预览观感不变——这是选这条路而非"原生 TextKit 2"的关键原因。
- **长期终态（未纳入本轮）**：原生 `NSAttributedString` + TextKit 2（方案四）可把"每消息一个 WebView"的进程/显存负担彻底去掉，设为长期独立升级项；因工作量大、且需替换渲染引擎（代码高亮、块级样式、测高、交互），易造成视觉回归，本轮不做。
