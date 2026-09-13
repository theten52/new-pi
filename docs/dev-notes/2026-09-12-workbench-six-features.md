# 工作台六项原型 gap · 实施与验收边界（2026-09-12）

## 状态与范围

> **当前状态（2026-09-13 后续）**：固定原生审批 dock 已被正文 `.ti-approval` 替代，
> 只读拟执行预览、回答 footer/真实结果条、窗口内居中用量对话框均已接入，待用户验收。
> 文件编辑记录仍仅部分覆盖，不是全部 Agent 修改账本。当前代码、日志与待 main 回填项见
> [弹窗、审批与结果记录](2026-09-13-workbench-dialogs-and-results.md)。下文初轮方案与失败证据保留为历史；
> “尚未实现”、原生审批组件测试和旧 Release 阻塞不能直接当作当前状态。

**初轮历史结论：六项相关能力已接入，但原型交付仍不完整。** 2026-09-13 用户指出协议徽章后重新实查网页，
确认存在展示错误与未实现项，不只是 pixel-perfect 或待验收问题。详见[再次对照与纠偏](2026-09-13-prototype-presentation-review.md)。
历史缺口见[差距审计](2026-09-12-prototype-production-gap-audit.md)，当前索引见[TODO](../TODO.md)。

初轮记录时生产代码与新增测试尚未提交；没有推送、创建 PR、更新 `dist/NewPi.app` 或重启用户 App。
不登记未经核验的新构建/安装包哈希。既有 `3b1ca4b` 图片预览比例修复及用户验收仍然关闭，
不将那次“图片可以了”的反馈扩展为本轮六项验收。

## 1. 失败卡与安全重试（仅 Session）

### 已实施

- 单文档错误卡展示按真实错误线索分类的标题、恢复状态和原始详情；未知异常不冒充连接故障。
  错误时间、provider/model 来自运行错误元数据，错误仍锚定原轮次并持久化，不成为额外模型消息。
- `AgentSession.retry(errorID:)` 仅原子领取最新的、已持久化且标记 `available` 的错误。
  守卫包括运行锁、原用户锚点、`retryLeafID`、当前内存消息与持久分支快照一致、工具结果完整。
  无已接受用户/无有效锚点、旧错误、取消、遗留缺字段错误及未完成工具阶段均不提供安全重试。
- 先保存 `retrying` 再请求，保存失败不启动 provider；成功结束保存 `recovered`，
  未成功完成则保存 `unavailable`。再次失败可以形成新的最新错误，旧卡不能假称恢复。
  冷恢复遇到中断的 `retrying` 会按不可安全继续显示，不自动重放。
- `AgentLoop.resume` 不追加用户或合成 Continue 消息，不重新执行历史工具声明；保留已完成工具结果。
  **仅重试的首个模型请求**裁掉连续位于末尾、无工具调用的 `.error/.aborted` assistant，
  遇到用户、工具结果或完整消息即停止。只改请求投影，磁盘/transcript 的部分正文仍保留；
  后续工具轮与普通 next-user 请求不套用这一裁尾规则。中断 reasoning/signature 不回放的既有保护保留。
- VM `retryError(id:on:)` 只接受当前 runtime 的最新可重试卡，主线程同步领取双击锁，
  不读/清/覆盖下一条草稿。事件消费逐条 await；`agentEnd` 串行等待结束提示与 transcript 校准，
  完成后才解除发送锁，避免旧收尾异步重建覆盖下一轮。错误态不会被 `agentEnd` 无条件改成成功。

### 边界

原型 error 场景是普通 Session。**不宣称聊天室失败重试或失败恢复已交付**；聊天室既有中断结果保存、
发送落盘失败保稿与本项不是同一功能。没有自动重试策略，也不承诺模型后续永不提出新的同类工具调用：
这里保证的是不由恢复流程重跑历史工具。真实网络端点、认证修复后恢复与正式 App 重启组合仍待验收。

源码：`Packages/NewPiCore/Sources/NewPiCore/AgentSession.swift`、`AgentLoop.swift`、
`NewPiApp/NewPiViewModel.swift`、`NewPiTranscriptDocumentView.swift`、
`NewPiApp/MarkdownRenderer/transcript-document.js`。

## 2. 真实 Git 改动入口与只读 diff（Session / room）

- header 共用 `NewPiChangesButton`：普通 Session 使用当前项目目录，room 使用聊天室工作目录。
  `WorkspaceChangesReader` 解析所选目录所属的**整个 Git 根目录**，不限于选中的子目录。
- 文件清单来自真实 Git status，逐文件区分 staged/unstaged；未跟踪 UTF-8 文本是
  **内容预览，不是 Git diff**。展示真实文件数，不从模型回答推断修改数。
- 明示“包含用户和其他工具修改，并非本轮 Agent 独占；只读，无撤销或回滚”。
  文件清单带读取时间，diff 按需读取，二者不是原子快照；刷新中不能把旧数量冒充最新数量。
  未选目录、非 Git、读取失败与干净仓库分别展示，非 Git 不自动初始化。
- IO 离开 MainActor，支持取消、generation 防过期回填及合并刷新。
  默认读取预算 8 秒、status/config 上限 8 MiB、diff/文本预览上限 256 KiB；
  清单截断拒绝不准确计数，diff/预览截断明确标记不完整。
- Git 不经 shell，使用字面路径参数；禁用外部 diff、textconv、hooks、fsmonitor、
  clean/smudge/process filter 等执行路径，并限制继承的 Git 环境与网络行为。
  未跟踪文件通过 `openat` / `O_NOFOLLOW` 逐级读取，符号链接仅展示目标，不跟随读取目标文件；
  二进制/非 UTF-8/嵌套仓库等如实提示，不伪造文本 diff。

**范围（仍有效）**：这是 header 的工作区级入口，不是每条回答下的 Agent 修改归属账本，
也不是审批拟执行内容的 before/after diff；没有恢复/回滚能力。Git 面板本身可用 sheet，
“审批不再模态”不等于应用所有面板均取消 sheet。
后续回答级记录与审批预览已有独立入口，见[当前记录](2026-09-13-workbench-dialogs-and-results.md)；
它们不将工作区所有修改重新归给 Agent。

源码：`NewPiApp/NewPiApp.swift`、`NewPiChangesView.swift`、
`Packages/NewPiCore/Sources/NewPiCore/Workspace/WorkspaceChanges.swift`。

## 3. 空态三建议：只填草稿

- `NewPiChatEmptyStateView` 提供“理解项目结构 / 检查最近的改动 / 一起定位问题”三条建议。
- `NewPiComposerDraft.fillSuggestion` 仅在文本完全为空、附件为空且提示非空时写入；
  已有文本、纯空白、图片草稿都不覆盖，不调用发送。
- 初始没有 runtime 时，`fillSuggestedDraft` 只在有项目且未切换会话时响应**显式点击**，
  创建 Session 后填稿，不发起模型请求。异步返回后重新检查项目、切换 generation、空 transcript
  与草稿守卫；自动打开项目不因此创建会话或发任务。
- 建议不是“已经检查过改动”的结果；用户仍需自行确认并发送草稿。

源码：`NewPiApp/NewPiMarkdownText.swift`、`NewPiComposerDraft.swift`、
`NewPiChatView.swift`、`NewPiViewModel.swift`。

## 4. 非模态原生审批：保留位置偏差

> **superseded**：本节记录初轮固定 dock 的偏差，现已移除生产挂载；当前审批位于 HTML transcript，
> 支持 write/edit/write_file 拟执行差异。不可再将下面“尚未实现”列为当前待办，
> 也不可用旧 `NewPiApprovalContent` 独立测试证明当前正文接线。

Session 和 room 都接入共用 `NewPiApprovalContent(isInline: true)`，不再通过模态 sheet 等待审批。
卡片是 **transcript 下方、composer 上方的原生 dock**，等待时真实输入框仍可编辑。
**它不是 HTML transcript 内的元素，不随正文滚动。原型随文审批尚未实现，用户未同意替换为固定卡片，不能记为已交付后仅待人工接受。**

- Return/Enter/Escape 不绑定批准或拒绝，不能因编辑草稿误授权；发送/停止仍遵循运行态守卫。
- `responded` 防重复响应，request ID 变化重置卡片；回调再核对 Session 活跃 runtime/request
  或 room 队首请求，防止旧卡片误处理新请求。
- 既有风险评估、允许一次/拒绝、Session 范围和永久授权，以及 room 内存态范围授权保留。
  高风险仍逐次确认，不展示记忆授权；room 不扩成永久授权，也不将工作目录说成 bash 沙箱。
- 不新增审批关联的拟执行 diff；工具摘要与独立工作区 Git diff 是不同信息。

源码：`NewPiApp/NewPiToolApprovalSheet.swift`、`NewPiChatView.swift`、`NewPiApp.swift`。
保留的旧 sheet 类型名/日志文字不等于当前生产审批仍从 sheet 呈现，应以实际挂载调用为准。

## 5. 真实消息元数据：日期、时间、身份与模型

- Session transcript 从 UserMessage/AssistantMessage/ToolResultMessage 的真实字段传递时间，
  assistant/error 同时传递实际 provider/model。复制、冻结、结束重建及冷恢复保留可选字段。
  流式期间可以先显示请求模型；时间未取得前不以当前时刻伪造历史时间。
- 单文档渲染日期分隔、消息时间、用户/助手身份头像行。09-13 纠偏：普通会话只显示身份/时间，
  历史模型放在身份悬停提示；聊天室显示一个真实模型徽章。内部 provider 协议标识不作厂商徽章。
  头像是本地身份图形，不宣称读取了用户照片或姓名档案，也不等同原型头像堆叠。
- `ChatRoomMessage.provider/modelID` 为可选快照字段：引擎路径从实际 engine model 获取，
  旧 provider 路径从可选 `modelSnapshot` 获取，随新消息/分段保存。适配器读取消息快照，
  不用当前角色配置回填历史模型；旧 JSONL 缺字段/null 保持 nil，旧自定义 provider 无快照仍兼容。
- 聊天室已有角色栏、阶段与 streaming identity 继续复用；元数据接入不表示全部房间视觉或失败恢复验收完成。

源码：`NewPiApp/NewPiViewModel.swift`、`NewPiChatRoomTranscriptAdapter.swift`、
`NewPiTranscriptDocumentView.swift`、`NewPiApp/MarkdownRenderer/transcript-document.js`、
`Packages/NewPiCore/Sources/NewPiCore/ChatRoom/ChatRoomModels.swift`、`ChatRoomLoop.swift`、`ChatRoomLLMProvider.swift`。

## 6. 真实工具进度与 Session 中文结束摘要

> 下列为初轮摘要实现。后续新增实测工具耗时、成功编辑记录与最终回答 footer；
> 因此“不造工具耗时”不等于当前没有计时。规划总步骤与测试通过数仍未提供，详见[当前记录](2026-09-13-workbench-dialogs-and-results.md)。

- 工具卡和详情组依据实际 tool start/end/result 状态统计已完成、进行中、失败，
  不是规划器承诺的总步骤；尚无结果不能假称成功。无工具时不补假步骤。
- `turnOutcome` 仅在主状态展示；`SessionRuntime.turnSummaryText` 只给真实工具计数，作为同排辅助信息。
  09-13 删除了无工具时多出的第二行「已完成」，不重复失败/已停止/已恢复等主状态。
- 不造固定“2/3 步”、百分比、工具耗时、文件修改归属或测试通过数；工具完成不等于任务正确或测试通过。
  这里的 Session 摘要不是聊天室全流程结果报告，也不宣称整款应用所有英文文案已中文化。

源码：`NewPiApp/NewPiViewModel.swift`（`turnSummaryText`、`restoredTurnOutcome`）、
`NewPiChatView.swift`、`NewPiApp/MarkdownRenderer/transcript-document.js`。

## 初轮验证证据（历史，不代表后续源码全量验收）

下列日志均在 `/private/tmp/newpi-ui/`，临时路径只是本机证据，不进入 Git。
PASS 数量按各自测试层级记录，不能相加成“完整 App 测试数”。日志文件名含 `final` 也不自动意味着覆盖最后一次源码编辑。

| 范围 | 已核对的结果 / 日志 | 限制 |
|---|---|---|
| Core 默认并行 | `workbench-six-core-final.log`：374 tests / 93 suites，**1 issue**；`NewPiLoggerTests.fileSinkDelivery` 缺少预期全局日志 marker | 全局 logger/file sink 并行干扰，失败原样保留，不能写成全绿或已修复。 |
| Core 串行 | `six-core-serial.log`：`--no-parallel`，**374 tests / 93 suites PASS** | 工作区全量，**包含用户 Labs**；无本轮 clean tracked-only 结果。旧 PR 的 327/85 clean-head 是旧提交证据，不适用于当前代码。 |
| 原生建议/审批 actions | `workbench-six-actions-final.log`：**493 PASS / 0 FAIL / 0 SKIP** | 独立 NSHostingView/NSWindow，生产组件与提取接线；发送、创建 Session、审批后端为内存 fake。覆盖620/360宽×浅深、草稿/图片保护、点击/双击、Return/Escape及授权菜单，不是完整 App 或持久授权验收。 |
| 真实 Git diff UI | `six-changes-ui-fixed.log` **ROUND 2：281 PASS / 0 FAIL / 0 SKIP，REAL_EXIT=0** | 临时真实 Git + 完整生产 Changes 组件与 NewPiCore、独立 NSWindow。420/920×720浅深，打开/关闭、分区/文件选择、刷新、在途切目录、index/worktree不变；不是正式 App。 |
| 单文档 DOM | `workbench-six-dom-final.log`：新增 **46** 断言；既有 **19** 语义、**4** 组收尾几何零差、**8** 组浅深样式通过，**0 SKIP** | 真实 WKWebView；实际桥接收到1次retry、2次原文复制。不是完整窗口像素、VoiceOver或真实网络恢复。 |
| room adapter / 元数据 | `workbench-six-room-final.log`：PASS，包含历史模型快照、steering、分段ID、取消及Session兼容 | adapter/共享流式判定回归；Core日志另含历史快照持久化/缺字段兼容测试，不等于聊天室实机全流程。 |
| Session VM 重试 | `workbench-six-retry.log`：**19 条断言 PASS**，另有1条完成说明 | 提取真实VM业务并走fake provider；无App/窗口/网络。`six-retry-vm.log` 本次读取时仅见Core build完成，不能把它当作最新19条断言复跑完成。 |
| 草稿/发送守卫 | `workbench-six-draft.log`：PASS | 真实NSTextView、生产Binding与runtime/room controller重建；跨Session/room草稿隔离、图片保留、发送拒绝与追加失败保稿，不是用户正式导航验收。 |

### 历史失败与最终验证回填

- `six-changes-ui-fixed.log` 首轮 **22 PASS / 8 FAIL / 0 SKIP，REAL_EXIT=1**，
  清单等待超时；后附 ROUND 2 才为281通过。首轮是历史失败，不删掉或反向标为通过。
- Core 串行通过不能证明默认并行隔离问题已修复；本次只核对日志与测试使用的全局 singleton，不修改测试。
- diff button 后续编辑后的最终 Debug build 已通过：`six-final-build.log`，`six-final-exits.txt` 中 `build=0`。
- 最终冷恢复 `six-final-cold.log` / `cold=0`：500条Session、room A/B/A、Session切回均 `heightReads=0`、`anchorErrorPX=0`；
  Coordinator 重试桥接守卫、进程恢复、隐藏追赶和迟到帧回归通过。不是完整生产会话性能统计。
- 最终权限控制器、Session VM重试复跑通过，`six-final-exits.txt` 中 `controller=0`、`retry=0`；
  `git diff --check` 也为0。未改动生产日志测试解决并行隔离问题。
- Release打包尝试被终端未结束的heredoc输入阻塞，**未执行备份/打包/覆盖dist**；
  `six-release-result.txt` 不存在，不登记新包或哈希。可先在Xcode重新构建运行；终端恢复后再打包。
- 模型请求链通过 fake provider 演练，**没有真实网络模型调用**。“真实重试”指接入实际恢复链路，
  不是1.2秒模拟按钮；测试也不是外部服务恢复成功证明。

## 当前验证增量与待正式 App 人工验收

后续已核对 `remaining-core-v2.log`（串行392 tests / 96 suites，含Labs）、
`remaining-dom.log`（54断言＋19语义＋4几何＋8样式，无SKIP）、
`cold-debug-agent-final.log`（当前正文审批/结果桥接及500条历史保锚）、
`usage-dialog-blur-final.log`（712 PASS / 0 FAIL / 0 SKIP）与 `remaining-final-build.log`（Debug成功）。
`remaining-final-retry/draft/room.log` 有成功结束记录；`remaining-final-actions.log` 当前末尾中断、没有汇总，
**不沿用旧493作为该轮结果**。这仍不是完整App、VoiceOver、全端点或全部最新测试通过声明。
额外 Core+Coordinator 端到端新测试尚待运行结果；Release/备份/签名/哈希待 main 回填。

1. 已有 Debug build、冷恢复末轮日志回填；不能推断覆盖其后的每次编辑。Release 状态待 main 提供新证据，旧 heredoc 阻塞只是历史。需要 tracked-only 结论时单独验证，不能排除 Labs 后推算通过数。
2. 在正式 App 验收 Session 失败→显式重试→成功/再失败、冷恢复、双击/切换隔离及下一条草稿不变；真实端点另行明确安排，不将room恢复纳入已交付声明。
3. Session/room 的工作目录切换、Git清单/分区刷新与非Git/异常提示；确认用户已有改动不被归为Agent独占，不存在写入/回滚动作。
4. 初始无runtime与已有空Session的三建议入口、含图片/纯空白草稿保护；确认无隐式发送或模型调用。
5. Session/room 随正文滚动审批卡与拟执行差异已接入，待正式 App 验收等待时编辑、请求更替、风险范围和预览失效；不再要求用户接受已撤下的固定卡片替代方案。
6. 新旧消息的时间/模型展示、room切模型后的历史不变、工具状态/结束摘要真实性；核对浅深/系统高对比、真实IME、键盘完整路线与VoiceOver。
7. 同内容原型对照、完整工作台布局与跨会话滚动仍待人工验收；组件几何通过不证明玻璃像素、文字不截断或原型完全还原。

不关闭上述整体验收；用量窗口、回答级复制/改动与结果条按后续实现验收，不重复建设既有附件、单文档滚动及聊天室阶段能力。
提交、推送、PR、打包与用户更新需后续单独记录；[旧 PR 草稿](2026-09-12-workbench-pr-handoff.md)中的旧提交/Release证据不自动覆盖六项。