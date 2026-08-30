# 旧对话「从中间截断、只显示最近几轮」根因分析

> 状态：已修复（方案 A，选项 1）。详见「六、修复结论」。

## 一、现象（用户报告，逐条核实）

同一个 session 内多轮长对话：

1. 旧的几轮对话看不到，只有最后一轮（及最近几轮）在展示。
2. 截断点发生在某个 agent 输出的**中间**（不是 turn 边界，也不是「处理详情」折叠行）。
3. 最后一轮内容很长，展示的部分也很长。
4. 新起的对话正常展示，旧的历史对话消失。

**关键排除**：这**不是** BACKLOG-DETAIL-GROUP（处理详情折叠）的问题。折叠只影响
thinking / 工具卡 / 中间 assistant 的 display 状态，且有「处理详情」disclosure 行；
而本现象是整段 transcript 被截断、前面内容凭空消失。

## 二、根因：compaction（上下文压缩）触发后 UI 用截断后的 messages 重建 transcript

### 完整链条

1. **触发条件**：会话输入 token 估算值 ≥ `triggerTokenCount`。
   默认 `CompactionConfig` = `contextTokenLimit 96_000 × triggerRatio 0.75 = 72_000`，
   `keepRecentMessages = 8`（见 `CompactionConfig.swift`）。

2. **压缩动作**（`CompactionService.compactIfNeeded`，L41-43）：
   ```swift
   let summaryMessage = AgentMessage.compactionSummary(summary)
   context.messages = [summaryMessage] + toKeep   // 历史 → 1 条 summary + 最近 8 条
   ```
   即 LLM 的上下文数组被「原地替换」为 `[摘要] + 最近 8 条消息`，前面几十轮全部压缩。

3. **切分点不确定**（`CompactionService.partition`，L53-56）：
   ```swift
   var splitIndex = messages.count - keepRecent   // 默认 = count - 8
   while splitIndex > 0, case .toolResult = messages[splitIndex] {
       splitIndex -= 1                            // 避免从 toolResult 切，向前找非 toolResult
   }
   ```
   切分点可能落在某个 **assistant turn 的中间**（例如一条 assistant 输出被切成
   前半截进压缩区、后半截保留）。这正是「截断发生在 agent 输出的中间」的直接原因。

4. **UI 不同步**：`NewPiViewModel.handle` 的 switch **没有 `contextSnapshot` case**
   （走 `default: break`）。compaction 发生时，UI 只通过
   `.messageStart(.compactionSummary)` **追加**了一条 summary 条目（L1281-1290），
   旧 transcript 条目此刻仍在，尚未被删。

5. **agentEnd → 重建**（`handle` L1392 → L1400 `syncTranscriptMessageIndices` →
   `rebuildTranscript`）：用**已经被压缩截断的** `context.messages`
   （`[summary] + 最近 8 条`）重建 transcript。

6. **diff remove 删除旧条目**：`applyLoaded`（`NewPiTranscriptDocumentView.swift`
   L188-191）发出 `remove` op，把所有不在新 snapshot 里的旧 transcript 条目删除。
   最终用户看到「旧对话从中间消失、只留最近几轮」。

### 与用户三个观察的对应

- ✅ 旧的看不到、新的能看到 → compaction 只留最近 8 条。
- ✅ 从 agent 输出中间截断 → `partition` 的 splitIndex 落在 turn 中间。
- ✅ 最后一轮很长且展示很长 → 最近的消息都在、未受影响。

## 三、已有证据支撑

- `docs/dev-notes/2026-08-27-code-review-findings.md` L31-32 早已记录：
  > compaction 把消息数组换成 `[summary] + toKeep`（变短且首元素变化）……
- 同文件 L104（`UI-1`）：
  > 「输出截断提示」追加后立刻被 `rebuildTranscript` 全量重建擦除，永不显示。
  即「compaction → rebuild 擦掉历史展示」这一 symptom 早有记录，只是当时未与
  「历史对话消失」这个用户视角关联起来。

## 四、关键代码位置

| 文件 | 位置 | 作用 |
| --- | --- | --- |
| `Packages/NewPiCore/.../Compaction/CompactionConfig.swift` | L12-27 | compaction 默认配置（enabled、72k 触发、留 8 条） |
| `Packages/NewPiCore/.../Compaction/CompactionService.swift` | L13-45 | `compactIfNeeded` 压缩并原地替换 `context.messages` |
| `Packages/NewPiCore/.../Compaction/CompactionService.swift` | L47-63 | `partition` 切分点（落在 turn 中间的原因） |
| `Packages/NewPiCore/.../AgentLoop.swift` | L59-63 | 每轮 run 开头调用 `compactIfNeeded` |
| `NewPiApp/NewPiViewModel.swift` | L1281-1290 | `.messageStart(.compactionSummary)` 追加 summary 条目 |
| `NewPiApp/NewPiViewModel.swift` | L1266-1417 | `handle` switch，**无 `contextSnapshot` case** |
| `NewPiApp/NewPiViewModel.swift` | L1392-1403 | `agentEnd` → `syncTranscriptMessageIndices` → rebuild |
| `NewPiApp/NewPiViewModel.swift` | L1448-1574 | `rebuildTranscript`（用截断后的 messages 重建） |
| `NewPiApp/NewPiTranscriptDocumentView.swift` | L188-191 | diff remove op 删除不在新 snapshot 的旧条目 |

## 五、修复方案（已决策）

用户确认走**选项 1**：UI transcript 保留完整旧对话可视内容，compaction 只在「发给 LLM 的
`context.messages`」里压缩，UI 展示与 LLM 上下文解耦。

## 六、修复结论

关键词：**backlog `BACKLOG-FORK-COMPACT-HISTORY`**（见 `TODO.md`）。

### 方案 A：agentEnd 就地校准，不再全量重建清空

`agentEnd` 触发的 `syncTranscriptMessageIndices`（`NewPiViewModel.swift`）原先直接
`rebuildTranscript`——用已经截断的 `context.messages` 重建 transcript，被压缩历史据此丢失。
现改为调用新增的 `calibrateTranscriptAfterAgentEnd`：

- **无 compaction**（`messages.first ≠ .compactionSummary`）：保持原 `rebuildTranscript`
  全量重建行为（安全，不会丢历史）。
- **有 compaction**：定位 transcript 里最后一个 `.summary` 条目（live 期由
  `.messageStart(.compactionSummary)` 追加），以它下标作为 `preservedPrefixCount` 传入
  `rebuildTranscript`，保留它**之前**的完整旧历史，只重建 summary 及其后的尾巴
  （`[summary] + 最近8条`）。

### `rebuildTranscript` 增加 `preservedPrefixCount` 参数

保留前缀时 `removeAll()` 改为 `removeSubrange(preservedPrefixCount...)`；并且只让
`existingByMessageIndex` 基于被重建的后半段构建，避免「被压缩旧历史的 messageIndex
（0..N-1）与重建尾巴里从 0 重新排的 index 空间重叠」造成 id 误命中。

### 已知限制

fork + compaction 叠加仍无法恢复被压缩历史（fork 路径保留全量重建，而
`context.messages` 已不含完整历史），已作为 `BACKLOG-FORK-COMPACT-HISTORY`（P2）记录。
当前无实际触发路径（`forkFromMessage` 尚无 Swift 调用者）。

### 验证

- `NewPiCore` compaction 相关 6 项测试通过。
- `NewPiCore` 全量 174 项测试、58 suite 全部通过。
- `xcodebuild -scheme NewPi` 构建通过。

## 七、备注

- 本次排查过程中一度误判为「中间 assistant（toolCalls 非空且 text 非空）正文被折叠
  隐藏」，已排除——那是 BACKLOG-DETAIL-GROUP 的设计行为（折叠中间正文），与本现象
  （整段截断）不同，勿混淆。
- 「折叠」本身用户已确认为设计行为（方向 B），与 compaction 截断是两个独立问题。
