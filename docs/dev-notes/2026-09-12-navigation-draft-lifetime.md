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
3. 草稿生命周期这批未修改聊天室 `userSpeak` 失败清稿问题；后续修复记录见下一节。
4. 纯 Session 热切换、实际聊天室阶段/审批、磁盘冷恢复和滚动位置的整窗组合验收仍未完成。

## 后续：聊天室发送接受边界

后续发现并复现两个相连的问题：`ChatRoomLoop.userSpeak` 先修改内存，再调用 `appendMessage`；
后者抛错时 controller 只展示错误、返回 Void，UI 无条件清空草稿并落底。
结果为输入丢失、内存出现未保存消息；用户重新输入重试后，内存历史比磁盘多一条。

修复只调整接受链路：

1. `appendMessage` 成功返回后才追加 `runtime.messages`，运行中再加入 steering 队列。
2. `ChatRoomFlowController.userSpeak` 用 `@discardableResult -> Bool` 反馈接受状态，失败仍走原 `flowError` 提示。
3. `sendUserMessage` 仅成功后清稿/落底；失败保留未经 trim 的完整草稿（成功发送内容仍沿用原 trim 规则）。
4. `updatedAt` 配置保存仍为 best-effort；消息已经保存就不能因排序元数据失败提示重发。

验证：
- 修改生产前，扩展的 `check-draft-navigation.sh` 在「聊天室发送失败保留原始草稿」处失败；
  新增 Core `ChatRoomUserSendTests` 在空闲/运行中两组的历史 ID、条数及磁盘一致性断言失败（共 6 个 issue）。
- 修复后同一 UI/Controller/Core 路径在随机临时目录上通过：失败提示、原样保稿、不增加内存消息、不落底；
  排除路径障碍后重试仅保存一次、清稿、落底，内存和磁盘 ID 一致；空稿重复提交无副作用。
- Core 另验消息已保存但配置路径不可写时不拒绝；`swift test --filter ChatRoom` 共 85 tests / 19 suites 通过，
  `check-chatroom-controller.sh` 和完整 NewPi Debug build 通过。

扩展测试提取真实聊天室提交方法，调用真实 controller/loop/store；只替换转录渲染，记录落底意图次数。
运行中 UI 分支用 `runtime.isRunning` fixture，未调用真实模型，不能据此宣称完整实时 steering 端到端验收；
既有引擎插话测试在上述 85 项回归中通过。消息和故障目录全部为临时 fixture，不动用户会话。

存储层本轮未改：现有追加使用 FileHandle，未提供部分写入回滚、断电持久保证或跨进程原子事务；
本次注入的是目标路径被目录占用、在追加前抛错的情况，不涵盖所有磁盘失败，更不是通用 exactly-once。
未重启正在运行的 App、未更新 `dist`；实际产品故障环境下的人工验收仍需另做。