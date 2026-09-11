# 2026-09-12 · 切换会话类型时的草稿生命周期

## 问题与证据

上一轮实机输入验收已提交为 `61259c1`，但它只验证同一面板内的侧栏收展和菜单焦点，未覆盖输入视图销毁。

- `NewPiSessionPanel` 原先用 `@State input` / `draftAttachments` 保存文本与图片草稿。
  纯 Session 热切换在保活列表内不会销毁面板；切到聊天室时，root 的条件分支会卸载整个 `NewPiChatView`。
- `ChatRoomDetailView` 原先用 `@State inputText`；`.id(chatroom.id)` 在聊天室 A→B 时强制重建详情。
- 两类运行时仍存活，输入视图本地草稿却被清空。现有输入法/流式保护不解决此生命周期问题。

隔离回归直接提取生产视图的状态声明、初始化、输入绑定及 Session 提交守卫，挂载真实 NSTextView，
使用实际 SessionRuntime 和临时存储中的 ChatRoomFlowController。切换时断言新输入框与旧实例不同。
固定旧提交 `NEWPI_DRAFT_REVISION=61259c1` 编译成功后，在 **Room A→B→A 草稿保留**断言失败；
同一回归的工作区修复版通过。不把编译错误或焦点问题当作缺陷复现。

## 修复

`NewPiComposerDraft` 是独立 `@MainActor ObservableObject`，包含文本和图片草稿数组。
每个 SessionRuntime / ChatRoomFlowController 分别持有自己的实例，输入面板通过 `@ObservedObject` 绑定。

- 视图卸载、重建时重新绑定同一份运行时草稿，不把所有详情改为常驻，也不修改 WebView/滚动生命周期。
- 父运行时、控制器与根列表不转发草稿的 `objectWillChange`；逐键输入不会新增父级通知。
- 普通会话仍在发送被接受后才清空文本与图片；发送拒绝和运行中提交保留草稿。
- 聊天室仍保留 Return 插话及既有发送行为；本次不新增聊天室图片能力。
- 不写磁盘、不加入 transcript、不执行模型或工具，不扩大运行时缓存上限。

## 验证结果

仓库根目录运行 `bash scripts/validation/check-draft-navigation.sh`：

- Room A→B→A、Room→Session→Room 文本保留且隔离。
- Session→Room→Session 文本和图片草稿保留；Session A→B→A 强制重建后保留。
- 新 Session 不串入旧内容；接受发送只清当前 Session，不影响另一个 Session。
- Session 发送拒绝、运行中提交不清草稿。
- 输入和图片草稿改变时，SessionRuntime / ChatRoomFlowController / 根列表通知计数为 0。

其他实跑：完整 NewPi Debug build、`check-chatroom-controller.sh`、
`NEWPI_EXPECT_DRAFT_FIX=1 check-composer-streaming.sh`、
`NEWPI_EXPECT_FILTERED_NOTIFICATIONS=1 check-chatroom-performance.sh` 均通过。
性能守卫的短/长/多工具三场景均为 100 次详情更新、0 次根列表通知，不宣称性能提升。

回归使用受控 fixture：Session 不启动事件循环，provider 被调用即失败；聊天室无配置角色，不推进发言。
发送后端只模拟接受/拒绝，附件为合成字节，只验证绑定/生命周期，不验证采集、解码或真实落盘。
未对用户真实会话执行切换/发送，未重启正在运行的 App，未替换 `dist`；正式整窗导航与滚动恢复仍待验收。

## 保留边界与后续

1. 仅保证持有者仍在内存期间保留草稿。Session LRU 淘汰、切项目、关闭运行时，聊天室删除或退出 App 后不保留。
   若需跨这些边界保留，应另行设计轻量草稿存储，不能简单无限保活所有 WebView。
2. 保存已提交到 Binding 的文本；未提交 marked text、光标/选区、撤销栈及尚未完成的异步图片采集不保证跨重建保留。
3. 聊天室 `userSpeak` 吞下持久化错误后 UI 仍清稿是既有问题，本次未改；需要单独设计发送接受反馈及失败重试语义。
4. 纯 Session 热切换、实际聊天室阶段/审批、磁盘冷恢复和滚动位置的整窗组合验收仍未完成。