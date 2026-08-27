# 多模型协作工作方案

> 本文档供所有参与协作的 Agent 阅读，了解整体架构和分工。

---

## 需求来源（用户原始对话）

### 背景
用户正在开发 NewPi 项目（macOS Swift AI Agent），拥有三个 AI 模型：
- **MiMo (小米)** — 通过 Claude Code CLI 使用（命令：`claude`）
- **Kimi** — 在 Kimi 中使用，有 CLI（命令：`kimi`，二进制为 `~/.kimi-code/bin/kimi`）
- **DeepSeek** — 在 Hermes Agent 中使用，有 CLI（命令：`hermes`）

### 用户核心需求

**需求 1：设计协作工作模式**
> "帮我设计一个协作工作模式，接下来我会在一个项目开发中使用你们，给我方案"

**需求 2：支持自主沟通**
> "你们可以做到不需要我参与就互相交流分配任务吗？"

用户希望模型之间能自主协作，不需要人工中转。

> **实现方式说明**：本方案中 Agent 之间**不直接对话**，而是由 Hermes 作为中转枢纽传递消息。这是有意为之的简化——多方直连会导致状态同步困难、责任边界模糊。对用户的体验是等价的：用户只需面对 Hermes。

**需求 3：Hermes 作为中心枢纽**
> "我想用 Hermes 作为我和 agent 沟通的桥梁，因为它有 UI，可以吗？"

用户明确要求 Hermes 作为中心，因为：
- Hermes 有 Electron 桌面应用和 TUI
- 用户通过 Hermes UI 与所有 Agent 交互
- Hermes 负责调度 MiMo 和 Kimi

### 确认的关键信息（均已实测验证）

1. **Kimi 有 CLI** — 二进制为 `~/.kimi-code/bin/kimi`（Kimi Code CLI, v0.39.0），支持 `-p` 非交互模式、`--auto` 自动模式、`-S/--session [id]` 会话复用、`-y` 自动放行；`--output-format` 仅支持 `text` 和 `stream-json`（**无 `json`**）。**注意：它默认不在 PATH**，调用前必须 `export PATH="$PATH:$HOME/.kimi-code/bin"` 或直接用绝对路径
2. **Hermes 有 CLI** — 命令是 `hermes`，支持 `-z` 非交互模式和 `--yolo` 自动模式
3. **MiMo (Claude) 有 CLI** — 命令是 `claude`，支持 `-p` 非交互模式；**会话复用是 `-r/--resume [id]` 和 `-c/--continue`，没有 `-S` 参数**
4. **三个模型都可以被程序化调用** — 支持全自主协作（kimi 需先配置 PATH，见下）

> **路径准备（必须）**：本方案所有命令中的 `kimi` 均假设已执行过 `export PATH="$PATH:$HOME/.kimi-code/bin"`。Hermes 发起任何 kimi 调用前须先执行该行（或直接用 `$HOME/.kimi-code/bin/kimi`），否则会得到 `kimi: command not found`。建议在新终端/脚本里统一加一次。

### 设计决策过程

1. 初始方案：MiMo 作为调度器
2. 用户反馈：Hermes 有 UI，应该作为中心
3. 最终方案：Hermes 作为中心枢纽，调度 MiMo 和 Kimi

---

## 参与模型

| 模型 | CLI | 角色 | 自动模式参数 |
|------|-----|------|-------------|
| **Hermes (DeepSeek)** | `hermes` | 中心枢纽 + 调度 | `--yolo` |
| **MiMo (Claude)** | `claude` | 代码执行专家 | `--dangerously-skip-permissions` |
| **Kimi (Code)** | `kimi`（`~/.kimi-code/bin/kimi`，需 PATH） | 设计文档专家 | `--auto` / `-y` |

---

## 架构

```
用户 (Hermes UI)
    ↓
Hermes (中心枢纽)
    ├→ MiMo (Claude) — 代码执行
    └→ Kimi — 设计文档
```

**核心原则：**
- 用户通过 Hermes UI 交互
- Hermes 负责任务调度和结果汇总
- MiMo 负责所有需要工具链的操作（代码、调试、Git）
- Kimi 负责设计评审、长文档分析、技术文档
- **单一写者原则：只有 MiMo 可以修改项目文件。** Hermes 和 Kimi 只做只读操作（阅读、分析、评审），需要改动一律转交 MiMo，避免并发写冲突
- **Hermes 的"独立完成"有边界**：Hermes 只处理**不需要改动仓库文件**的任务（分析、问答、纯文本输出等）；凡是需要写入任何项目文件的任务，一律转交 MiMo。Hermes 自己绝不改写仓库文件，否则破坏单一写者

---

## 角色职责

### Hermes — 调度中心
- 接收用户任务
- 分析任务类型，决定调用哪个模型
- 分发任务并收集结果
- 汇总反馈给用户
- 管理会话历史
- 交叉评审出现分歧且达到轮次上限时，负责拍板或升级给用户决策
- **写文件边界**：只读 + 调度；不修改仓库文件（如需改动，转 MiMo）

### MiMo — 代码执行者
触发条件：需要修改代码、运行命令、调试、Git 操作

职责：
- 代码实现和修改（唯一的代码写入方）
- Bug 调试和修复
- Git 操作（提交、分支、合并）
- 代码审查（结合文件读取）
- 测试运行和构建验证
- **改动隔离**：涉及仓库文件修改时，优先在独立 git worktree + 专用分支上进行；Hermes 审阅后再合并回主分支（见下方"改动隔离"）

**任务完成标准（验证闭环）**：涉及代码改动的任务，MiMo 必须运行 `xcodebuild` 构建（和/或相关测试）验证通过后才算完成，并在结果中附上验证结果。禁止返回未经构建验证的代码。

#### 改动隔离（worktree / 分支）
为避免 `claude --dangerously-skip-permissions` 自动执行直接改坏主目录，MiMo 的文件修改应遵循：
1. Hermes 先为任务创建独立分支或 worktree（或交给 MiMo 在其内自行创建）
2. MiMo 在隔离环境中改代码并 `git commit`
3. Hermes 阅读 diff / 审阅，确认无误后 `git merge` 回主分支
4. 若审阅未通过，丢弃该分支/worktree 即可，主目录不受影响

> **`claude --worktree` 说明（已实测验证）**：Claude Code 原生支持 `-w/--worktree [name]`，会为会话创建 git worktree 并切换到其中；在 worktree 内可正常编辑、运行命令并 `git commit`。实测（v2.1.247）行为：
> - 自动创建 worktree 于 `<repo>/.claude/worktrees/<random-name>`，且 git 标记为 `locked`；从 `main` 拉出同名分支 `worktree-<random-name>`
> - 提交只落在该 worktree 分支上，`main` 分支完全不动 → 隔离生效
> - **Hermes 合并前必须先发现分支名**：优先读取被调方回复中给出的 `BRANCH=` 字段，或用 `git worktree list --porcelain` / `git branch` 反查
> - **审阅后清理**：`git merge <branch>` 回主分支后，worktree 仍会被 claude 会话标记为 `locked`（即使会话已退出），单次 `--force` 移除会失败。需先 `git worktree unlock <path>`，再 `git worktree remove <path>`（或直接 `git worktree remove -f -f <path>`），最后 `git branch -d <branch>`；否则残留的 locked worktree 会越积越多
> - 合并前用 `git diff main..<branch>` 快速核对改动范围

调用方式：
```bash
claude -p "{任务描述}" --dangerously-skip-permissions
```

### Kimi — 设计顾问
触发条件：需要设计评审、架构分析、文档写作、长上下文理解

职责：
- 架构设计方案评审
- 长文档阅读和总结（200K 上下文）
- 中文需求分析和拆解
- API 设计评审
- 技术文档写作

调用方式：
```bash
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "{任务描述}" --auto
```

---

## 工作目录约定

三个 CLI 的会话都绑定工作目录（cwd）。**Hermes 发起任何调用前，必须显式 `cd` 到同一项目目录**（`.`），否则各 Agent 的会话历史和上下文会错乱。kimi 路径还需 `export PATH`（见"路径准备"）。

---

## 沟通机制

### 1. 单向调用（简单任务）
```bash
# Hermes 调用 MiMo
claude -p "实现搜索功能" --dangerously-skip-permissions

# Hermes 调用 Kimi
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "评审这个架构方案" --auto
```

### 2. 多轮对话（需要追问）

**Kimi**（使用 `-S/--session`）：
```bash
# 第一轮
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "设计方案" --auto -S task-001-kimi

# 第二轮：追问
kimi -p "Hermes 指出问题 X，请重新考虑" -S task-001-kimi
```

**MiMo / Claude Code**（注意：没有 `-S`，用 `--session-id` 指定 + `-r` 恢复）：
```bash
# 第一轮：用固定 UUID 作为会话 ID（自行生成，如 uuidgen）
claude -p "实现功能" --dangerously-skip-permissions --session-id <uuid>

# 第二轮：恢复该会话追问
claude -p "Kimi 评审后要求调整 Y，请修改" -r <uuid> --dangerously-skip-permissions

# 或者简单场景：直接继续当前目录最近一次会话
claude -p "继续修改" -c --dangerously-skip-permissions
```

### 3. 交叉评审（需要多方意见）
Hermes 作为中间人协调：
```
Hermes → Kimi: "设计架构方案"
Hermes → MiMo: "评估方案可行性"（只读评估，不改代码）
Hermes → Kimi: "MiMo 指出问题，请修改"
Hermes → MiMo: "修改后的方案，请实现"
```
交叉评审默认**并行下发**（Kimi 与 MiMo 同时收到各自的评审指令），减少串行等待。**注意**：评审阶段 MiMo 也是只读的（只评估不改代码），只有进入"实现"阶段才允许写文件。

**仲裁规则**：若 Kimi 与 MiMo 意见相左、来回超过 3 轮仍无共识，Hermes 必须停止循环，基于已有信息拍板；无法拍板时把分歧点整理后升级给用户决策。禁止无限往返。

---

## 任务路由规则

```
任务来了
├─ 简单任务，且无需改动仓库文件？ → Hermes 自己做（纯分析/问答/文本）
├─ 需要修改代码/运行命令/写文件？ → 调用 MiMo
├─ 需要设计评审/写文档？ → 调用 Kimi
├─ 复杂任务？ → 拆分，分别调用
└─ 不确定？ → 先尝试，不行再切换
```

> **铁律**：只要任务最终会写仓库文件，就一定交给 MiMo；Hermes 的"自己完成"永远限定在"不写仓库文件"的范围内。

---

## 通信协议

CLI 默认输出为自然语言文本，**不要假设返回是结构化 JSON**。约定如下：

### 任务下发（Hermes 在 prompt 中用文本模板描述）
```
任务ID: TASK-001
类型: implement | review | design
描述: 实现消息搜索功能
上下文文件: ./.hermes/tasks/TASK-001/context.md
  （Hermes 预先将相关限制、背景、Kim 方案摘要等写入该文件，被调用方用文件工具读取，
   不受 prompt 长度限制，避免大上下文被截断）
涉及文件: NewPiApp/SearchView.swift
要求: 支持关键词搜索；高亮匹配结果
完成标准: xcodebuild 构建通过
```

**上下文传递规则**：
- 短上下文（几行到一段）可直接内联在 prompt 里
- 中大上下文（设计方案、多文件背景、长文档）必须写入**落盘的上下文文件**（markdown 或 JSON），并在 prompt 里给出文件路径，让被调用方用文件工具（读文件）读取，而不是塞进命令行参数
- 被调用方读取上下文文件后，如需再次追问，可继续基于该文件路径引用

### 结果返回（要求被调用方在结尾附上摘要块）
```
---RESULT---
状态: completed | failed | blocked
变更文件: NewPiApp/SearchView.swift
验证: xcodebuild 构建通过
摘要: 实现了搜索功能
---END---
```

### 解析规则（容错，不要假定完美）
Hermes 解析 `---RESULT---` 块提取状态和摘要，但必须**容错**：
1. 用正则提取 `状态: (completed|failed|blocked)`、`摘要:` 等字段，忽略块内其他内容与前后空白
2. **缺失块兜底**：若返回文本中找不到 `---RESULT---`/`---END---`，则把整段正文视为摘要，`状态` 默认置为 `completed`，附加一条 `解析警告: 未找到 RESULT 块`
3. 若状态为 `failed/blocked`，必须把正文中相关错误信息带出来展示给用户
4. 不要因为几处格式偏差就把一次成功调用判为失败

### 可选：机器可读输出
如需程序化解析（而非给人看），可使用 CLI 的结构化输出：
```bash
claude -p "{task}" --output-format json
kimi -p "{task}" --output-format stream-json
```
注意此时输出是 CLI 自身的信封格式（含 token 用量等元数据），不是上面的 RESULT 协议，两者按需选用。**Kimi 只有 `stream-json`，没有 `json`**。

---

## 工作流示例

### 场景：实现新功能

```
用户: "实现消息搜索功能"
    ↓
Hermes: 分析任务，需要设计 + 实现（写文件 → 必然走 MiMo）
    ↓
Hermes → Kimi: "设计搜索架构方案"（只读）
Kimi: 返回设计方案
    ↓
Hermes → MiMo: "根据方案实现代码（在独立 worktree/分支上），完成后跑 xcodebuild 验证"
MiMo: 返回实现结果 + 构建验证通过 + 分支/worktree 名
    ↓
Hermes: 审阅 diff，合并回主分支，汇总展示给用户
```

### 场景：代码审查

```
用户: "审查最近的代码变更"
    ↓
Hermes: 获取 git diff（只读）
    ↓
并行调用：
  Kimi: "从架构角度审查"（只读）
  MiMo: "从实现角度审查"（只读，此阶段不改代码）
    ↓
Hermes: 汇总两方意见，展示给用户
（若两方意见冲突且 3 轮内无共识 → Hermes 拍板或升级给用户）
```

### 场景：Bug 修复

```
用户: "修复滚动跳变的 bug"
    ↓
Hermes → MiMo: "定位并修复 bug（worktree/分支隔离），修复后构建验证"
    ↓
MiMo: 修复完成，但需要确认方案
    ↓
Hermes → Kimi: "这个修复方案是否合理？"（只读）
    ↓
Kimi: 确认方案
    ↓
Hermes: 审阅合并，完成，展示结果
```

---

## 注意事项

1. **上下文传递** — CLI 调用无状态，需要显式传递上下文；中大上下文一律走**落盘上下文文件**（见"上下文传递规则"），不要在 prompt 里塞大段内容
2. **会话管理** — Kimi 用 `-S`；Claude Code 用 `--session-id` + `-r`（或 `-c`），**没有 `-S`**；`-r` 恢复会话要求在同一工作目录下发起
3. **单一写者** — 只有 MiMo 改文件；Hermes、Kimi 一律只读
4. **验证闭环** — 代码任务必须构建验证通过才算完成
5. **工作目录** — 所有调用必须在同一项目目录下发起；kimi 还需 `export PATH="$PATH:$HOME/.kimi-code/bin"`
6. **错误处理** — 检查 CLI 返回码，处理超时和失败；Hermes 侧 shell 超时必须大于被调方的 API 超时（Claude Code 默认 `API_TIMEOUT_MS` 约 10 分钟），建议设 15 分钟以上
7. **成本控制** — 简单任务不要调用其他模型；可用 `--max-turns`（Claude Code）限制单次调用的 agent 循环上限。**注意固定成本地板**：MiMo 每次调用都自带约 2.1 万 input token 的系统提示开销，实测一次"OK"级回复约 $0.11（在 project 上下文下更高），agentic 循环会成倍放大——能 Hermes 直接处理的就别跳模型，且多轮/评审尽量控制次数。此外 `token-plan-cn` 表明是**预付费 token 套餐**，需在额度内规划交叉评审频率
8. **改动隔离** — MiMo 写文件优先在独立 worktree/分支上，Hermes 审阅后合并，保护主目录（尤其在一键跳过权限的自动模式下）
9. **轮次上限与仲裁** — 多轮对话最多 3-5 轮；交叉评审 3 轮无共识由 Hermes 拍板或升级给用户
10. **输出解析容错** — 依赖 `---RESULT---` 文本协议，但必须容错解析：正则提取字段、缺失块兜底为成功+警告、失败块带出错误信息（见"解析规则"）
11. **流式/交互延迟敏感** — NewPi 本身对流式输出延迟敏感，本编排（Hermes→模型→Hermes 逐跳）天然放大延迟。因此：简单任务由 Hermes 直接做（不跳模型）；交叉评审并行下发；默认避免不必要的深度 agent 串联；仅把多模型编排用于真正需要"设计+实现+评审"的复杂任务
12. **模型/产物名** — 目标 CLI 是 Kimi **Code**（`~/.kimi-code/bin/kimi`），不要与模型名"Kimi K3"混淆
13. **MiMo 运行方式（已实测）** — MiMo 实为小米 `mimo-v2.5-pro[1m]`，经 Anthropic 兼容网关（`token-plan-cn.xiaomimimo.com`）由 Claude Code 驱动。Claude Code 客户端会打印 `[claude-code:unrecognized_model]` 警告——它打在 **stderr**，不影响 `--output-format json` 在 stdout 上的干净 JSON；该警告仅为校验提示，**不阻断请求**（实测 worktree 建分支改文件提交、结构化输出均成功）。因 MiMo 非原生 Claude、由 harness 驱动，复杂 agentic 任务（构建/调试/提交多步循环）的稳定性是主要观察点——已用验证闭环、`--max-turns`、worktree 隔离兜底；若某次复杂任务卡住或异常，按**模型能力波动**处理（重试/拆短/简化），勿误判为方案错误。若未来 Claude Code 版本升级后对新模型校验变严格（开始拒绝而非仅警告），重点检查 `~/.claude/settings.json` 的 `ANTHROPIC_MODEL` 映射或回退到已知 Claude 模型 ID

---

## 快速参考

### 调用命令
```bash
# 调用 MiMo
claude -p "{task}" --dangerously-skip-permissions

# 调用 Kimi（先确保 PATH）
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "{task}" --auto

# 带会话复用 — Kimi
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "{task}" --auto -S {session_id}

# 带会话复用 — Claude Code（首轮指定 ID，后续用 -r 恢复）
claude -p "{task}" --dangerously-skip-permissions --session-id {uuid}
claude -p "{追问}" --dangerously-skip-permissions -r {uuid}
```

### 任务类型判断
- 需要写仓库文件 → MiMo（worktree/分支隔离 + 构建验证）
- 设计评审/写文档 → Kimi（只读）
- 简单任务且不写文件 → Hermes 自己做
- 混合任务 → 拆分后分别调用
