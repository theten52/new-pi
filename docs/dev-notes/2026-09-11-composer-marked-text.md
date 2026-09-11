# 聊天室思考输出期间草稿消失

基线：`dee1ff8`。分支：`codex/chatroom-draft-preservation`。

## 复现

共用 `NewPiComposerTextView.updateNSView` 原先每次都比较 NSTextView.string 与 SwiftUI Binding，不相等就覆盖 NSTextView.string。
聊天室长思考/输出会不断触发父视图刷新，进而调用 updateNSView。

但输入法的 marked text 是 AppKit 管理的未提交编辑，暂时尚未进入 Binding；二者不一致不是外部清空命令。
旧代码把旧草稿（空草稿时为空字符串）写回，导致正在组词的文本被删除；继续组词后下一次输出刷新又会重现。

用真实 SwiftUI @State + NSTextView，先输入 `Existing draft `，再 setMarkedText(`zhongwen`) 并触发 20 次父视图更新：

- 旧代码：普通已提交草稿保留，组词文本消失，`composition-preserved=false`。
- 修复后：组词文本、marked range 都保留，`composition-preserved=true`；确认后 Binding 正常成为 `Existing draft 中文`。

因此已定位一个可复现且与用户现象吻合的输入同步缺陷；没有证据表明聊天室 ID 变化或输出逻辑主动清空了草稿。

## 修复范围

- 输入法仍在组词时，不从 SwiftUI 回写 textView.string。
- Delegate 不把未提交的组词文本当作最终草稿发布。
- isEditable 只在状态真的变化时赋值，不在每次输出刷新时重复设置。
- Coordinator 明确归 MainActor，AppKit 状态访问不跨线程。
- 组词结束后保留原本的差异同步，外部清空/恢复和发送行为不变。

没有缓存“上一次模型文本”来屏蔽相同值回写：额外测试发现这会在同一 run-loop 输入后立即发送、SwiftUI 合并中间状态时导致原生输入框未被清空。本轮最终实现不使用该缓存。

聊天室与 Session 复用这个输入框，因此两边都获得组词保护。不改固定四行高度、内部滚动、图片输入和 Return/Shift+Return 规则。

## 验证方式

`scripts/validation/check-composer-streaming.sh` 编译实际组件与图片输入依赖，宿主用 @State 保存草稿、ObservableObject 变化模拟输出刷新。
使用 NSTextView 的 setMarkedText/insertText 进行确定性输入，不切换用户系统输入法；不是模拟真实厂商网络输出。

检查普通文本、光标选区、未提交组词、空草稿三轮重复组词、确认后提交、外部清空/恢复、立即发送清空，以及五行内容仍在 78pt 视口内滚动。
额外验证拒绝发送仍保留草稿，以及 Session 禁用/重新启用输入框不清除已提交内容。
实际第三方输入法的候选窗口交互、切换聊天室后的草稿保留不在本轮范围。

执行结果：旧版本同一探针可复现组词丢失，修复版所有检查通过；Debug / Release 构建通过。
本轮未修改 Core；工作区里另有用户未提交的 EditSnapshotStore/测试实验代码，未纳入提交，也未作为本轮修复范围运行全量 Core 实验测试。
