# 2026-09-13 · 原型展示再次对照与纠偏

## 当前状态与历史边界

本记录保留重新对照原型时发现的真实偏差，不能把当时未完成项永久当作 backlog。
**后续已实现**窗口内居中用量对话框、正文随文审批及拟执行预览、最终回答底部复制/查看改动与真实结果条；
固定原生审批 dock 已移除。实现与日志见[弹窗、审批与结果记录](2026-09-13-workbench-dialogs-and-results.md)。
这些项目转为 implemented / 待用户验收；文件编辑捕获仍限内置成功 write/edit/write_file，
不是全工作区或全部 Agent-only changes。原型像素、全端点、VoiceOver、普通旧历史追溯补齐仍未完成。

## 首轮结论（历史）

用户截图中的 `openaiCompatible` 是实现错误：它是内部 provider 协议标识，不是模型或厂商名称。
不是用户配置错，也不能要求用户改配置迁就界面。此前「六项已实施，只差人工验收」范围表述仍然过满。

原型服务已停止；恢复仓库 `preview.py` 后，实际打开用户指定地址，切换全部六场景并查看普通会话/聊天室深色截图。
首页文本提取失败，JS/CSS获取及浏览器导航成功。没有改变原型来迁就实现，没有读取用户凭据、发送模型请求或重启App。

## 首轮逐项对照（历史；审批、回答级改动与结果缺口已 superseded）

| 项目 | 原型 | 生产结论 |
|---|---|---|
| 消息头 | 普通会话：头像、NewPi、时间；聊天室：头像、角色名、一个模型徽章、时间 | **确实写偏，本次修正**：删除协议徽章；普通会话不堆叠模型标签，历史模型留在身份悬停提示；聊天室保留一个真实模型徽章。未修改磁盘模型数据。 |
| 状态与结果 | 一行主状态＋辅助说明；回答后有结果条 | **确实写偏/部分缺失**：截图无工具时两行「已完成」源于summary重复turnOutcome。本次只保留主状态，工具统计同排辅助显示；真实任务结果条、计划步骤/耗时仍未实现。 |
| 审批 | 正文中的黄色审批卡，随正文滚动，可查看拟执行差异 | **未完整交付**：目前非模态，但固定在输入框上方；没有拟执行diff。原生实现不是不能做随文审批的理由，用户未批准这一替代方案。 |
| 改动 | 顶部入口、回答底部「查看改动」、文件差异面板 | **部分交付**：顶部真实Git面板已有，范围是整个工作区。回答底部入口及本轮修改归属/关联缺失，工作区48个文件不能说成Agent本轮改了48个。只读和明确范围是必要边界，不是归属功能完成。 |
| 失败恢复 | 失败卡、重试中、恢复态与保稿提示 | Session真实重试已有，限制安全最新锚点合理；原型假计时器不能搬到生产。恢复后的历史错误保留而非直接消失，属于需要明确的展示差异；未据此宣称聊天室恢复已实现。 |
| 新会话 | 三建议，只填草稿 | 基本行为已接入；生产另外保护已有草稿，合理。不意味着整个空态间距、图标、焦点等均按原型完成。 |

## 首轮修正依据与测试原则

- 原型 `prototype.js` 的 `assistantMessage`：普通会话传空role，聊天室传模型名；无协议标签。
- 生产 `syncMetadata` 原先直接循环显示provider/model；此前DOM测试还要求“两徽章”，是测试跟着实现走，未验证设计语义。
  本次改为普通会话无徽章、聊天室单个模型、协议不出现在可见标签；保留source复制、时间真实性、XSS转义与节点复用检查。
- `SessionRuntime.turnSummaryText` 只返回工具统计，无工具返回nil；`NewPiAgentStatusBar.detailText` 同排展示，
  `NewPiChatView` 删除额外摘要行。失败/恢复/停止仍由主状态表达，不是删除状态能力。
- 不以测试数量证明设计已还原；当时随文审批、回答级改动和结果条维持open，后续已实施、待用户验收。该次未自动提交、打包或重启用户App。

## 首轮已核验结果（不追溯覆盖旧 SKIP）

- `prototype-header-dom.log`：54条元数据/错误/统计断言、19语义、4收尾几何零差与8组浅深样式通过。
  本轮WebKit没有页面键盘焦点，8组代码复制键盘可见性明确SKIP，不能写成全交互通过。
- `prototype-status-vm.log`：真实业务提取回归通过，新增无工具时不重复状态、各结束态与工具统计隔离断言。
- 上述日志与原型截图 `prototype-review-complete.png` / `prototype-review-room.png` 位于本机 `/private/tmp/newpi-ui/`，不进入Git。
- `prototype-header-cold.log`：Coordinator元数据/重试守卫、500条Session与room A/B/A恢复通过，`heightReads=0`、`anchorErrorPX=0`。
- `prototype-presentation-build.log`：完整Debug构建`BUILD SUCCEEDED`，exit0；`git diff --check`通过。未更新dist。
- 本次未把用户先前的图片验收扩展为新的展示验收；新状态辅助信息的窄栏实际像素/键盘可达性仍需人工确认。

## 后续核验与剩余边界

- 用量不再是小型 popover：实际按钮窗口归属、居中最大600pt圆角卡片、四指标卡＋三摘要、真实 nil，
  父 content `.withinWindow` blur＋dim 与透明子面板已接入；关闭/背景/Escape、焦点/marked text、AX 模态隔离有合成回归。
  `usage-dialog-blur-final.log` 末尾为712 PASS / 0 FAIL / 0 SKIP；浅深真实合成截图已查看。
  原生模糊强度不等于原型 CSS 3px，不作 pixel-perfect 声明，也不是整款 App 用户接受。
- `.ti-approval` 已在正文，独立待发态避免 `liveDriven` 吞掉撤销；runtime/request/nonce、main-frame、可见性、当前回调及一次领取守卫已接入。
  `ToolChangePreview` 明示尚未执行、可能变化与不可用原因；不以 header Git 面板替代预览。
- 结果条依据工具记录，不猜计划步骤、测试通过数或整个工作区归属；partial/intermediate 不作 final，旧缺失不回读当前文件补齐。
- 最新证据：Core串行392/96（含Labs）；DOM54断言、19语义、4几何、8样式且无SKIP；生产Coordinator合成回归、500历史锚点误差0；
  `remaining-final-build/retry/draft/room.log` 成功。旧键盘SKIP仍保留为旧轮结果。
  `remaining-final-actions.log` 当前读取末尾中断、无汇总，不能登记493；其中原生审批仅兼容组件，不是当前生产正文接线。
- 额外 Core+Coordinator 端到端新测试、actions最终汇总与本轮Release状态待 main 回填；已读日志不自动覆盖此后源码。
  保留整窗导航/草稿/滚动组合、真实IME候选窗、VoiceOver朗读及同内容原型对照待验收，不从组件PASS推导全部交付。