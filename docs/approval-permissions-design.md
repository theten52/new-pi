# NewPi 权限管理设计文档

> 状态：已实施（2026-08 更新：整类工具授权记忆 + 危险评估降噪 + Sheet UI 重做）
> 目标：实现三档允许粒度（一次/本对话/一直）的权限管理，并引入危险等级评估与持久化。

---

## 1. 需求回顾

1. 审批弹窗提供三个允许按钮：
   - **一次允许**（`once`）：仅本次调用生效。
   - **本对话一直允许**（`session`）：当前 `AgentSession` 生命周期内生效。
   - **一直允许**（`forever`）：跨 Session、跨 APP 启动持久化生效。
2. 对命令/参数做**危险等级评估**：
   - 危险等级高的操作，即使选择了「本对话一直允许」或「一直允许」，**仍需再次提示**（不可被永久跳过）。
3. 审批弹窗需显示**危险级别图标 + 危险提示信息**。
4. Settings 中可配置危险评估模式与规则阈值。

---

## 2. 现状与痛点

当前 `NewPiToolApprovalSheet` 只有 **Deny / Allow** 两个按钮；`AgentSession.respondToToolApproval` 审批通过后会把整个工具名（`write`/`edit`/`bash`/`subagent`/MCP）标记为本 Session 永久允许（`ToolApprovalTracker`，`Set<String>`，内存态）。

问题：
- 无一次/本对话/一直的粒度区分。
- 无危险评估，`rm -rf` 与普通命令同等对待。
- `ToolApprovalTracker` 为内存态，无法跨 Session / APP 重启持久化。
- 拦截粒度仅为「工具名」，无法区分同一工具的不同参数（例如不同的 bash 命令）。

---

## 3. 核心概念

### 3.1 允许粒度

```swift
public enum ApprovalScope: String, Sendable, Equatable, Codable {
    case once      // 一次允许：仅本次调用
    case session   // 本对话一直允许：当前 AgentSession
    case forever   // 一直允许：跨 Session / APP 重启
}
```

### 3.2 危险等级

```swift
public enum ToolDangerLevel: Int, Sendable, Equatable, Comparable, Codable {
    case low = 0     // 读取类
    case medium = 1  // 写入文件、常规命令
    case high = 2    // 删除、提权、磁盘操作、强制推送、下载执行等
}
```

---

## 4. 危险等级评估

### 4.1 评估策略：本地规则为主 + LLM 补充 + 缓存

采用**混合方案**：

| 层 | 作用 | 判定 | 是否调 LLM |
|---|---|---|---|
| ① 本地高危规则 | `rm -rf`（危险目标）、`sudo`、`git push --force`、`curl|sh`、磁盘/设备操作 | 命中 → 规则等级（确定） | 否 |
| ①.5 只读 bash 识别 | 整段命令均由已知只读命令组成（ls/find/cat/grep/git status…），无写入重定向、无命令替换、find 无 -exec/-delete、git 为只读子命令 | → **LOW** | 否 |
| ② 工具类型基线 | `read`=low，`write`/`edit`/`bash`/`subagent`=medium，MCP=medium | 返回基线等级 | 否 |
| ③ LLM 补充（可选） | 对 ①② 未覆盖/需语义判断的命令做补充评估 | 返回等级+原因 | 是（可配置开关） |
| ④ 缓存 | 按 `工具名 + 参数指纹` 缓存评估结果 | 命中直接返回 | 否 |

**安全原则**：
- 本地规则命中即判定为 HIGH，**永不调 LLM、永不降级**——这是权限兜底，必须确定性。
- LLM 评估仅作为**可选增强**，默认关闭；开启后若 LLM 调用失败，**降级为工具基线等级（medium），绝不降为 low**。

### 4.2 本地危险规则（bash 重点）

规则匹配前先**剥离 shell 字符串字面量**（单/双引号内容），避免仅「提及」危险词
的命令被误判高危（如 `grep "sudo"`、`git commit -m "rm -rf 用法"`）。

`rm` 递归强制删除**按目标分级**：目标是 home/根/上级/绝对路径 → 高危（每次强制
确认）；项目内相对路径（如 `rm -rf build/`）→ 中危，可被授权记忆。
`docker rm/rmi` 为中危，`docker system prune` 为高危。
当前规则集以代码为准：`ApprovalPolicy.defaultRiskRules`。

### 4.3 参数指纹

```swift
struct ToolApprovalFingerprint {
    static func make(arguments: JSONValue) -> String
    // 对 JSON 做稳定排序后 SHA256，作为危险评估缓存 key
}
```

> 注：指纹不再用于授权记录匹配——session/forever 授权按整类工具记忆（见 §5）。

### 4.4 参数别名共用解析

bash 执行端接受 `cmd`/`script` 别名，read/write/edit 接受 `file_path`/`filePath`
别名。`DangerEvaluator` 与 `ToolApprovalSummary` 通过 `ToolArguments.optionalString`
与执行端共用同一份别名表，避免别名绕过评估或审批摘要显示 `?`。

---

## 5. 审批跟踪器（支持持久化 + 三档粒度）

重写 `ToolApprovalTracker`：

```swift
public struct ApprovalRecord: Sendable, Equatable, Codable {
    public var toolName: String
    public var parametersFingerprint: String?  // nil = 整类工具
    public var scope: ApprovalScope
}

public actor ToolApprovalTracker {
    private var sessionRecords: [String: ApprovalRecord] = [:]
    private let store: PersistentApprovalStore      // 永久记录
    private let dangerCache: DangerAssessmentCache  // 评估结果缓存
    
    public func isAuthorized(tool: String, args: JSONValue) -> Bool
    public func record(scope: ApprovalScope, tool: String, args: JSONValue, danger: DangerAssessment)
}
```

**授权粒度**：`session`/`forever` 记录按**整类工具**记忆（`parametersFingerprint = nil`）
——用户选择「本对话一直允许 bash」后，本对话内 bash 的非高危调用不再弹窗。
早期版本按精确参数指纹记忆，每条新命令都重新弹窗，等同失效，已废弃。

**授权判定流程**（`isAuthorized`）：

```
输入 (tool, args)
  ├─ danger = dangerCache / DangerEvaluator.evaluate(tool, args)
  ├─ danger.level == .high
  │     └─ 直接返回 false（即使有 forever 记录也必须重新提示）
  └─ danger.level < .high
        ├─ sessionRecords 命中（scope=session）→ true
        ├─ store.foreverRecords 命中（scope=forever）→ true
        └─ 未命中 → false
```

---

## 6. 持久化：PersistentApprovalStore

- 存储位置：`~/.new-pi/agent/approvals.json`（与 `providers.json`/`mcp.json` 一致）。
- 仅持久化 `scope = .forever` 的记录。
- 结构：

```json
{
  "approvals": [
    {
      "toolName": "bash",
      "parametersFingerprint": "<sha256>",
      "scope": "forever",
      "createdAt": "2026-08-26T00:00:00Z"
    }
  ]
}
```

```swift
public final class PersistentApprovalStore: @unchecked Sendable {
    public func saveForever(_ record: ApprovalRecord)
    public func removeForever(toolName: String, fingerprint: String?)
    public func foreverRecords() -> [ApprovalRecord]
}
```

---

## 7. 数据链路改造

### 7.1 ToolApprovalRequest 增加危险字段

```swift
public struct ToolApprovalRequest {
    public var id: String
    public var toolName: String
    public var arguments: JSONValue
    public var summary: String
    public var dangerLevel: ToolDangerLevel    // 新增
    public var dangerReason: String?           // 新增
    public var parametersFingerprint: String   // 新增
}
```

`AgentLoop.executeToolCalls` 构造 request 时由 `DangerEvaluator` 填充。

### 7.2 AgentSession.respondToToolApproval 支持 scope

```swift
public func respondToToolApproval(
    requestID: String,
    approved: Bool,
    scope: ApprovalScope = .once
) async
```

- `.once` → 仅放行本次（不写 tracker）。
- `.session` → 写入 session 层 tracker。
- `.forever` → 写入 session + `PersistentApprovalStore`。
- 若 `danger.level == .high`，即使 scope 为 `.session`/`.forever`，**也不写入 tracker/持久化**（只放行本次），保证下次调用仍提示。

### 7.3 AgentLoop 授权逻辑

```
toolPolicy.requiresApproval(tool)?
  ├─ 否 → 直接执行
  └─ 是 → danger = DangerEvaluator.evaluate(tool, args)
           ├─ danger.level == .low（只读）→ 直接执行，不弹审批（与 read 工具一致）
           └─ 否则 → isAuthorized(tool, args)?
                      ├─ true  → 直接执行
                      └─ false → yield(.toolApprovalRequired(request 含危险信息))
                                  → await requestToolApproval(request)
                                  → 用户返回 (approved, scope)
                                  → 写 tracker（high 则仅本次）
```

---

## 8. UI：NewPiToolApprovalSheet

```
┌──────────────────────────────────────────────────┐
│  [图标] 高风险操作 · 需再次确认                     │
│         [BASH] [高风险]                            │
│  ┌────────────────────────────────────────────┐  │
│  │ Run command:                               │  │
│  │ rm -rf ~/important                         │  │  ← 等宽内容块
│  └────────────────────────────────────────────┘  │
│  ⚠ 递归强制删除 home/根/上级目录                  │  ← 危险横幅
│                                                  │
│  ────────────────────────────────────────────    │
│  [拒绝]          [不再询问…▾] [允许一次(默认)]     │
└──────────────────────────────────────────────────┘
```

- **头部**：危险图标（彩色圆角底）+ 标题 + 工具名 chip + 危险等级胶囊（红/橙/绿）。
- **内容块**：等宽、圆角描边、可选中复制，超高滚动。
- **危险横幅**：显示 `dangerReason`（浅色危险色底）。
- **操作行**：`拒绝`（Esc）／`允许一次`（主按钮，Enter）／`不再询问…` 菜单
  （`本对话中不再询问 {tool}` = session、`一直允许 {tool}` = forever，按整类工具记忆）。
- **高风险**：不显示「不再询问」菜单，并提示「后续每次执行仍会再次确认」；
  点击允许后本次放行但不写 tracker/持久化。

---

## 9. Settings 可配置项（危险评估）

在 `NewPiSettingsView` 新增「危险评估」区块：

| 配置项 | 类型 | 默认值 |
|---|---|---|
| 危险评估模式 | 下拉 | 仅本地规则 |
| LLM 补充评估 | 开关（可选增强，消耗 token） | 关 |
| 高危险规则集 | 管理（查看/自定义导入导出 JSON） | 内置规则 |
| 工具审批基线 | 每个工具可选 low/medium/high | 见基线表 |
| 重置规则 | 恢复默认 | — |

持久化到 `~/.new-pi/agent/approval-policy.json`，`DangerEvaluator` 从该配置初始化规则与基线。

---

## 10. 实施计划

| 步骤 | 内容 | 文件 |
|---|---|---|
| 1 | 枚举 `ApprovalScope`、`ToolDangerLevel` | `Tools/ToolPolicy.swift`（或 `Tools/Approval.swift`） |
| 2 | `DangerEvaluator` + `DangerAssessment` | `Tools/DangerEvaluator.swift` |
| 3 | `ToolApprovalFingerprint` | `Tools/ToolPolicy.swift` |
| 4 | `PersistentApprovalStore` | `Tools/PersistentApprovalStore.swift` |
| 5 | `PersistentApprovalPolicyStore`（Settings 规则） | `Tools/ApprovalPolicy.swift` |
| 6 | `ToolApprovalTracker` 升级（scope + 持久化 + 缓存） | `Tools/ToolPolicy.swift` |
| 7 | `ToolApprovalRequest` 增字段 | `Tools/ToolPolicy.swift` |
| 8 | `AgentLoop` 挂载评估 + scope 授权 | `AgentLoop.swift` |
| 9 | `AgentSession.respondToToolApproval(scope:)` | `AgentSession.swift` |
| 10 | UI 重写审批 Sheet | `NewPiApp/NewPiToolApprovalSheet.swift` |
| 11 | `NewPiViewModel.approvePendingTool(scope:)` | `NewPiApp/NewPiViewModel.swift` |
| 12 | Settings 危险评估区块 | `NewPiApp/NewPiSettingsView.swift` |
| 13 | 单元测试 | `Tests/NewPiCoreTests/` |

---

## 11. 风险与边界

- **LLM 评估默认关闭**：本地规则已覆盖绝大多数高危场景；LLM 仅作可选增强，避免权限判定依赖不稳定模型。
- **LLM 失败降级为 medium**：绝不降为 low。
- **HIGH 不可被持久化跳过**：即使「一直允许」，HIGH 每次仍强制提示。
- **MCP 工具**：默认 medium，命中危险关键词升为高；MCP 工具名带 server 前缀，`DangerEvaluator` 需解析。
- **并发**：`ToolApprovalTracker`/`PersistentApprovalStore` 为 actor/lock 保护，`DangerAssessmentCache` 用 actor（LRU 上限 512）。

---

## 12. 审批审计日志（ToolApprovalAuditLogger）

每次工具调用（无论是否弹窗）记录一条 JSONL，供事后 review 权限设计是否合理：

- **存储**：`~/.new-pi/agent/approval-audit.jsonl`；超过 10MB 轮转为 `.1`（保留一代）。
- **接线**：`AgentLoopConfig.auditLogger`（`AgentSession` 默认启用）→ `ToolContext`
  透传 → `SubAgentTool` 子代理同样记录。
- **字段**：

| 字段 | 含义 |
|---|---|
| `timestamp` / `workingDirectory` / `callID` / `toolName` | 调用定位 |
| `arguments` / `argumentsTruncated` | 原始参数 JSON（超 16KB 截断） |
| `summary` / `fingerprint` | 审批摘要 / 参数指纹 |
| `dangerLevel` / `dangerReason` / `matchedRules` | 危险评估结果 |
| `policyRequiresApproval` | 工具策略是否要求审批 |
| `approvalPrompted` | 实际是否弹窗 |
| `authorization` | `not-required` / `low-risk` / `session` / `forever` / `prompted` |
| `decisionApproved` / `decisionScope` | 弹窗时用户的决定（未弹窗为 null） |

- 写日志失败不阻塞工具执行；审计在审批决议后、工具执行前落盘（拒绝也记录）。

---
