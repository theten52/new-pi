# NewPi 权限管理设计文档

> 状态：设计评审中
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
| ① 本地高危规则 | `rm -rf`、`sudo`、`git push --force`、`curl|sh`、磁盘/设备操作 | 命中 → **HIGH**（确定） | 否 |
| ② 工具类型基线 | `read`=low，`write`/`edit`/`bash`/`subagent`=medium，MCP=medium | 返回基线等级 | 否 |
| ③ LLM 补充（可选） | 对 ①② 未覆盖/需语义判断的命令做补充评估 | 返回等级+原因 | 是（可配置开关） |
| ④ 缓存 | 按 `工具名 + 参数指纹` 缓存评估结果 | 命中直接返回 | 否 |

**安全原则**：
- 本地规则命中即判定为 HIGH，**永不调 LLM、永不降级**——这是权限兜底，必须确定性。
- LLM 评估仅作为**可选增强**，默认关闭；开启后若 LLM 调用失败，**降级为工具基线等级（medium），绝不降为 low**。

### 4.2 本地危险规则（bash 重点）

```swift
struct RiskPattern {
    let regex: NSRegularExpression
    let reason: String
}

static let highRiskPatterns: [RiskPattern] = [
    .init(#"\brm\s+(-rf|-fr|-r\s+-f|-f\s+-r)\b"#, "递归强制删除文件"),
    .init(#"\brm\s+-[a-z]*[rR][a-z]*\s+/\b"#, "删除根目录"),
    .init(#"\bsudo\b"#, "提权执行"),
    .init(#"\b(mkfs|diskutil|dd)\b"#, "磁盘/设备操作"),
    .init(#"\bgit\s+push\s+--force"#, "强制推送"),
    .init(#"curl\s+.*\|\s*(sh|bash)"#, "下载并执行脚本"),
    .init(#"\bchmod\s+777"#, "权限放宽"),
    .init(#">\s*/etc/passwd|>/dev/(disk|[a-z]+)"#, "写入系统/设备"),
]
```

### 4.3 参数指纹

```swift
struct ToolApprovalFingerprint {
    static func make(arguments: JSONValue) -> String
    // 对 JSON 做稳定排序后 SHA256，作为缓存 key / 永久允许记录 key
}
```

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
requiresApproval?
  ├─ 是 → isAuthorized(tool, args)?
  │        ├─ true  → 直接执行
  │        └─ false → yield(.toolApprovalRequired(request 含危险信息))
  │                    → await requestToolApproval(request)
  │                    → 用户返回 (approved, scope)
  │                    → 写 tracker（high 则仅本次）
  └─ 否 → 直接执行
```

---

## 8. UI 改造：NewPiToolApprovalSheet

```
┌────────────────────────────────────────────────┐
│  ⚠️  高风险操作需要确认                         │
│  BASH                                           │
│                                                 │
│  Run command:                                   │
│  rm -rf ~/important                             │
│                                                 │
│  ───────────────────────────────────────────    │
│  🔴 高危险 · 递归强制删除文件                   │  ← 危险图标+提示
│                                                 │
│  [ Deny ]       [ 一次允许 ]                     │
│                 [ 本对话一直允许 ]               │
│                 [ 一直允许 ]                     │
└────────────────────────────────────────────────┘
```

- **危险图标**：`exclamationmark.triangle.fill`（红，high）/ `exclamationmark.triangle`（橙，medium）/ `checkmark.circle`（灰绿，low）。
- **危险提示**：显示 `dangerReason`。
- **三个允许按钮 + Deny**：
  - `一次允许`：**默认高亮主按钮**（borderedProminent，Enter 快捷）。
  - `本对话一直允许` / `一直允许`：次级按钮。
- **高风险**：三个允许按钮仍可选，但文案附加提示「本次将允许，该操作每次执行仍会再次确认」；点击任意允许后若为 high，本次放行但不写 tracker/持久化。

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
