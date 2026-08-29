# 渲染产物重放方案（Render-Once, Replay-Forever）

> 本文档记录「会话切换/冷加载不再重新渲染」的最终方案：动静分离 + 渲染产物持久化。
> 上游设计史：[`session-switch-instant-resume-plan.md`](./session-switch-instant-resume-plan.md)（高度缓存/保活/快照三级方案）、
> [`dev-notes/2026-08-28-streaming-markdown-rendering-context.md`](./dev-notes/2026-08-28-streaming-markdown-rendering-context.md)（单引擎流式渲染）。

---

## 一、需求定稿（与用户对齐，2026-08-29）

| # | 需求 | 强度 |
|---|---|---|
| R1 | 切换会话零重载、直接展示最终结果 | 强（切换频繁） |
| R2 | 快速定位到任意消息（rail 跳转 + 恢复原滚动位） | **强需求** |
| R3 | 渲染观感逐像素一致（历史/活跃无差别） | 强 |
| R4 | 活跃消息流式渲染体验（块级增量 + ✦ 光标）不变 | 强 |
| R5 | 揭示后滚动条高度稳定，不再"越滚越短" | 中（本方案应结构性消解） |
| R6 | 不可急切全量挂载 WKWebView（内存/WebContent 白屏防线） | 硬约束 |
| — | 暗色模式 | 暂不需要 |
| 规模 | 几十条消息/会话 | 关键前提 |

用户明确接受**动静分离**：历史消息可以直接展示渲染产物而不必重新渲染，
渲染结果（HTML + 高度）作为数据单独持久化，供之后切换展示。

## 二、为什么不是全原生（方向 B 对比结论）

效果维度上，R3「逐像素一致」只有重放能结构性满足（同引擎、同 CSS、同一份 HTML 输出）；
全原生（TextKit 2 / SwiftStreamingMarkdown）只能无限逼近 markdown-it + hljs 的观感，
且需重做流式解析、样式体系、代码块 UI、测高管线（周级），并重新经历滚动/跳变踩坑史。

全原生唯一不可替代的效果优势是**跨消息文本选择 / Cmd+F**（WebView 每消息一个选择域）。
当前判为可接受取舍。方向 B 保留为长期选项，触发条件：① 会话规模涨到几百条以上；
② 跨消息选择升级为强需求。

## 三、方案

**动静分界线**：流式中/刚完成 = 动（现有单引擎块级增量渲染，不动）；
flush 完成 = 产物落盘，此后**永远重放、不再解析**。

```
消息 flush 完成时：
  JS 把最终渲染产物 root.innerHTML（剥掉终态光标）经 messageHandler 回传
  → Swift 持久化到渲染产物缓存：{ 内容SHA256, 宽度桶, 引擎指纹 } → { finalHTML, 实测高度 }

会话切换/冷打开时（非流式行）：
  命中缓存 → 加载「重放文档」：article 内联预填产物 HTML + window.replayRendered()
  → 不跑 markdown-it 解析、无块级增量、无尾部修复、无光标
  → 首帧高度 = 缓存高度（准确值，非估算）→ 滚动条一次到位（R5 消解）
  → rail 跳转/原位恢复从"追赶变化高度"变成纯算术（R2）
```

### 缓存设计（扩展现有 `MarkdownRenderingCache`）

- key：`SHA256(markdown)` + 宽度桶（沿用现有分桶），**全局跨会话共享**
  （fork/分支/同内容消息天然命中，用户已确认）。
- value：`{ height, html, engine, lastAccess }`，追加进现有
  `~/.new-pi/agent/markdown-height-cache.json`（字段可选化，v2 文件无损升级）。
- **引擎指纹**：`MarkdownRenderer/` 目录资源（js/css）内容哈希。
  渲染器或样式一变，指纹变 → 旧产物整体 miss → 回落正常渲染并重新捕获。
  这是"可能改变渲染结果的因素"的通用兜底（用户答不上来的部分由此机制覆盖）。
- LRU 与防抖持久化沿用现有实现。

### 重放路径

- `NewPiMarkdownWebDocument.replayDocumentHTML(renderedHTML:)`：同一 CSP、同三份 CSS，
  body 内 `<article>` 预填产物；仍加载 markdown-it/hljs/markdown-renderer.js
  （JS 顶层依赖 markdown-it 全局实例；本地文件加载开销可忽略），引导脚本调用
  `window.replayRendered()`。
- `replayRendered()` 只做三件事：重绑代码块复制按钮/链接拦截（innerHTML 重放
  不保留事件监听）、挂 ResizeObserver、强制上报一次高度（幂等写缓存）。
- 安全性：产物本身是 markdown-it `html: false` 的输出（用户输入已转义）；
  CSP `script-src` 无 `unsafe-inline`，产物中即便混入内联脚本/事件属性也不执行。
- **交互豁免**：重放行与正常行完全一致地参与滚轮转发、rail 上报、就绪门控。

### 渐进迁移

历史消息首次切回时缓存里只有高度没有 HTML → 走正常渲染一次并捕获产物，
之后永远重放。无需迁移脚本，体验逐会话自愈。

### 对现有机制的处置

- **高度缓存**：保留并升级（并入产物缓存），首帧高度语义不变。
- **保活 LRU5**：保留（热路径零成本）。
- **就绪门控 / Preheater（7554710）**：保留但职责收窄——只服务 cache-miss
  （首见内容）场景；命中产物缓存的会话首帧即正确，门控瞬时通过。
  后续实测若确认 miss 场景稀少，可考虑移除预热器（待议）。

## 四、落地步骤

1. ✅ 工作区清理：门控/预热器作为独立 commit 落盘（`7554710`），后续改动可对照。
2. 缓存层：`Entry` 增加 `html/engine`，`snapshot(for:)` / `setSnapshot(...)`，引擎指纹计算。
3. JS：最终渲染后回传产物（`renderedSnapshot` 通道，剥光标）；新增 `replayRendered()` + 复制按钮/链接重绑。
4. Swift：`replayDocumentHTML`；`loadInitial` 命中产物时走重放文档；Coordinator 接收产物写缓存。
5. 每步 `xcodebuild` 验证；全部完成后人工实测：切会话秒开、滚动条稳定、rail 精确跳转、复制按钮可用。
6.（后续，R2 收尾）被淘汰会话的"锚点消息 ID + 行内偏移"原位恢复——高度已准确，轻量可做。

## 五、风险与边界

> **实现与调试全记录**：见 [`dev-notes/2026-08-29-render-replay-windowing-scroll-restore.md`](./dev-notes/2026-08-29-render-replay-windowing-scroll-restore.md)（含窗口化、锚点恢复与设计原则 P1–P5）。

- **产物 HTML 体积**：每条消息几 KB，几十条/会话规模下磁盘占用可忽略；LRU 2048 条上限兜底。
- **窗口 resize**：宽度变 → 桶切换 → 产物 miss → 回落正常渲染重捕获（与现有高度缓存同策略）。
- **重放失败**：看门狗/进程终止等现有防线照旧；失败行退回原生文本兜底并写日志。
- **流式中的消息**永不重放（无产物或产物过期即正常渲染），单引擎流式路径完全不动。
