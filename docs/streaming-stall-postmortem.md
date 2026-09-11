# 流式输出卡顿——根因复盘与修复（STALL-VERIFY）

> 2026-09-07。记录「agent 输出卡顿」从 8 月底首次出现、被缓解、9 月初复发、
> 多轮渲染向修复无效，到最终用双通道看门狗 + 采样定位根因并修复的完整过程。
> 修复见 `debug/stall-verify` 分支 `8d7eb5c`。本文所有结论均有日志/采样实证。

> **2026-09-11 后续修正**：上述措施没有消除全部原生呈现等待。新的 200 行回放在加入真实
> 状态栏后复现同一 RenderBox/CA 等待栈，持续 `symbolEffect(.pulse)` 被 A/B 确认为触发点。
> 移除图标 pulse、保留文字呼吸后该等待栈消失；这不是仅发生于 Debug 注入的现象，
> 因为脱离调试器的回放也能复现。详见
> [长会话性能复核 §13](./dev-notes/2026-09-11-long-session-rendering-review.md#13-200-行卡顿的触发点修复与受控验收)。

## 一、问题现象

流式输出期间 UI 出字卡顿、暂停；LLM 流早已结束，界面还在缓慢「涌字」，
最坏时流式 30s 的内容要等 100~160s 才显示完（run wall time 164s vs 流式 28s）。
「滚动一下能续上一点」的错觉随之而来（滚动触发的事件泵恰好让出主线程）。

## 二、时间线

| 时间 | 事件 |
|---|---|
| 08-27 | `162af16` 流式输出增量合并 + 轻量渲染（首次治理） |
| 08-29 | `ccbb69e` 主线程治理：sample 发现「~44% 时间阻塞在渲染提交的 CA 表面分配同步，单次 0.5~1s，最高 20s+」；40ms 自适应节流把 wall time 272s 降到 ≈流式时长。**当时认为已解决** |
| 09-03 起 | 聊天室分支开发，用户全程用 Xcode Debug 构建测试 |
| 09-06 | 卡顿「复发」，多轮渲染向修复（`d6edcd6`：Warmer 门控、节流 200ms、流式布局隔离、paint-gate、高度步进）**全部无效** |
| 09-07 | STALL-VERIFY 排查：双通道看门狗 + sample + 序号探针，定位根因，修复并实测 |

## 三、排查过程（方法论记录）

关键设施（都在 `debug/stall-verify` 分支，可复用）：

1. **双通道看门狗**（`NewPiApp.swift` MainRunloopWatchdog）：
   - CFRunLoop Timer（.common 模式）每 0.5s 打点测 **runloop 可用性**
   - `Task { @MainActor }` sleep 探针测 **MainActor executor 调度延迟**
   - 60s 心跳证明看门狗存活（无报警时可区分「真不卡」与「看门狗没跑」）
2. **序号对齐探针**：AgentSession broadcast 端与 UI 消费端各记 textDelta 序号
   （每 100 个一条），同序号两端时间差 = 投递/调度延迟
3. **边界事件 hopLag**：边界事件从入队到 MainActor 实际执行的滞后——
   直接度量主线程可用性
4. **sample 主线程**：卡顿窗口内抓栈
5. **构建配置对照矩阵**：Xcode Debug / 直执行 Debug ± MTL_DEBUG_LAYER / Release

### 排查中的关键转折

- 日志里 923 条 `UI event loop stall`，textDelta gap 最大 41s，avg 3.6s
- 但 flush 合并 0ms、JS DOM apply 1~6ms、provider→broadcast 全速——
  **每一环都便宜，钱不知道花在哪**
- 看门狗第一次给出反直觉结果：runloop 准点、主线程 sample 里 99% 停在
  mach_msg 空闲态，MainActor 却延迟 5~30s——看似「主线程空闲但任务饿死」
- **真相**：sample 抓到主线程其实在 `CA::Context::synchronize →
  wait_for_synchronize → mach_msg` 里同步等待；CA 的等待会嵌套泵 runloop，
  common 模式的看门狗 Timer 照常触发，把阻塞掩盖了。
  教训：**runloop 定时器准点 ≠ 主线程空闲**。

## 四、根因（完整因果链）

```
流式期间每次渲染提交（WKWebView 内容变化 → SwiftUI UpdateCycle）
  → CA::Transaction::commit
    → RBLayer display（RenderBox，WKWebView 远程图层宿主）
      → SharedSurfaceGroup::add_subsurface
        → wait_for_allocations → CommitMarker::test_displayed
          → CAContext waitForCommitId → CA::Context::synchronize
            → wait_for_synchronize → mach_msg（主线程同步阻塞，单次数秒~20s+）
```

主线程被秒级阻塞时，挂在 MainActor 上的事件消费循环（每事件一次 hop，
流式 100+ delta/s）消费速度 << 生产速度，`AsyncStream` 无界缓冲把债务攒住，
流结束后排空数分钟——这就是卡顿。**缓冲合并、JS 渲染、网络全链路无罪。**

### 放大器（按贡献排序）

1. **Debug 构建 + Metal API Validation**：`MTL_DEBUG_LAYER=1` 实测把单次提交
   成本放大 ~4 倍（同一 Debug 二进制：开 validation 排空 163s，关 42s）。
   Xcode 直跑默认还叠加 debug dylib 注入，最坏（100~164s）
2. **并发产 surface 的 WebView 数量**：保活面板（opacity 0）里的后台会话
   流式时仍全速渲染；多会话并发/连发时 render server 确认延迟叠加
3. **启动冷渲染风暴**：恢复长会话（36+ 条）后立即发消息，冷渲染的 CA 提交
   与首个 run 的流式叠加，第一轮就欠 15s+
4. **逐条 thinkingDelta DEBUG 日志**：每条日志的内存存储要做一次 MainActor
   hop，思考阶段 100 行/s，本身就是卡顿源之一（修复中已移除）

### 与 8 月底「已解决」的关系

`ccbb69e` 的修法是**减少提交次数**（40ms 自适应节流），在当时的每提交成本
（Release 下亚秒级）下够用。9 月「复发」是因为测试环境切到了 Xcode Debug
构建（Metal validation 把每提交成本放大到秒级），同样的提交频率再次打爆。
**不是聊天室分支的代码回归**——聊天室全部 30 个提交经逐行核对与实测排除，
Session 流式渲染主链路在 main..feat/chatroom 间实质零变化。

## 五、修复（`8d7eb5c`）

**事件消费移下 MainActor**——让事件流不再依赖主线程可用性：

- `startRuntimeEventLoop` 从 `Task { @MainActor }` 改 `Task.detached` 后台消费
- 新增 `StreamingDeltaBuffer`（锁保护、Sendable，正文/思考双通道）：
  delta 在后台**实时合并**，仅脏标记 false→true 时 poke 一次 MainActor
  调度节流 flush（MainActor hop 从 100+/s 降到 ≈flush 频率 25/s）
- 边界事件（messageStart/tool/agentEnd…）仍逐条 hop MainActor；
  `handle()` 入口先 drain 缓冲——**内容顺序严格不变**
- 原逐事件的状态迁移（`agentActivity=.writing`、`streamingBubbleComplete=false`、
  token 速率）移到 flush 按节流节奏执行（@Published 同值去重，UI 行为不变）
- 移除逐条 thinkingDelta DEBUG 日志
- 诊断口径：stall 日志改为边界事件 hopLag；run wall time 改接收侧口径
  （=真实流式时长）

修复后的行为语义：主线程被渲染提交卡住时，事件在后台照收并合并；
主线程一空闲就把累积内容一次画上。观感上限从「卡几分钟」变成
「卡一下、涌一段」。

## 六、验证

| 环境 | 修复前 | 修复后 |
|---|---|---|
| Xcode Debug（validation+注入） | 流式 23~28s → 排空 100~164s | — |
| Debug 直执行 MTL_DEBUG_LAYER=1 | 排空 163s | **流式 17s → 同秒完成，零 stall** |
| Debug 直执行 MTL_DEBUG_LAYER=0 | 排空 42s | — |
| Release 单次稳态 | 0s（本就正常） | 0s |
| Release 压力场景（启动+连发+多会话） | gap 最大 26s、wall 132s | 同场景实测无积压 |

其它验证：bcast/consumed 序号两端时间戳逐对对齐（生产→后台消费零延迟）；
150 行长文完整渲染（截图）；token 速率/状态栏正常；`swift test` 180 全过。

## 七、钉底回归（PIN-FIX `74663c8` + PIN-FREEZE `aad8608`）

STALL-FIX 合入后用户反馈「输出钉到底部」失效。最终定位到**三层叠加**，
前两层是意图管理漏洞，第三层才是用户看到「完全没效果」的主因：

1. **钉底意图空窗期不受保护**：发送时 `scrollToBottom` 置 `pinnedBottom`，但
   流式首批 `forkLock` 要数百毫秒后才到。空窗内拖拽误判（>150ms 无程序滚动即
   视为用户接管；scroll anchoring 布局微调也走 scroll 事件）与 `onScrollSettled`
   的「未近底即降级」都可能误贬意图，且无任何重新武装机制。修复：钉底宽限期
   1.5s。
2. **聊天室发送从不钉底**：`sendUserMessage` 自初始集成（28996ec）起就没有
   `scrollToBottom`（Session 的 `sendComposerInput` 有）。修复：补上。
3. **content-visibility 冻结流式条目（主因）**：`.ti` 的 `content-visibility:auto`
   + `lockIntrinsicHeight` 逐批锁定估算高——流式气泡高度超过一个视口后，布局
   被冻结在锁定值上：DOM 仍在实时流入（dom applied 每批正常）、pinBottom 每批
   执行、意图全程 pinnedBottom，但 **docHeight/scrollY 双双平台化**，画面精确定格
   在「恰好一屏」（所有构建、所有节流档位、wip 与合并后构建都停在 22 行）。
   流结束 renderFinal 后条目恢复渲染，文档瞬间长全。
   修复：流式期间该条目 `contentVisibility = "visible"`（本就该在屏上，CV 调度
   只有风险没有收益），定型归还。

### 排查过程中的排除项（都有实验证据）

- ~~帧率 × 提交等待~~：NEWPI_FLUSH_MS=200（5 帧/s vs 17 帧/s）冻结依旧
- ~~意图丢失~~：PIN-PROBE 全程 pinnedBottom 零降级
- ~~JS 执行滞后~~：dom applied 与 flush 1:1 同秒
- ~~WebContent 过载~~：sample 显示其 98% 空闲
- ~~窗口尺寸变化可解锁~~：resize 实验无效
- ~~本次合并的回归~~：wip 构建（d6edcd6）同环境同会话复现同一冻结
- 干扰项：多面板探针日志互相污染（加面板标识后排除）；provider 出字速度
  波动（35~112 tok/s）干扰「是否在跟随」的截图判读

### 认知更新

「看到旧画面」不等于「绘制滞后」——docHeight 平台化证明是**布局**被冻结，
像素只是如实反映了布局。关键探针：scrollTop 与 docHeight 成对上报
（两者同涨=健康钉底；docHeight 停涨=布局冻结；scrollTop 落后=滚动失效）。

### 已知设计行为：流式结束时的「跳一下」（收尾沉降）

agentEnd 同刻发生：处理详情折叠（思考/工具卡收进 disclosure，答案上方变矮，
位移最大来源）、流式气泡定型换最终渲染、定型光标原位停 1.4s 后移除、
hljs 异步高亮。catchUp 循环（1.6s 窗口逐帧钉底）保证沉降后必然回底；
用户已上滚（userScrolling）时 catchUp 立即退出，不打扰阅读。
2026-09-08 实测确认：跟随流畅、上滚接管正常、Jump 按钮正常，收尾一跳为预期。

### 「不跳」方案（用户确认后实施，按 A→B 顺序）

收尾跳的成分拆解：处理详情折叠（大，主源）、气泡定型与 hljs 的高度差（中，
实测单帧 docHeight +2312px）、光标移除（极小）。方案分「消除变化」与
「掩盖变化」两类：

- **方案 A：折叠提前（治本）**——处理详情在**答案开始流出时**（首个 textDelta
  flush）就收进折叠组，而不是 agentEnd 才收。此时答案很短，重排不可感知；
  结束时刻只剩气泡定型的小差异。改动在 ViewModel 分组触发时机，JS 侧现有
  remove/upsert/order ops 已支持流式中结构变化。注意多轮 run（工具穿插多段
  文本）时每段新答案开始都要收上一段；分叉/压缩/恢复的交互要过一遍。
- **方案 B：收尾平滑滚动（治标，便宜）**——finalize 后 catchUp 的逐帧硬钉底
  改为一次 ~300ms smooth scroll 滑到底。观感从「故障」变「动画」。注意平滑
  期间 hljs 仍在改布局，目标移动中可能略晃；程序滚动时间戳（+600ms）已存在，
  不会误判用户接管。
- **方案 C：收尾帧锚定视口（折中，有风险，暂不实施）**——finalize 批用
  topAnchor/scrollToAnchor 纪律保持可见内容零移动，折叠发生在视口上方、
  尾部增高藏到屏外。风险：尾部增高大时会变成「延迟的第二跳」，与 catchUp
  叠加需谨慎。

决策：A→B 顺序实施，A 完成后实测再定 B 的具体形态（纯滑行 vs 锚定+滑行）。

## 八、遗留与后续项

1. **surface churn 未根治**：主线程的同步表面分配等待机制还在，修复只是
   让事件流对它免疫。若想进一步降低卡顿概率，方向是减少流式期间
   WKWebView 的 surface 重分配（wip 的 160pt 高度步进思路，力度需加大），
   或调查为何每次 commit 都走 add_subsurface + wait
2. **非活跃面板仍在全速渲染**（方案②未做）：后台保活会话的 WebView
   （opacity 0）流式时继续产 surface。可改为非活跃面板只累积 transcript、
   暂停 evaluateJavaScript 投递，切回时一次性 diff 重放——把并发产
   surface 的 WebView 数降到 1
3. **Debug 构建预期管理**：未优化代码 + Metal validation 下，渲染提交成本
   天然数倍于 Release；验收体验以 Release 为准，Xcode 调试建议关
   Metal API Validation（Scheme → Run → Diagnostics）
4. **聊天室流式路径自身的结构开销**（与本卡顿无关，独立优化项）：
   每 120ms flush 做全量消息→条目重适配 O(n) + SwiftUI 全 body 重估 +
   全量指纹 diff O(总字符)，没有 Session 侧的增量缓冲；长讨论下会显现

## 九、复盘要点（给未来的自己）

- 「UI 卡」先分清是**渲染慢**还是**事件流积压**——两者修法完全不同；
  本次三轮渲染向修复无效就是因为病灶在事件消费调度
- 主线程采样要在**卡顿窗口内**抓，且 runloop 定时器会被嵌套泵掩盖阻塞；
  MainActor sleep 探针 + 边界事件 hopLag 才是可靠的可用性度量
- Debug/Release 行为差异（Metal validation ×4）必须先纳入对照矩阵，
  否则会把环境问题当代码回归追
- 二分前先做**静态排除**：本次聊天室分支 30 个提交里 Session 渲染链路
  实质零变化，若先做这一步可省下多轮无效修复
