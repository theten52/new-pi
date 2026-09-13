# 完全 Swift 原生 UI 技术路线评估

> 评估日期：2026-09-14。
> 结论：当前没有必要全面去掉 WebView，继续采用 SwiftUI／AppKit 外壳 + 单文档 WKWebView 正文。
> 本文基于当前源码与已有复盘，不包含新一轮性能测量或原生对照原型。
> 这是路线评估，不是迁移实施计划，也不新增性能缺陷或待办；当前渲染决策仍以
> [UI 架构 ADR](ui-architecture-decision.md) 为准。

## 1. 评估范围与当前分工

本文的“完全原生”指正文也不使用 HTML／JS／CSS，改由 SwiftUI 或 AppKit／TextKit 展示，
不是要求系统框架的内部实现全部使用 Swift，也不等同于“所有 UI 都必须使用 SwiftUI”。

当前项目不是套壳 Web 应用：

| 层次 | 当前实现 | 全面原生化的新增收益 |
|---|---|---|
| Agent loop、provider、工具与会话存储 | Swift 核心包 | 已经原生，无需迁移 |
| 窗口、导航、侧栏与交互外壳 | SwiftUI／AppKit | 已经原生 |
| 输入框、输入法处理与附件选择 | NSTextView／AppKit | 已经原生 |
| 会话正文、代码块、随文工具与审批卡 | WKWebView + 本地渲染资源 | 真正需要重写的部分 |

源码入口：

- [Package.swift](../Packages/NewPiCore/Package.swift)、
  [AgentLoop.swift](../Packages/NewPiCore/Sources/NewPiCore/AgentLoop.swift)：Swift 核心包与执行循环。
- [NewPiChatView.swift](../NewPiApp/NewPiChatView.swift)：会话面板与基于 NSTextView 的 `NewPiComposerTextView`。
- [NewPiTranscriptDocumentView.swift](../NewPiApp/NewPiTranscriptDocumentView.swift)：单文档宿主、内容投递与原生交互桥。
- [NewPiMarkdownWebRenderer.swift](../NewPiApp/NewPiMarkdownWebRenderer.swift)：本地 HTML 外壳与资源加载。

WKWebView 是系统组件，不是随 App 打包一整套 Chromium。Markdown 与高亮资源已经本地加载，
离线与不依赖 CDN 不需要靠重写才能获得；这也不表示所有渲染风险自动消失。

## 2. 去掉 WebView 的实际收益与边界

潜在收益包括：

- 减少 Swift ↔ JS 的序列化和异步桥接。
- 去掉 WebContent 生命周期与特定 WebKit 布局兼容问题。
- 让正文交互更直接地接入 AppKit 菜单、焦点、文本服务与辅助功能体系。
- 多会话场景可能降低内存，但收益幅度必须通过同场景对照确认。

当前源码中仍存在以下成本：

| 机制 | 当前依据 | 能得出的结论 |
|---|---|---|
| 全历史遍历与活动正文投递 | `Coordinator.applyLoaded` 每批遍历条目，更新条目的完整正文进入 ops，`send` 编码后交给 JS | 规模增长可能增加 diff、编码与 IPC 成本，不等于已经证明其是体验主瓶颈 |
| 当前 Markdown 全文解析 | `markdown-renderer.js` 的 `splitBlocks` 调用 `markdown.parse`，之后 `renderStreaming` 复用稳定 DOM | 增量 DOM 不等于增量解析；当前长回答仍有随长度增长的解析成本 |
| 文档内滚动与占位校正 | `transcript-document.js` 的 `Poller`、`Warmer`，以及 CSS 的 `content-visibility` | 为长文档布局稳定性维护了额外逻辑 |
| 多会话保活 | `NewPiChatView` 保留多个面板；`NewPiViewModel.evictIdleRuntimesIfNeeded` 按 LRU 淘汰空闲 runtime | 内存随保活内容增长；生成中或等待审批的 runtime 不作为普通空闲条目淘汰，因此缓存目标不是绝对硬上限 |

对应实现：[原生桥](../NewPiApp/NewPiTranscriptDocumentView.swift)、
[Markdown 渲染器](../NewPiApp/MarkdownRenderer/markdown-renderer.js)、
[文档控制器](../NewPiApp/MarkdownRenderer/transcript-document.js)、
[文档样式](../NewPiApp/MarkdownRenderer/transcript-document.css)、
[运行时管理](../NewPiApp/NewPiViewModel.swift)。

这些机制说明有成本，但不能推出“换成 SwiftUI 就会更快”。全文解析、动态高度、
状态传播和长列表布局在原生路线中同样需要处理。已有
[长会话性能复核](dev-notes/2026-09-11-long-session-rendering-review.md) 的历史实验
只对记录的版本与场景负责，不能代替当前版本的端到端归因。

## 3. 迁移成本：功能与体验等价

当前正文不仅显示文字，还承担语义分块、流式尾部修复、代码高亮、稳定前缀复用、
折叠详情、随文审批、复制、附件、锚点恢复和 minimap 定位。替换后需要重新保证这些能力协同工作，
并保持流式增量进入易失展示态、消息边界才提交正式 transcript 的约定。

| 原生路线 | 优势 | 主要难点 |
|---|---|---|
| SwiftUI 分块／消息列表 | 原生组件与按钮易组合 | 跨块文本选择、动态高度保锚、大量流式更新、复杂 Markdown 排版 |
| AppKit／TextKit 文档视图 | 连续文本选择、文本系统集成更自然 | 表格、代码区域、交互卡片、附件布局、增量文本范围维护 |

`Text(AttributedString(markdown:))` 不是当前渲染器的等价替代。引入 Markdown 库也只是解决解析
或部分展示，不能自动解决整条 transcript 的滚动、交互和生命周期。

若未来需要原生对照原型，优先评估“SwiftUI 外壳 + AppKit／TextKit 正文”，而不是要求所有内容
都由 SwiftUI 绘制。这是候选方向，不是已经证明更优的实现方案。

当前已经消除了旧架构中最危险的边界：不是每条消息一个 WebView，再把内容高度传回原生布局，
而是整个文档自己管理布局与滚动。旧原生高度表、逐消息 WebView、原生预热路径已删除；
文档内 Warmer／Poller 不是旧路径残留。不能以旧高度桥的问题作为今天必须去掉 WebKit 的理由。
单文档也只为跨消息选择和全文查找提供基础条件，不代表这些体验已全部验收。

## 4. 重新评估迁移的触发条件

以下条件之一成立时，才值得认真考虑迁移：

1. **性能硬指标持续不达标**：真实长会话、多会话内存或流式响应超过预先确定的预算，
   且剖析确认主要成本来自 WebKit／桥接，局部优化收益有限。
2. **产品方向变成编辑器**：正文需要大量原位编辑、原生文本操作或复杂键盘交互，
   不再以只读富文本阅读为主。
3. **系统集成成为核心门槛**：明确的 VoiceOver、焦点或文本服务要求，
   在现有文档方案下反复无法可靠满足。
4. **团队存在明确维护约束**：长期无法维护 JS／CSS，并愿意承担原生富文本实现与回归成本。
   统一语言有价值，但不等于减少总复杂度。

“纯 Swift 应该更轻、更快、更 macOS”本身不足以支持重写。

## 5. 当前建议

继续现有混合路线，不启动全面迁移。优先测清长正文解析、全历史 diff／编码、
多 WebView 保活的实际成本，再按证据决定是否局部优化；不把本节建议自动转成已确认缺陷或实施承诺。

若未来确实触及硬限制，再使用同一批流式、冷恢复和复杂 Markdown 样例，制作功能受限的原生
对照原型，同时比较性能、内存、选择／复制、滚动恢复和交互能力。以实测收益与功能等价程度
决定是否替换，避免在没有明确退出条件的情况下长期维护两套生产渲染器。
