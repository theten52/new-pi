# 聊天室输出渲染：插话、边界刷新与中断保留

基线：`6dc3acb`；分支：`codex/chatroom-stream-rendering`。

## 本轮范围

修正确性，不重写 Session/聊天室共用的 JS Markdown 和滚动架构，不改变目录/审批规则，不增加界面动画。

### 1. 显式的流式身份

`ChatRoomRuntime.liveSpeech` 保存发言 ID、当前分段消息 ID、waiting/thinking/text/complete 阶段。
适配器不再依赖 `messages.last`。用户插话追加在列表末尾时，原分段仍可继续显示流式正文，详情组不会因此收起。

`NewPiTranscriptItem.streamingOverride` 只由聊天室 Assistant 条目赋值，共用桥接层据此决定 streaming op；Session 默认为 nil，保持原来的末条消息 + bubbleComplete 判定。

一条正文 messageEnd 就进入完成态，不等整个工具循环结束。声明的工具在该边界入组，执行开始事件按工具 ID 去重。

### 2. 有尾部定时冲刷的合并器

`ChatRoomSpeechBuffer` 首批立即显示，后续最多等 120ms；没有下一个 token 时也能显示缓冲尾字。
仅有脏数据时创建一次 Task，结束/边界取消；Thinking/正文在同一次消息赋值中提交。

所有非 delta 事件先冲刷；审批回调还通过 `ChatRoomApprovalEventGate` 等待消费到对应的 toolApprovalRequired，保证前序文字先发布。
生产者已排队不代表消费者已处理，不能只在回调里随意 flush 一个可能尚为空的缓冲。
取消与结束会解开 gate 的等待，不留悬挂 continuation。

### 3. 停止不等于撤销

- 已有文字、Thinking 和工具结果保留。
- 已声明却未收到结果的工具标为结果未知，明确说明可能尚未执行，也可能部分执行，不声称回滚。
- `termination` 可选字段记录 cancelled/failed；旧 JSON 无此字段仍正常读取。
- 中断详情默认展开，显示“未完成”提示；既有手动折叠选择仍由 JS 尊重。
- Markdown/Text/JSON 导出、后续模型上下文和历史压缩携带中断说明。
- 没有任何输出的空占位不保留；停止不推进下一角色索引。
- 本次发言定型/中断时原子保存消息快照，保持插话在 UI 中的相对顺序，避免重载后插话被排到所有角色分段之前。流式每批不落盘。

## 验证层次

1. Core：可控模拟模型 + 临时目录，覆盖缓冲尾字、插话、审批等待、取消/失败、兼容 provider 路径、中断记录重载。
2. App：真实条目类型和适配器的可重复脚本，验证 Session 既有流式语义不回归。
3. WKWebView：真实 JS/CSS，直接检查非末尾 Assistant 的 renderStreaming 调用与 messageEnd 的 renderFinal 调用。
   当前产品代码已经关闭正文 ✦ 光标，测试不依赖光标，不恢复该视觉效果。

## 未扩展

- 聊天室流式仍通过 MainActor/SwiftUI，未移植 Session 的后台缓冲 + applyLive 直连。
- 全量适配、签名计算和通知传播的性能优化留待测量，不在本轮重构。
- 不改滚动/高度步进策略；布局定型的自然高度差仍可能存在。
- 不保证系统强杀前的未落盘流式内容恢复；本轮处理用户停止和正常错误收尾。
- 已执行工具的副作用不自动回滚；取消和结果未知提示不能代替文件状态检查。

## 本轮执行结果

- Debug / Release：构建通过（仅 AppIntents 无依赖时的 metadata extraction 提示）。
- Swift Package：282 tests / 79 suites 全部通过。
- 新增 11 个 Core 专项测试连续重复 5 轮通过。
- 真实 App 适配器/共享流式判定、控制器删除与目录守卫脚本全部通过。
- 真实 WKWebView DOM 检查通过；没有请求真实模型，也没有修改用户项目文件来验证工具执行。
