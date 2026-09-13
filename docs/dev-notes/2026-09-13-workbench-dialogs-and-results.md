# 工作台用量对话框、随文审批与回答结果（2026-09-13）

## 当前结论

用量窗口、Session/room 随文审批与只读拟执行预览、最终回答 footer/真实结果条均已接入，
状态为 **implemented / 待用户验收**。此前“审批固定在输入框上方、回答底部入口和结果条未实现”
已被后续代码取代；不再要求用户接受固定 dock 替代方案，也不称整款 App 已获接受。

[六项初轮记录](2026-09-12-workbench-six-features.md)与[原型再次对照](2026-09-13-prototype-presentation-review.md)
保留历史方案、失败和 SKIP；当前待办见 [TODO](../TODO.md)。本记录依据工作区源码及下列实际日志，
不是对旧报告的转述。文件捕获仍是部分覆盖，不能因新增结果条就宣布“全部 Agent 改动”已实现。

## 1. 用量：属于当前窗口的居中对话框

入口为 `NewPiAgentStatusView.swift` 的 `NewPiUsageButton` / `NewPiUsageOpener`，
由按钮实际所属 `NSWindow` 创建 `NewPiUsagePresentation`，不查找全局 key window 代替归属。
每个窗口最多一个面板，不同窗口互不覆盖；隐藏保活入口、最小化窗口不新建面板。

- 卡片居中，最大宽600pt，两侧至少20pt，圆角14pt，最大高度为内容区80%；小窗只滚动内容，标题/关闭按钮保持可达。
- 四张两列指标卡：**最近一轮输入、最近一轮输出、缓存命中率、上下文占用**；三项摘要：累计用量、最近一轮、输出速率。
  卡片读取明确字段，不解析累计字符串猜数，也不照搬原型数字。nil/空值显示“暂无数据”，动态更新不残留旧值。
- Session 传 `lastTurnUsage.totalInputTokens` / `outputTokens` 的正值，缓存率仍来自累计用量，
  上下文来自现有估算展示；room 当前最近一轮输入/输出传 nil，不拿房间累计冒充单轮。
  展示数据类型可以区分明确0与未知，但 Session 当前接线对非正值传 nil；不声称已补齐所有端点的零值/缺失区分。
- **背景取样在父窗口内**：父 content 顶层 `NSVisualEffectView(.withinWindow)` 加 dim，
  透明子 `NSPanel` 只承载卡片、键盘焦点和输入隔离。几何随 content layout rect 同步，正文/输入框不被挤压。
  减少透明度时隐藏 blur、使用不透明兜底；无位移动画，不依赖动画完成更新。
- 这是 window-local 交互模态，不启动全局 `runModal`，不持有发送/停止回调，后台生成继续。
  打开时焦点在关闭按钮，Tab/Shift-Tab 不逃逸；关闭按钮、背景、Escape 都可关闭并恢复原 responder。
  父 NSTextView 不被强制结束编辑或 unmark，marked text/草稿/选区保留；事件过滤不拦截其他窗口。
- AX 将子面板标为 modal dialog，父窗口仅暴露该对话框，底层业务内容隐藏；关闭恢复原 AX children、隐藏状态、通知设置，
  只删除自身持有的两层，不移除业务新加视图。窗口关闭/最小化及入口卸载清理面板和监听器。

### 缺陷与证据不能混写

1. 初始事件监听编译失败涉及 `NSEvent` 的 Sendable 边界；现代码只让 Bool 穿过 `MainActor.assumeIsolated`，
   外侧返回原事件或 nil，不让 `NSEvent` 跨该返回边界。
2. 早期 frame 断言失败：合成 NSTextView 在设置 marked text 后高度98→18，采基线时尚未 settle。
   最终日志记录“未打开 panel”也有该变化；应在其布局稳定后比较，不能归因为弹窗挤压正文。
3. blur 缺失是真实问题：子窗口 behind-window 取样没有取得父正文，后来改为父 content 的 within-window 取样。
   不能用第2项 fixture 问题为第3项开脱，也不能只凭存在 effect view 就称视觉正确。

`usage-dialog-blur-final.log` 末尾 **712 PASS / 0 FAIL / 0 SKIP**，覆盖900/620浅深、三关闭路径、
动态数据、marked text、AX树、父子窗口几何、后台推进、双窗口隔离和生命周期。
已查看 `usage-dialog-new.png` 与 `usage-dialog-900-dark.png`；日志另含620浅深合成截图和父子窗口白名单捕获。
可见圆角、四卡片、三摘要及模糊背景；非均匀背景像素检测不能量化 blur 核。
**原生模糊强度不等于 CSS 3px，不宣称 pixel-perfect。** 合成窗口的后台计数推进不等同正式模型任务整体验收。

## 2. 审批：进入正文，而不是原生固定 dock

生产接线为 `NewPiChatView.swift` / `NewPiApp.swift` → `NewPiTranscriptApproval` →
`NewPiTranscriptDocumentView.Coordinator` → `transcript-document.js`。
Session/room 父视图的固定 dock 挂载已删除；保留的 `NewPiApprovalContent` / sheet 类型是兼容代码，
不能凭类型名或旧组件测试判断当前生产布局。

- JS 创建正文 main 中的 `.ti-approval`，固定于请求出现时的正文锚点，后续插话不会搬到新 user 后。
  插入、更新、移除和正文变化共用同批保锚；浏览器仍是唯一滚动写入方，原生不消费内容高度。
- 审批是易失展示态，不写入模型消息或持久 transcript。Coordinator 按 runtime/request 映射DOM身份，
  更替时刷新 nonce；审批/预览独立待发，不被 `liveDriven` 对正文快照的独占提前返回吞掉。
- 收消息先检查 main-frame、当前 WebView、页面已加载和可见性，再核对ID、request、nonce、未领取状态及当前 runtime 回调。
  Session 再确认活跃 runtime，room 再确认待批队首；按钮双击或旧页面消息不能重复领取。
  模型文本、class、href、dataset 不构成授权，能力在原生下发与按钮闭包中。
- 高危只允许 once；非高危 Session 可 once/session/forever，room 只有 once/session，无永久授权。
  等待时输入框仍可编辑，Return/Escape 不直接授予或拒绝审批；打开差异对话框后的 Escape 仅关闭预览。
- 预览异步返回再检查 generation、nonce、请求、可见性及当前回调；请求更换、已领取、隐藏或页面重建时丢弃迟到结果。

### 拟执行差异的只读边界

`ToolChangePreview.make` 支持 `write` / `edit` / `write_file`，复用 edit 唯一匹配规则。
读取以工作目录为信任根，逐级目录 fd + `openat` / `O_NOFOLLOW`，拒绝越界、`..`、父级/叶子符号链接、
设备/FIFO、二进制/非UTF-8及超预算内容；文件读取和拟写入文本预算64 KiB。
不创建目录或执行工具，不把预览当作已修改文件。

卡片及预览明示“尚未执行”“文件可能在实际执行前变化”；不支持、目标不存在、参数不匹配、内容相同及预算不足均给原因。
预览继续受下节32 KiB快照/64 KiB patch预算约束，能读取不等于有完整diff。
实际执行重新捕获 before，历史以成功写入结果为准，而非复用可能过期的预览。

## 3. 文件记录与耗时：有限、不可变、可缺失

`ToolFileChange.swift` 定义 immutable `Codable` 记录：path、可选before/after/diff/note、
`isTruncated` 与可选 `beforeExists`。它不是可变 backup 引用，也不是回滚备份。
内置 `write` / `edit` / room `write_file` 在实际成功编辑后才返回记录；无变化返回 []，失败不声称成功修改。

- 每份before/after快照最多32 KiB，patch最多64 KiB；保留文本总预算128 KiB。
  真正逐行 unified diff 使用有界LCS（最多1,000,000个UInt32单元，另有行数上限），保留LF/CRLF、末尾无换行及Unicode字节差异。
  超限明确不完整，不生成伪完整patch或据此计算全部增删行。
- 执行耗时用 `ContinuousClock` 单调计时，AgentLoop 在审批通过、实际调用工具前开始，**不含审批等待**。
  执行失败可有实际耗时；拒绝、策略阻断、未知工具不能伪造已执行时长。
  结果条显示“已记录工具耗时”，不是模型总耗时、计划进度或整项任务耗时。
- 元数据通过 `ToolExecutionResult`、AgentLoop事件、`ToolResultMessage`、Session持久化与重建、
  ChatRoom engine/legacy结果及adapter传递；Anthropic/OpenAI-compatible/Responses请求编码不发送文件记录元数据。
  旧JSONL缺字段/null仍可读，未知保持nil，不能当作当时已确认无变化的[]。

**捕获覆盖仍是 partial**：只覆盖新发生的内置成功编辑，不覆盖bash、子代理、MCP和外部修改。
不回读当前文件补造普通旧历史，不从模型叙述或Git状态倒推归属；记录的路径不是所有Agent改动全集。
header `NewPiChangesButton` 继续独立展示所选目录所属整个Git root的当前改动，包含用户原有修改，
与审批预览、回答历史编辑记录是三个不同范围，均无回滚。

## 4. 回答 footer 与真实结果条

`syncAnswerFooters` 仅给明确 `answerState == final`、非流式且非详情中间段的assistant附加footer。
Session按user/summary边界分轮，room按显式角色＋speech ID分组；每个作用域只保留一个最终结果条，
不把另一用户轮或另一角色的工具记录归入当前回答。partial/intermediate不冒充final；旧缺字段不强行推断完成。

- “复制回答”通过既有原生通道复制source原文，而非带按钮、统计或格式化HTML的可见文本。
- “查看改动”展示该作用域已记录快照的只读diff；文本转义，长diff明确截断，缺记录显示“本轮未记录文件编辑快照”。
  关闭/背景/Escape关闭对话框并在入口仍有效时恢复焦点；请求失效不恢复到过期审批按钮。
- 结果条显示实际工具成功/失败/未完成数、已记录耗时（不足时标“部分”）、编辑记录次数和唯一路径数。
  同一路径多次编辑不是多个文件；工具成功不等于任务正确或测试通过。
  **没有编造“19 tests passed”、规划总步骤、完成百分比或全部文件归属。**
- 元数据变化也进入Coordinator签名与footer dirty判定，不能因为正文未变就吞掉耗时/记录更新；正文与代码DOM身份继续保留。

## 5. 已读验证日志及其覆盖范围

日志均位于本机 `/private/tmp/newpi-ui/`，不进入Git；每行是独立层级，不能相加成整款App测试总数。
名称含final不证明覆盖此后的源码或仍在补充的测试。

| 日志 | 已读结果 | 不可扩大为 |
|---|---|---|
| `remaining-core-v2.log` | `--no-parallel`，392 tests / 96 suites PASS，含Labs；包括编辑/预览、传播/历史兼容、provider编码和room engine/legacy记录 | 无tracked-only结果；串行通过不关闭旧默认并行logger/file sink隔离问题。 |
| `remaining-dom.log` | 54元数据/错误/工具断言、19语义、4收尾几何零差、8浅深样式，无SKIP；实际收到1次retry、2次原文复制 | 不是新增审批的全部端到端测试数，也不追溯把旧DOM的键盘SKIP改为PASS。 |
| `cold-debug-agent-final.log` | 实际生产Coordinator/JS合成路径通过：审批DOM、可编辑输入、live撤销、runtime身份、授权范围、只读预览、迟到/nonce/main-frame/一次领取、footer原文复制、轮次/角色隔离、长diff和取消焦点；500历史及room A/B/A恢复heightReads=0、anchorErrorPX=0 | 不是正式App全业务或严密性能统计；文件名有debug，日志实际注明探针编译 `-O`。 |
| `usage-dialog-blur-final.log` | 712 PASS / 0 FAIL / 0 SKIP，浅深合成截图已查看 | 不覆盖真实IME候选窗、生产WKWebView整窗、VoiceOver人工朗读或原型像素一致。 |
| `remaining-final-build.log` | 完整Debug `BUILD SUCCEEDED` | 不是Release打包或已运行的用户App版本证明。 |
| `remaining-final-retry.log` | VM业务提取成功结束，保稿/双击/历史/主状态回归通过 | fake provider，无App/窗口/真实网络；不照搬旧19条断言口径。 |
| `remaining-final-draft.log` / `remaining-final-room.log` | 草稿/发送接受边界与实际adapter回归成功结束 | 不是用户正式导航及聊天室全阶段验收。 |
| `remaining-final-actions.log` | 后续完整输出已核对：493 PASS / 0 FAIL / 0 SKIP | 审批段明确是原生兼容组件，不是当前正文生产接线。 |
| `approval-e2e.log` | 允许一次/拒绝两场景均PASS：真实DOM按钮→Coordinator→AgentSession gate→WriteTool→JSONL→footer；每场景user count=1，无永久授权写入 | fake provider、临时HOME/项目/会话，使用显式测试投影，不冒称生产ViewModel整窗验收。 |

## 6. 交付与剩余验收

1. Core＋Coordinator端到端已运行，见上表；新增文件为`TranscriptApprovalEndToEndChecks.swift`，
  根目录执行`NEWPI_APPROVAL_E2E_ONLY=1 bash scripts/validation/check-transcript-cold-load.sh`可单跑，默认cold套件也包含。
  预览不创建文件；允许前外部改写使实际before与预览不同，最终快照取实际执行内容；拒绝不写文件、不伪造耗时。
2. actions完整末轮结果已回填；逐测试结果计数能力仍未实现，不能靠解析任意工具文本猜通过数。
3. 本轮Release已更新`dist/NewPi.app`。首次构建中断，重试日志`remaining-release-retry.log`确认`BUILD SUCCEEDED`及打包完成；
  独立严格签名、dist/Release二进制一致性、渲染资源逐文件对比（忽略`.DS_Store`）和`git diff --check`均exit0。
  备份：`dist-backup/NewPi-before-dialogs-results-20260913-040341.app`；主二进制SHA-256：
  `1a8109ff58a433db40728c799a0f262f0ccb532fb4d50a30267d713904dd85a0`。
  核验报告`remaining-delivery-verification.txt`；未提交、推送或停止/重启用户App。
4. 正式App同内容原型对照、用量窗口与真实生成/IME候选窗组合、浅深/系统高对比、VoiceOver朗读，
   以及Session/room切换、审批更替、草稿/滚动恢复组合仍待验收。AX树和单项几何通过不能代替用户体验接受。
5. 全端点用量/真实网络恢复、全部修改来源捕获、普通旧历史追溯补齐不在当前已交付范围。
   已实现的有限记录与明确缺失提示应保留，不以“不造假”取消真实功能缺口，也不倒退重建已完成能力。

最终完整cold重跑：`remaining-final-cold.log`包含新增端到端允许/拒绝、审批/历史diff桥接和500条恢复，
`remaining-release-result.txt`记录`remaining-final-cold=0`。首轮中断的Release记录保留，不覆盖为成功。