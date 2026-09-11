# 历史冷加载：移除单文档路径的无用高度读取

基线 `0c5d8fc`，分支 `codex/transcript-cold-load`。

## 定位结果

`renderFinal()` 原先无条件调用 `measureRootHeight()`，但该高度只在 `reportHeight == true` 时使用。
Session / 聊天室单文档路径明确传入 `reportHeight: false`。
每新增一条历史正文前，读取 article.getBoundingClientRect() 会要求浏览器更新布局；与连续 DOM 插入交替时成本累积。
500 条正文的探针确认：正文最终渲染 500 次、额外 article 高度读取 500 次，但读取结果从未被单文档路径使用。

生产改动只有一处：`reportHeight ? measureRootHeight() : 0`。
不缓存 HTML，不保活更多 WebView，不拆分消息批次，不修改恢复锚点、content-visibility、流式高度步进或 Markdown 输出。
高度上报模式继续读取原高度；新增 DOM 检查覆盖开/关两个模式。

## 测量方法与边界

新增 `scripts/validation/check-transcript-cold-load.sh`，编译真实 Coordinator、HTML 工厂、适配器以及 WKWebView。
临时构建 Probe.app 提供真实 JS/CSS 资源；仅 logger/metrics 为空测试实现，避免合成数据落盘到用户监控。
滚动 sessionID=nil，但直接提供真实 Entry 作为恢复锚点，不读写用户的 scroll-positions.json。

fixture 是 500 条带标题、长正文和 Swift 代码块的合成历史，使用真实 ChatRoomStore 写入/读取临时 JSONL。
脚本逐个创建并销毁页面：Session 形态首次加载、聊天室 A、短历史 B、A 返回、Session 形态返回。
聊天室历史在内存复用，切回重新调用适配器。每次页面创建前提交两次快照，检查 pendingSnapshot 合并。
Session 形态使用内存 transcript，**没有测量真实 SessionManager 解码或整个 SwiftUI 导航**。
文件读取可能命中刚写入数据的 OS 页缓存，不代表磁盘物理冷读。

基线和修改后顺序运行，不与构建并发；通过环境变量只替换临时资源中的旧 JS：

```bash
NEWPI_RENDERER_REVISION=0c5d8fc bash scripts/validation/check-transcript-cold-load.sh
NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 bash scripts/validation/check-transcript-cold-load.sh
```

## 一组相邻对照结果

时间均为毫秒。“两个 RAF”从开始 loadShell 到收到 DOM apply 回报并等待两个 RAF，含轮询、调度和 IPC，**不是 GPU 已显示或真实用户点击到首屏的计时**。

| 场景 | 外壳加载 前→后 | 原生 diff/编码/派发 前→后 | DOM apply 前→后 | 两个 RAF 前→后 |
|---|---|---|---|---|
| Session 形态首次，500 条 | 576.72→314.51 | 8.29→9.37 | 539→94 | 1177.80→457.21 |
| 聊天室 A，501 条目 | 252.28→188.18 | 15.47→16.77 | 779→119 | 1094.43→361.64 |
| 聊天室 B，25 条目 | 264.99→216.23 | 0.99→0.99 | 39→25 | 320.38→257.72 |
| 聊天室 A 返回 | 234.90→187.37 | 15.68→17.15 | 800→140 | 1107.74→382.41 |
| Session 形态返回 | 245.84→193.65 | 8.55→7.43 | 560→118 | 846.68→350.81 |

- 聊天室首次 JSONL 读取：11.52→10.99ms；首次适配：0.501→0.439ms。
- 聊天室 A 返回适配：1.040→0.470ms；没有重新读取磁盘。
- 所有长历史额外 article 测高：500→0；小历史：24→0。
- 两版每页均只投递一个初始化批次，最终渲染次数均等于正文数；没有证据表明存在重复初始化投递。
- 返回锚点偏差均为 0px，等待原有 3s 恢复窗口结束后测量。

第一轮较早的对照也观察到长历史 DOM apply 527～805ms → 98～145ms。
外壳启动时间受进程预热/系统调度影响明显，不能把它的下降归因于这一行改动。
可信结论是消除了 500 次无用布局读取，受控 DOM apply 显著下降；不宣称所有真实对话都获得同等比例提速。

## 正确性覆盖

- 待加载快照合并成一次 JS apply，重复相同快照不再投递。
- DOM 行数和唯一 ID 数等于输入条目数，无重复消息。
- 正文非空、代码块存在；最终 Markdown 渲染次数不减少。
- 聊天室/Session 形态中部锚点冷恢复。
- 既有流式非末尾消息、Thinking 手动展开、完成态、插话保留检查。
- reportHeight=false 不再读取旧高度；reportHeight=true 仍测量。

执行结果：Debug / Release 构建通过，产物 JS 与工作区文件一致；282 tests / 79 suites 通过。
控制器守卫、适配器/Session 兼容、WKWebView DOM 回归及上述冷加载探针均通过。

## 后续

本轮不处理真实 App 的 SessionManager 恢复成本、SwiftUI 导航耗时、附件加载、背景 WebView、首屏 GPU 呈现或全部主题/窗口尺寸。
不将本次结果作为增加 HTML 缓存、分页或长期保活聊天室 WebView 的依据；先在真实大历史下确认剩余开销。
