# 聊天室平铺化 + Markdown 渲染复用 Session 单文档管线——实施计划

> **当前状态（2026-09-12 源码核对）：已落地，本文保留原始计划作历史对照。**
> `NewPiApp.swift` 已将聊天室放入主窗口 detail；`NewPiChatRoomStore.swift` 的
> `ChatRoomRuntimeStore` / `ChatRoomFlowController` 持有长命运行时与任务；
> `NewPiChatRoomTranscriptAdapter.swift` → `NewPiTranscriptDocumentView` 已复用单文档管线。
> 本文 Phase 0/1/2 已实施；后续组件/引擎复用 Phase A/B 见
> [复用分析](chatroom-session-reuse-analysis.md)。聊天室现已支持流式、详情组和共享 Composer，
> 下文「无流式 / 无详情组」仅是早期范围约束，不是当前限制；fork、图片附件未因此自动接通。
> 原始路径、行号、示例与验证清单保留供追溯，不能直接作为当前实现或本次验证结果。
> 本次仅核对源码与修订文档，未运行构建、测试或 UI 验收。

## 原始实施计划（历史，不再作为待执行任务）

> 两件事、一个顺序：**先平铺化**（聊天室从嵌套 sheet 并入主窗口 NavigationSplitView，
> runtime 上提为长命缓存），**再渲染复用**（消息 → `NewPiTranscriptItem` → 泛化后的
> 单文档 transcript 视图）。平铺化做完后，渲染复用就是 session 路径的镜像。

## 一、需求与决策（历史草案）

1. **聊天室对话本体平铺**：不再是 sheet，和 Session 对话一样占主窗口 detail 区。
   创建/编辑/模板管理/投票/结束讨论等**模态交互保留 sheet**（语义正确，不动）。
2. **Markdown 渲染复用 Session 方式**：复用同一份 `transcript-document.js/css` +
   本地 markdown-it/highlight.js，**不复制 JS**；新增能力（发言者标签）以新 op 字段加入，
   session 路径无此字段、零影响。
3. **角色身份呈现**：tint 按角色着色（roleID 哈希 → 色相，复用现有 `--tint` 机制）
   + 正文气泡上方一行发言者名字 caption（JS 新增 `speaker` 字段渲染）。
4. **phase 分组头进文档**：映射为 `.system` 分隔行条目，随文档统一滚动（不留原生
   section header 在 WebView 外——两套滚动源会打架）。
5. **候选方案（candidates）**：v1 拼进该条消息的 markdown body（`**候选方案**` + 列表），
   不新增 kind。
6. **聊天室无流式**：消息整条落（`ChatRoomLoop` append 完整消息），`isStreaming`
   恒 false，不涉及 delta 合并 / detail-group / streamingBubbleComplete。
7. **聊天室无 fork**：适配层产出条目的 `messageIndex` 一律 nil → `canFork` 为 false →
   JS 不渲染 Fork 按钮；`onFork` 传 nil。
8. **讨论流程不被 UI 切换打断**：runtime/loop 上提到缓存层后，切到别的 session/聊天室
   再切回，运行中的讨论继续（对齐 session「后台事件循环」语义）。

## 二、架构背景（改动前快照）

- 根结构：`NewPiApp.swift` 的 `NewPiRootView` = `NavigationSplitView`，
  sidebar（Project / Sessions / 聊天室 section，只有一个「聊天室列表」按钮）+
  detail（恒为 `NewPiChatView`）。
- 聊天室：`ChatRoomListView` 本身是 sheet（L290 `showingChatrooms`），
  `ChatRoomDetailView` 是**嵌套 sheet**（L423）。`ChatRoomRuntime` /
  `ChatRoomApprovalManager` / `ChatRoomLoop` 全是 DetailView 的
  `@StateObject/@State`（L1244-1247）——**关 sheet 即销毁运行时**，与
  「讨论是长期流程」语义冲突。
- 聊天室消息列表：SwiftUI 原生 `ScrollView + LazyVStack`，正文
  `Text(message.content)` 无 markdown；滚动靠 `ScrollViewReader.scrollTo`。
- Session 渲染管线（复用目标）：
  - `NewPiApp/NewPiTranscriptDocumentView.swift`：`TranscriptDocumentController`
    把 `[NewPiTranscriptItem]` diff → ops 下发 WKWebView；视图当前绑死
    `SessionRuntime`，但**实际只读四个值**：`runtime.transcript`、
    `runtime.isStreaming`、`runtime.streamingBubbleComplete`（updateNSView）、
    `runtime.sessionID`（makeNSView L81，注入 coordinator 供滚动锚点持久化）。
  - fork 按钮显隐由 op 的 `canFork`/`messageIndex` 字段驱动（upsertOp L297-300），
    `item.canFork = messageIndex != nil && kind ∈ {user, assistant, summary}`。
  - `ScrollPositionStore` 按 `UUID` key 持久化滚动锚点；`ChatRoom.id` /
    `ChatRoomMessage.id` 是 `String`（UUID 字符串），可 `UUID(uuidString:)` 转换。
- Core 层（`Packages/NewPiCore/Sources/NewPiCore/ChatRoom/`）逻辑不动：
  `ChatRoomLoop`（`triggerNextSpeaker` / `triggerSpeaker` / `advancePhase` /
  `stopFlow`）、`ChatRoomStore`（`listAll` / `loadMessages` / `appendMessage`…）、
  `ChatRoomRuntime`（`@Published messages/isRunning/currentSpeakerIndex`）。

## 三、实现方案

### Phase 0：泛化 `NewPiTranscriptDocumentView`（session 零行为变化，独立可提交）

把视图从「绑 SessionRuntime」改为「吃显式参数」：

```swift
struct NewPiTranscriptDocumentView: NSViewRepresentable {
    let transcript: [NewPiTranscriptItem]
    let isStreaming: Bool
    let streamingBubbleComplete: Bool
    /// 滚动锚点持久化 key（session 用 sessionID，聊天室用 chatroom UUID）。
    let storeKey: UUID?
    let controller: TranscriptDocumentController
    var tintHues: [UUID: Int] = [:]
    var restoreEntry: ScrollPositionStore.Entry?
    var onFork: ((Int) -> Void)?
}
```

- `makeNSView` 里 `coordinator.sessionID = storeKey`；`updateNSView` 改为直读参数。
- `NewPiChatView` 调用处改为显式传 `runtime.transcript` 等四个值——行为不变。
- 附件 `pi-att://` scheme handler 保留（聊天室无附件条目，handler 挂着无害）。

### Phase 1：聊天室平铺化

**A. runtime 上提（核心）**

- 新增 `ChatRoomRuntimeStore`（`ObservableObject`，挂到 `NewPiViewModel` 或独立单例，
  仿 SessionRuntime 缓存）：
  ```swift
  final class ChatRoomRuntimeStore: ObservableObject {
      /// chatroomID → (runtime, loop, approvalManager)；LRU 淘汰可后续再加。
      private(set) var runtimes: [String: ChatRoomRuntime] = [:]
      private var loops: [String: ChatRoomLoop] = [:]
      private var approvalManagers: [String: ChatRoomApprovalManager] = [:]
      private var runningTasks: [String: Task<Void, Never>] = [:]

      func runtime(for chatroom: ChatRoom) -> ChatRoomRuntime  // 有则复用，无则建并 loadMessages
      func triggerNextSpeaker(chatroomID: String)              // Task 归 store 管，与 view 生命周期解耦
      func triggerSpeaker(chatroomID: String, roleID: String)
      func advancePhase(chatroomID: String, discussionEnd: ...)
      func stopFlow(chatroomID: String)
  }
  ```
- `triggerNextSpeaker` 等方法从 `ChatRoomDetailView`（L1687-1705）搬进 store；
  view 只发意图。`ChatRoomApprovalManager` 与 runtime 的接线方式保持现状
  （现 DetailView init 里的接线逻辑原样搬到 store 的创建点）。

**B. 根视图选择模型**

- `NewPiRootView` 新增 `@State private var selectedChatroom: ChatRoom?`（或只存 id +
  查表）。选择语义互斥：
  - 点聊天室行 → `selectedChatroom = X`（session 侧保持不变，只是 detail 不再显示它）；
  - 点 session 行（`resumeSession`）→ `selectedChatroom = nil`。
- detail 区：
  ```swift
  if let chatroom = selectedChatroom {
      ChatRoomDetailView(viewModel: viewModel, chatroom: chatroom)  // 平铺版
  } else {
      NewPiChatView(viewModel: viewModel)
  }
  ```

**C. sidebar 聊天室 section 内联列表**

- 「聊天室列表」sheet 按钮删除；section 内直接 `ForEach(chatrooms)` 行
  （复用 `ChatRoomRow` 的徽章/轮数/时间展示），+ 号仍开创建 sheet。
- context menu 编辑/删除保留（编辑仍 sheet）。列表数据由 store/`ChatRoomStore.listAll()`
  驱动，选中聊天室后 runtime 的 `chatroom` @Published 变更自动反映（替代原
  `onDismiss { loadChatrooms() }` 的刷新依赖）。

**D. `ChatRoomDetailView` 去 sheet 化**

- 删 `@Environment(\.dismiss)` 与「返回」逻辑；`runtime` / `approvalManager` 改为
  `@ObservedObject`（从 store 注入）；`loop` 不再持有。
- 内部 sheet（投票/角色选择/审批/结束讨论/编辑配置）全部保留。
- 顶部工具栏（阶段推进、轮数、菜单）与输入栏原样保留——只替换消息列表区。

### Phase 2：渲染复用（消息 → transcript items 适配层）

**E. 适配层 `NewPiChatRoomTranscriptAdapter.swift`（新文件）**

纯函数 + 一个 id 映射状态（挂在 store 的 runtime 旁，或做成带缓存的 struct）：

```swift
struct ChatRoomTranscriptAdapter {
    /// 派生 id 的稳定映射：phase 头/工具卡等无原生 UUID 的条目用。
    /// key 例："phase-<首条消息id>"、"tool-<toolCallID>"。
    private var derivedIDs: [String: UUID] = [:]

    mutating func items(for messages: [ChatRoomMessage],
                        roles: [ChatRoomRole]) -> [NewPiTranscriptItem]
}
```

映射规则：

| 聊天室元素 | transcript item |
|---|---|
| `message.isUserMessage` | `.user`，id = `UUID(uuidString: message.id)!`，tint 沿用 turn 锚点逻辑（或无 tint） |
| 角色发言 | `.assistant`，body = content + candidates 的 markdown 拼接；tint = `hue(roleID)`；**op 加 `speaker: 角色名`** |
| phase 切换处 | `.system` 分隔行（body = 阶段名），id 走 derivedIDs（key = `phase-<组内首条消息id>`，插叙不漂移） |
| `toolCalls` × `toolResults` | 每个 call 一条 `.tool(name:, state: .completed(isError:))`，body = 配对 result 的 output，`toolCommand` = arguments 摘要（可复用 `newPiToolCommandSummary` 的思路，参数是 String 需先转 JSONValue 或直接单行截断） |
| `messageIndex` / `detailTurnID` | 一律 nil（无 fork、无折叠组） |

tint：`hue(for roleID:)` 用 **FNV-1a 哈希**（已与需求方确认，不用 `hashValue`——
它每次启动随机，角色着色要跨启动稳定）。

**F. JS/CSS 增量（同一份 `transcript-document.js/css`，加分支不加 fork）**

- op 新增可选字段 `speaker: String`；`renderAssistant` 有 speaker 时气泡头部标签
  （现成 `.answer-hd`，session 显示 "NewPi" 的位置）改显角色名——比新增 caption 行更简单，
  视觉一致（实现时对方案的微调）。
- `signature(...)` 把 speaker 纳入相等性（改角色名要触发重渲染）。
- 不新增 CSS（复用 `.answer-hd`）；不碰现有选择器。
- session 路径不下发 speaker 字段 → 零影响。

**G. `ChatRoomDetailView` 消息区替换**

```swift
NewPiTranscriptDocumentView(
    transcript: adapter.items(for: runtime.messages, roles: runtime.chatroom.roles),
    isStreaming: false,
    streamingBubbleComplete: true,
    storeKey: UUID(uuidString: runtime.chatroom.id),
    controller: chatroomDocController,
    tintHues: …,           // 按角色
    restoreEntry: ScrollPositionStore.shared.entry(for: chatroomUUID),
    onFork: nil
)
```

- 删掉 `ScrollView + LazyVStack` + `ChatRoomMessageView` + `PhaseHeader` +
  `groupMessagesByPhase`（分组逻辑挪进适配层）。
- 「正在思考」指示（`currentSpeaker`）保留为原生浮层，不进文档。
- 「Jump to latest」浮层按钮可一并复用（`controller.isNearBottom` +
  `scrollToBottom()`）；rail minimap v1 不接（聊天室 user 消息少，价值低）。

## 四、阶段划分与提交

| 阶段 | 内容 | 可独立提交 |
|---|---|---|
| Phase 0 | 泛化 document view（session 零回归重构） | ✅ `refactor:` |
| Phase 1 | runtime 上提 + 选择模型 + 平铺化（消息区仍是原生列表） | ✅ `feat:` |
| Phase 2 | 适配层 + JS speaker 字段 + 消息区替换 | ✅ `feat:` |

每个阶段单独可构建可回滚；Phase 1 落地后「讨论不被 UI 切换打断」即生效，
Phase 2 纯粹是渲染升级。

## 五、验证清单（原计划，非本次验证记录）

1. `cd Packages/NewPiCore && swift test`（core 不动，应全过）。
2. `./scripts/package.sh Debug` 每阶段构建通过。
3. Phase 0：session 对话全功能回归（markdown、工具卡、详情折叠组、fork、滚动恢复）。
4. Phase 1：
   - 聊天室出现在 sidebar，点击进入平铺详情；创建/编辑/删除正常；
   - 讨论运行中切到 session 再切回：流程继续、消息不丢、runtime 是同一个；
   - 阶段推进/投票/结束讨论/审批 sheet 正常。
5. Phase 2：
   - 角色发言 markdown 渲染（代码块高亮、列表、表格）；角色 tint + 名字 caption 正确；
   - phase 分隔行位置正确；工具调用卡片展示参数与结果；
   - 长讨论滚动钉底/保锚正常；关闭重开聊天室滚动位置恢复；
   - 无 Fork 按钮、无「处理详情」组；
   - session 对话无 speaker 行、零回归。
6. 提交信息：中文 conventional commit，按阶段分别提交。

## 六、已知不做（原阶段范围，部分已被后续实现取代）

- 聊天室流式渲染（core 无 delta 事件；若未来加，管线天然支持）。
- rail minimap 接入聊天室（v1 不做，接口现成）。
- detail-group 折叠、fork、附件图片——session 特有，聊天室不接。
- runtime 缓存的 LRU 淘汰（session 侧有现成策略，聊天室 v1 不淘汰，量小）。
- ChatRoom 代码从 `NewPiApp.swift` 抽离为独立文件（可做可不做，建议 Phase 1 顺手拆：
  `NewPiApp.swift` 已 1900+ 行）。
