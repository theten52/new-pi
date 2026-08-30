# NewPi 需求交接：Agent 处理详情折叠（处理详情组）

> 参考行为（截图产品）：agent 的中间过程（思考 / 工具调用 / 中间回复）聚合为一条可折叠的
> 「处理详情」disclosure 行，最终答复单独展示在组外。

## 一、需求（已与需求方逐条确认）

1. **分组范围**：以 turn 为单位（一条 user 消息 → 下一条 user 消息之间）。
   组内：thinking 条目、tool 工具卡、**中间 assistant 正文**（turn 内除最终答复外的 assistant 消息）。
   组外：最终答复（turn 内最后一条、且无后续工具调用的 assistant 消息）。
2. **自动展开**：新 turn 开始（用户发送消息）→ 该 turn 的详情组自动展开。
3. **自动收起**：**最终答复完整落定时**收起。判定信号已有现成实现：
   `messageEnd(assistant)` 且 `assistant.toolCalls.isEmpty`（即 `SessionRuntime.finalAnswerComplete = true` 的置位点，
   见 `NewPiViewModel.handle(event:on:)` 的 `.messageEnd` 分支，BACKLOG-STATUS-READY-LAG 注释处）。
   ❗不是「开始流出就收起」——需求方最终选择了落定收起（更简单、无翻转）。
4. **手动维度独立**：用户点击展开/收起后，该组一切自动逻辑失效（无论最终答复落定前后），
   以手动为准。每组一个 `manualOverride` 标记。新一轮（新 turn）是新组，自动逻辑重新生效。
5. **统计计数不实现**：disclosure 行只显示「处理详情」，不做「N 条消息 · M 次工具调用」（需求方明确暂缓）。
6. **恢复旧会话**：所有历史详情组默认收起；手动状态不持久化、不跨会话保留。
7. **流式期间组内容持续增高**：沿用现有钉底/保锚纪律，不做特殊处理。
8. **折叠实现约束**：用 CSS class + `display:none` 切换，**DOM 保持扁平、不搬动节点**，
   **不碰 content-visibility 高度缓存**（滚动跳变刚修过一系列，见
   `docs/dev-notes/2026-08-30-transcript-scroll-jump.md`、
   `docs/dev-notes/2026-08-29-render-replay-windowing-scroll-restore.md`）。

## 二、架构背景（必读）

项目是 macOS 编码 agent（SwiftUI + AppKit + WKWebView），核心渲染架构是**单文档 transcript**：

- 整条会话渲染进**一个** WKWebView。
- `NewPiApp/NewPiViewModel.swift`：维护 `[NewPiTranscriptItem]`（typed item，kind 为
  `user / assistant / thinking(isStreaming:) / tool(name:state:) / system / summary / error`）。
  事件处理入口 `handle(_ event: AgentEvent, on runtime: SessionRuntime)`。
  每条会话一个 `SessionRuntime`（独立转录/流式状态/事件循环）。
- `NewPiApp/NewPiTranscriptDocumentView.swift`：`TranscriptDocumentController` 把 transcript
  **diff → ops** 下发给 WebView（原生不感知布局/高度）。
- `NewPiApp/MarkdownRenderer/transcript-document.js`：`upsert/applyOps` 按条目 id 就地更新 DOM；
  渲染分发 `renderUser / renderAssistant / renderCard(工具) / renderSystemLike`；
  内含**文档内滚动状态机**（唯一 scroll writer：意图驱动、同批同步保锚、RAF 锚点恢复）。
- `NewPiApp/MarkdownRenderer/transcript-document.css`：单文档样式。
- 事件流：`agentStart` →（thinkingDelta / textDelta / toolExecutionStart / toolExecutionEnd 多轮）→
  `messageEnd(assistant)` → `agentEnd`。
- 历史重建：`makeTranscriptItems(from:entryIDs:)`（冷恢复）与 `rebuildTranscript(from:entryIDs:on:)`
  （fork / agentEnd 同步），两者都要处理分组。
- `rebuildTranscript` 有条目 id 保留逻辑 `preservedTranscriptID`（按 messageIndex / sessionEntryID
  保留 UUID，避免 DOM 重建）——改动时不要破坏它。

构建/测试（仓库根目录）：
- 核心库测试：`cd Packages/NewPiCore && swift test`
- App 构建：`./scripts/package.sh Debug`（必须在仓库根目录跑）
- 提交信息风格：中文 conventional commit（如 `feat: xxx` / `fix: xxx`）。

## 三、实现方案

### A. 数据模型（`NewPiApp/NewPiViewModel.swift`）

1. `NewPiTranscriptItemKind` 新增 case：
   ```swift
   /// 处理详情组的 disclosure 行（BACKLOG-DETAIL-GROUP）。collapsed 为自动逻辑的目标状态，
   /// JS 侧在未手动覆盖时采纳。
   case detailGroup(collapsed: Bool)
   ```
   `title` 派生属性补 `case .detailGroup: "处理详情"`。
2. `NewPiTranscriptItem` 新增字段 `detailTurnID: String? = nil`（非 nil 表示该条目属于某个详情组）。
3. `SessionRuntime` 新增 turn 状态：
   ```swift
   var detailTurnID: String?          // 当前 turn id；nil = 不在 turn 中
   var detailGroupMarkerID: UUID?     // 当前 turn 的 disclosure 行条目 id
   var detailMarkerIDs: [String: UUID] = [:]  // turnID → marker 条目 id（跨 rebuild 复用，防闪烁）
   ```
4. turnID 规则：live turn 用 `"live-<UUID()>"`；历史重建用 `"turn-<user消息entryID ?? index>"`
   （**必须确定性**，JS 端的 manualOverride 以 turnID 为 key，rebuild 后要能命中）。

### B. 事件逻辑（`NewPiViewModel`）

1. `send(_:)`：`runtime.detailTurnID = 新live turnID`，`detailGroupMarkerID = nil`。
2. **marker 懒创建**：向组内追加第一个条目（thinking / tool / 中间 assistant）前，
   若 `detailGroupMarkerID == nil`，先 append marker 条目
   （kind `.detailGroup(collapsed: false)`，body 空，detailTurnID = 当前 turn），记录其 id。
   （marker 必须先于组内条目出现在扁平数组中。无中间过程直接出答复的 turn 没有 marker，正常。）
3. 组内条目打标：
   - `appendOrUpdateThinking`：thinking 条目带 `detailTurnID`。
   - `.toolExecutionStart` / `.toolExecutionEnd`：tool 条目带 `detailTurnID`。
   - `appendOrUpdateAssistant`：流式正文条目**先带** `detailTurnID`（默认假定是中间消息；
     组在流式期间是展开的，所以用户照样实时看到）。
4. `.messageEnd(message)` 分支（现有 `finalAnswerComplete` 置位处）：
   - 若 `assistant.toolCalls.isEmpty`（最终答复）：
     a. 把该 streaming assistant 条目的 `detailTurnID` 置 nil（移出组；DOM 不动只改 class，
        视觉上它留在原位置、组收起后它是组后第一条可见内容）；
     b. marker 条目更新为 `.detailGroup(collapsed: true)`（同 id 替换，走 upsert）。
   - 若有 toolCalls：什么都不做（条目留在组内，组保持展开）。
   - ❗**最终答复位置（决策 1，已确认）**：最终答复**留在原数组位置**（组内条目末尾），
     仅改 `detailTurnID` 标记为 nil 表示移出组，**不重排序、不搬动 DOM 节点**。
     折叠后它自然显示在 marker（"处理详情"行）之后，作为该 turn 的第一条可见内容。
   - ❗**置 nil 与流式 flush 的时序（决策 2，已确认）**：`messageEnd` 之后正常不再有
     textDelta；实现时在 `messageEnd` 置 nil 后禁止该 assistant 条目再次被
     `appendOrUpdateAssistant` 重新带进组（加一道屏障/标志，确保置 nil 是最终态）。
     否则若残余 delta 又把它当作组内条目重建，移出动作会被覆盖。
5. error / system / summary 条目：不进组（`detailTurnID = nil`）。
6. `abort()`：保持组展开（用户能看到进行到哪），marker 不收起。
   - ❗**abort 与 B.4 收尾动作互斥（决策 3，已确认）**：abort 是主动取消，不走
     `.messageEnd` 落定路径，因此 `finalAnswerComplete` **不置位**、B.4 的收尾动作
     （最终答复置 nil + marker 置 collapsed）**不执行**。组保持流式期间的展开态，
     用户能看到中止时的中间进度。

### C. 历史重建（`makeTranscriptItems` 与 `rebuildTranscript` 两处都要）

按消息序列重建分组：
- 遇 `.user` 开新 turn（turnID 按 A.4 规则）。
- turn 内：
  - `assistant.reasoningContent` 非空 → thinking 条目（组内）。
  - `assistant.toolCalls` 非空 → 中间 assistant（组内）。
  - `.toolResult` → 组内。
  - turn 内**最后一条** `toolCalls.isEmpty` 的 assistant → 最终答复（组外）。
    （判定简化：assistant 无 toolCalls 即最终答复；同 turn 内理论上只有一条。）
- 每个含 ≥1 组内条目的 turn：在 user 条目之后插入 marker，`.detailGroup(collapsed: true)`
  （恢复默认收起），marker 条目 id 从 `runtime.detailMarkerIDs[turnID]` 复用（没有则新建并缓存）。
- `preservedTranscriptID` 逻辑不动。

### D. ops 序列化（`NewPiApp/NewPiTranscriptDocumentView.swift`）

- op payload 增加 `detailTurnID: String?`；`detailGroup` kind 的 op 增加 `collapsed: Bool`。
- diff 逻辑必须感知这两个字段的变化（marker 的 collapsed 翻转、assistant 条目 detailTurnID
  置 nil 都要触发 update op）——若现有 diff 只比 body/kind，需要把这两个字段纳入相等性判断。

### E. JS 渲染（`NewPiApp/MarkdownRenderer/transcript-document.js`）

1. `upsert` 分发新增 `detailGroup` 分支 → `renderDetailGroup(el, op)`：
   disclosure 行（chevron ▸/▾ + 文本「处理详情」），`data-turn-id = op.detailTurnID`。
2. 组内条目：`el.classList.add('detail-item')`，`el.dataset.turnId = op.detailTurnID`；
   若该 turn 当前是 collapsed，立即加 `detail-hidden` class（新条目到达也要遵守组状态）。
   detailTurnID 从有变无（最终答复移出组）时：移除 `detail-item` / `detail-hidden` / data 属性。
3. 组状态（模块级，页面生命周期内有效）：
   ```js
   const groupState = {};      // turnID → bool collapsed
   const manualOverride = {};  // turnID → true
   function applyGroupState(turnID) { /* 遍历 [data-turn-id] 的 .detail-item，按 groupState 切 detail-hidden；
                                       同步更新 marker 行 chevron */ }
   ```
4. marker op 到达/更新：`if (!manualOverride[turnID]) { groupState[turnID] = op.collapsed; applyGroupState(turnID); }`
5. marker 行 click：`groupState[turnID] = !current; manualOverride[turnID] = true; applyGroupState(turnID);`
   （不回传原生——手动状态不持久化，原生也无需感知。）
6. 滚动纪律：折叠/展开改变文档高度，确保 ops 应用仍在既有 beginBatch/endBatch 保锚管线内
   （不要在 click handler 里直接读写 scrollY 之外的状态；display 切换交给状态机的下一帧保锚即可，
   如有跳动，参考既有 `lockIntrinsicHeight` 思路，但默认先不做额外处理——需求 7）。

### F. CSS（`NewPiApp/MarkdownRenderer/transcript-document.css`）

- `.t-detail-row`：次级文本色、整行可点击、hover 态、chevron 旋转过渡（▸↔▾ 或 transform rotate）。
- `.detail-hidden { display: none; }`

### G. Spike 窗口兼容

`NewPiApp/NewPiSpikeTranscriptView.swift` 复用同一渲染管线的话，确认其模拟数据不含 detailGroup
kind 即可；若 spike 的 JS 分发走同一 `upsert`，新增分支不能影响既有 kind。

## 四、验证清单

1. `cd Packages/NewPiCore && swift test`（core 未动，应无回归；当前 174 个测试全过）。
2. `./scripts/package.sh Debug` 构建成功。
3. 手动验证：
   - 新提问：流式期间详情组展开，thinking/工具卡实时可见；
   - 最终答复落定：组自动收起，答复完整显示在组外；
   - 收起后点击展开 → 再发一轮 → 新一轮组重新自动展开；
   - 流式期间手动收起 → 答复落定后不覆盖手动状态（保持收起）；
   - 展开状态下手动操作同理；
   - 恢复旧会话：历史组全部收起，可手动展开；
   - fork 会话后分组仍然正确；
   - 折叠/展开时滚动位置不跳（钉底时保持钉底）。
4. 提交：中文 conventional commit，如
   `feat: agent 处理详情按 turn 折叠——流式自动展开、答复落定自动收起、手动覆盖优先`。

## 五、已知不做的事

- 统计计数（N 条消息 · M 次工具调用）——需求方明确暂缓。
- 手动状态持久化 / 跨会话保留——不做。
- thinking 条目单独的二级折叠——组内原样平铺。
