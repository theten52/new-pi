# Transcript 滚动跳变：根因、三轮方案与最终修复

> 日期：2026-08-30
> 状态：已修复并实测确认
> 涉及文件：`NewPiApp/MarkdownRenderer/transcript-document.js`、`transcript-document.css`
> 相关提交：`23a8817`（v1，无效）→ `f2ef59c`（v2，更糟）→ `b8ae989`（v3 方向正确）→ `b1825af`（收尾）

## 1. 问题现象

单文档 transcript（整条会话渲染进一个 WKWebView）下，用户滚轮向上翻看历史时，
页面会「冷不丁跳到另一个位置」。后续两轮迭代分别出现：修复无效、以及更糟的
「小范围频繁跳动」。最终修复后，仅「长会话打开头几秒内」残留短暂跳动，收尾后全部消失。

## 2. 根因

transcript 用 `content-visibility: auto` 做虚拟化：视口外条目跳过布局/绘制，
以 `contain-intrinsic-size` 的**估算高**占位（answer 480px、user 64px、卡片 48px）。
条目滚近视口时异步解析出**真实高度**（长回答可达数千 px），差值让文档在
scrollY 不变的情况下整体平移。

两个平台前提使问题无解于「常规手段」：

1. **WebKit 没有 scroll anchoring**（`overflow-anchor` 实测不支持）——Chromium 遇到
   这种布局平移会自动锚定视口内容，WebKit 不会。
2. **WebKit 的 content-visibility 占位高↔真实高切换不触发 ResizeObserver**
   （Playwright WebKit 26.5 探针：滚动 30 次收到 0 个 RO 事件；Chromium 正常）。

## 3. 三轮方案与失败原因

### v1：ResizeObserver 补偿（`23a8817`）——WebKit 下完全无效

思路：RO 监听条目高度变化，视口上方条目变高多少就 `scrollBy` 抵消多少。
在 Chromium（ego-browser）上测试全绿，但真机无效——**RO 根本不触发**（见上）。
教训：Chromium 通过不等于 WebKit 通过；ego-browser 是 Chromium 内核，
验证 WebView 行为必须用 Playwright WebKit 或真机。

### v2：锚点文档位置 − scrollY 帧间差分看门狗（`f2ef59c`）——真机更糟

思路：rAF 逐帧比对「视口锚定条目的文档位置」，把不能被 scrollY 变化解释的
位移判为布局平移并 `scrollBy` 抵消。
真机表现为**小范围频繁跳动**：macOS 触控板/滚轮是**异步滚动**（合成线程驱动），
rAF 里读到的 scrollY 与真实视觉位置有帧延迟，差分把**滚动本身**误判为平移 →
补偿打断惯性 → 下一帧再误判 → 反馈振荡。
教训：**滚动补偿的输入信号必须是「内容几何变化」本身，绝不能混入 scrollY 差分**；
且 Playwright 合成 wheel 走主线程同步滚动，复现不了异步滚动问题。

### v3 + 收尾：Poller + Warmer（`b8ae989` → `b1825af`）——最终方案

**Poller（滚动中，兜底）**
- 滚动活跃期（wheel/scroll/按键激活，停后延 500ms）逐帧轮询「视口上方 3 屏内」
  条目的 `offsetHeight`，**变了多少就 scrollBy 多少**。
- 补偿量直接量自高度变化这个根源，与 scrollY 完全解耦——高度没变就不产生任何
  滚动写入，结构上不存在反馈环。
- 除 rAF 轮询外，还在 **scroll 事件处理器里直接轮询一次**：scroll 事件在当帧
  布局后、绘制前分发，可同帧抵消，避免 rAF 晚一拍留下单帧闪动。
- pinnedBottom / jumpingToTarget / restoringAnchor 意图下让权（滚动权归意图逻辑）。

**Warmer（空闲时，源头消除）**
- 空闲时把未固化的条目按「距视口由近及远」逐个强制渲染（`content-visibility: visible`），
  真实高度写入 inline `contain-intrinsic-size`，再归还 CV 调度——之后滚出/滚入
  视口时占位高=真实高，平移从源头消失。
- 每个 chunk（10 条）用批次锚定纪律保护视口（高度变化与锚点恢复同一同步块）。
- `setTimeout(0)` 连续推进（rIC 在 WebKit 触发太慢）；用户主动滚动/跳转时让路；
  流式中条目跳过（流结束后入选）；折叠卡展开/收起后重新预热。

**收尾发现**（用户实测「头几秒跳动」）：restoreAnchor 的 3 秒校正窗口内 Warmer
原本让路 → 预热恰在用户最可能开始滚动的头几秒停摆。恢复 RAF 每帧都在校正锚点，
与预热批次同纪律，**允许预热在恢复窗口内并行**即可。

## 4. 验证方法（可复用）

Playwright WebKit（真内核，`npx playwright install webkit`），harness 直接加载
真实的 `transcript-document.js/css` + markdown-it/highlight 本地资源。

**指标的正确性比工具更重要**，前两次都栽在指标上：

| 错误指标 | 为什么错 |
|---|---|
|  scrollY 的非预期变化 | 平移发生时 scrollY 不变，测不到；补偿时 scrollY 正常变化，误报 |
| 锚点元素 Δtop + ΔscrollY | 恒等于 ΔdocTop（恒等式），测的是内容位移而非视觉跳变 |

**正确指标：可见跳变帧 = 无滚动（dy=0）的帧里，锚定元素屏上位移 |dt| > 15px**。
辅以对照组（`content-visibility: visible` 关闭虚拟化）确认根因归属。

最终三场景全零跳变：恢复窗口内立刻快速上滚 / 延迟后上滚 / 上→下→上混合滚动。

## 5. 经验清单

1. **Chromium ≠ WebKit**：RO 行为、scroll anchoring、异步滚动差异巨大；WKWebView
   的问题必须用 WebKit 验证（Playwright WebKit 是性价比最高的方式）。
2. **合成输入 ≠ 真实输入**：CDP 合成 wheel 是主线程同步滚动，复现不了触控板
   异步滚动 + 惯性的反馈问题。
3. **scroll 补偿信号必须与 scrollY 解耦**：凡是用 scrollY 差分推导「内容平移」的
   方案，在异步滚动平台上都会自激振荡。
4. **优先从源头消除（固化真实高度），补偿只做兜底**：补偿再精确也有帧级时序风险；
   占位高=真实高之后，补偿路径自然闲置。
5. **调度窗口要对着用户时间线检查**：恢复窗口（3s）恰好覆盖用户最可能开始滚动的
   时刻，「让路」逻辑要看语义冲突而非一刀切。

## 6. 遗留边界

- 未固化条目的解析理论上仍可能有**单帧**残差（16ms 级），实测已低于可感知阈值；
  若未来出现，方向是扩大 Poller 窗口或在 scroll 事件外再挂 `scrollend` 前 poll。
- 窗口 resize 改变条目宽度 → 高度变化不在 Poller 轮询路径上（resize 时通常不在
  滚动中）；如遇到可再加 resize 事件触发预热重刷。
