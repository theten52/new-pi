# 单文档 Transcript Spike 结果

> 日期：2026-08-30 · 分支：`feat/ui-arch-rework` · 机器：本机 macOS 15（Darwin 24）
>
> 决策闸门定义见 [`../ui-architecture-decision.md`](../ui-architecture-decision.md) §4.2。
> 测量工具：`NewPiApp/NewPiSpikeTranscriptView.swift`（菜单 Help → UI Architecture Spike，
> 或 `NEWPI_SPIKE_AUTORUN=1 NEWPI_SPIKE_TURNS=N` 无人值守运行，结果写 `/tmp/newpi-spike-N.log`）。

## 结果

| 指标 | 标准 | 200 turns | 500 turns | 判定 |
|---|---|---:|---:|:--:|
| M1 冷挂载首屏可读（cold = markdown 全量渲染） | < 500ms | 115ms | 185ms | ✅ |
| M1 同上（replay = 预渲染 HTML 直出，模拟产物重放） | < 500ms | 21ms | 60ms | ✅ |
| M2 流式每帧渲染耗时（尾块**全量重渲染**，保守上界） | < 8ms | p50 1 / p95 3 / max 4ms | p50 2 / p95 4 / max 4ms | ✅ |
| M3 WebKit 进程内存增量（phys_footprint，对空 WebView 基线） | 可接受 | +58MB | +87MB | ✅ |
| M4 全程匀速滚动（6s 扫过全文档） | 无明显掉帧 | 75fps / 0% 掉帧 | 75fps / 0% 掉帧 | ✅ |

文档规模参照：500 turns ≈ 19k DOM 节点、462k px 文档高度。
`content-visibility: auto` + `contain-intrinsic-size` 的虚拟化生效（滚动零掉帧的直接原因）。

**结论：GO。** 满足决策文档 §4.2 的全部预先承诺标准，且 M2 是在比生产实现
（`renderStreaming` 块级增量）更差的算法下测得的——生产只会更快。

## 测量方法备注（可复现性）

- 合成数据：短提问 + thinking + 1~4 张工具卡 + 代码密集型 markdown 回答，
  分布贴近 coding agent 真实负载；非真实会话数据（局限，见下）。
- M2 测的是 Web 进程内 JS 渲染耗时——这正是单文档架构的论点所在
  （渲染在 Web 进程，App 主线程不被占用）；流式期间页面 rAF 维持 75fps。
- M3 归因方式：WebKit 进程由 launchd 孵化（ppid=1），用 responsibility API
  （无公开头文件、符号导出，top/powermetrics 同款）归属过滤；
  从终端启动时责任归终端 App（实测归 Warp），采样函数已兼容两种归因。
  采样有噪声（流式后 WebKit 回收内存，读数回落），仅作量级参考。
- **未直接对比当前实现同等会话的内存**（当前实现窗口化后 WebView 数量受控，
  但每个 WebContent 进程固定成本高）。绝对值 +87MB @500 turns 判断为可接受。

## 局限（诚实清单）

1. 合成数据，非真实长会话；真实会话的代码块更大、工具输出更长，建议 Phase 1 用真实会话复测。
2. 滚动为程序化匀速扫滚，非触控板惯性滚动。
3. 未测会话切换（换文档内容 + 恢复 scrollTop）——Phase 2 的验收项覆盖。
4. 未测 WebView 单点崩溃恢复（对策：replay 产物重建 + scrollTop 恢复，Phase 1/2 实现）。

## 对迁移排期的影响

按决策文档 §4.3 进入 Phase 1（文档外壳 + 渲染迁移，feature flag 并行）。
三个已识别的实现要点不变：

1. `markdown-renderer.js` 的 IIFE 单例状态（renderedBlocks / lastPostedHeight / 光标 id）
   需改为 per-turn 实例。
2. JS 滚动模块手写锚定（`overflow-anchor` 不可用，算法同 osaurus ScrollAnchorManager）。
3. 工具卡折叠不用原生 `<details>`（Safari 18.0 content-visibility 回归）。
