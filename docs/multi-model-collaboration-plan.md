# 多模型协作工作方案

> 本文档供所有参与协作的 Agent 阅读，了解整体架构和分工。
>
> **当前生效流程：v2（2026-08-28 定稿）** — 见下方「二、生效流程 v2」。
> **正文只保留 v2 流程 + 工具类内容**（CLI 实测 / 通信协议 / 调用方法）。v1 的角色分工、架构（"单一写者=GLM / Hermes 只读"等）、路由表、职责、工作流示例**已整体移到文末「四、v1 历史（勿参考）」**，全部已被 v2 取代，**不要据以执行**。

---

## 一、需求来源（用户原始对话）

### 背景
用户正在开发 NewPi 项目（macOS Swift AI Agent），拥有三个 AI 模型：
- **GLM (智谱)** — 通过 Claude Code CLI 使用（命令：`claude`）
- **Kimi (K3)** — 在 Kimi 中使用，有 CLI（命令：`kimi`，二进制为 `~/.kimi-code/bin/kimi`）
- **DeepSeek** — 在 Hermes Agent 中使用

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
- Hermes 有桌面应用和 TUI
- 用户通过 Hermes UI 与所有 Agent 交互
- Hermes 负责调度

### 确认的关键信息（均已实测验证）

1. **Kimi 有 CLI** — 二进制为 `~/.kimi-code/bin/kimi`（Kimi Code CLI, v0.39.0），支持 `-p` 非交互模式、`--auto` 自动模式、`-S/--session [id]` 会话复用、`-y` 自动放行；`--output-format` 仅支持 `text` 和 `stream-json`（**无 `json`**）。**注意：它默认不在 PATH**，调用前必须 `export PATH="$PATH:$HOME/.kimi-code/bin"` 或直接用绝对路径
2. **Hermes 有 CLI** — 命令是 `hermes`，支持 `-z` 非交互模式和 `--yolo` 自动模式
3. **GLM (Claude Code) 有 CLI** — 命令是 `claude`，支持 `-p` 非交互模式；**会话复用是 `-r/--resume [id]` 和 `-c/--continue`，没有 `-S` 参数**
4. **三个模型都可以被程序化调用** — 支持全自主协作（kimi 需先配置 PATH，见下）

> **路径准备（必须）**：本方案所有命令中的 `kimi` 均假设已执行过 `export PATH="$PATH:$HOME/.kimi-code/bin"`。Hermes 发起任何 kimi 调用前须先执行该行（或直接用 `$HOME/.kimi-code/bin/kimi`），否则会得到 `kimi: command not found`。建议在新终端/脚本里统一加一次。

### 设计决策过程

1. 初始方案：GLM 作为调度器
2. 用户反馈：Hermes 有 UI，应该作为中心
3. 最终方案：Hermes 作为中心枢纽

---

## 二、生效流程 v2（2026-08-28 定稿）

> 用户原话（保留）：
> "我想这样，1.我和Hermes对话，因为它有UI；2.它收到请求给你或者K3，因为我不知道你们的模型能力谁更强，你们来进行方案设计，3.设计好的方案让Hermes执行。此时Hermes可以告诉我已经修改完底代码，让我手动测试。4.你或者K3来review Hermes的代码，把结果给到Hermes，Hermes验证完成后进行修改。5.修改完成后K3或你再次review。这个修改review的过程可以最多持续3轮，如果还有问题记录到文档并通知我，我来决策。"

### 定稿决议（用户逐项确认，2026-08-28）

| # | 待定项 | 决议 |
|---|---|---|
| 1 | 设计者与 reviewer 交错 | ✅ **采纳**：谁出的方案，由另一方 review |
| 2 | 验证闭环归属 | ✅ **采纳**：xcodebuild 构建验证归 Hermes（执行者）；reviewer 一律只读 |
| 3 | 手动测试时序 | ✅ **按用户原意**：Hermes 改完即通知用户测试，不等 review 收敛；接受测试中代码仍会被后续 review 轮次修改 |
| 4 | review 输出格式 | ✅ **采纳**：必须带文件路径 + 行号 + 具体修改建议 + 严重级别（格式见下） |
| 5 | 设计/review 默认分工 | ✅ **采纳**：默认 K3 设计 / GLM review（交错规则下 GLM 设计则 K3 review）；跑几轮后按实际效果调整 |
| 6 | Hermes 执行能力预实测 | ⏸️ **不做**：通过 review 环节自然观察 Hermes 代码质量，出问题再说 |

### 流程（定稿版）

```
用户 (Hermes UI)
    ↓ 需求
Hermes → K3（默认）：方案设计（只读）
    ↓ 方案
Hermes：执行代码修改 + xcodebuild 构建验证通过
    ├→ 通知用户：可手动测试（不等 review 收敛）
    ↓
GLM（默认）：review 代码（只读，实读仓库代码与决策文档）
    ↓ review 意见（按格式：文件+行号+改法+级别）
Hermes：验证 review 意见 → 修改 → 重新构建验证
    ↓
GLM：再次 review（只看上轮意见是否解决 + 有无新问题）
    └─ 循环最多 3 轮 → 仍有 blocker/major：记录文档 + 通知用户决策
```

### v2 角色分工

| 模型 | v2 角色 | 写文件？ |
|------|---------|---------|
| **Hermes** | 调度 + **执行者**（唯一写代码方）+ 构建验证 | ✅ 唯一写者 |
| **K3 (Kimi)** | **设计**（默认）/ 交错时 review | ❌ 只读 |
| **GLM (claude)** | **review**（默认）/ 交错时设计 | ❌ 只读 |

**交错规则**：K3 出方案 → GLM review；GLM 出方案（K3 不适合的场合，如需工具链侦察的方案）→ K3 review。**禁止同一模型对同一任务既设计又 review。**

### v2 路由速查（用户说什么 → 谁做什么）

| 你说 | 处理方式（v2） |
|---|---|
| "实现 X / 修复 Y / 跑构建"（会写仓库文件） | **Hermes 自己**（唯一写者）→ 改代码 + `xcodebuild` 构建验证 → 通知你手动测试 |
| "出架构方案 / 评审设计 / 写技术文档" | **K3 (Kimi)** 只读设计/文档评审 |
| "review 最近改动 / 审查代码" | **GLM (claude)** 只读 review（附路径+行号+改法+级别） |
| "设计 + 实现"（混合） | K3 出方案 → Hermes 实现 → GLM review → 3 轮内闭环 |
| 简单查询/文本、或 NewPi 自身小的 bug/UI 修复 | **Hermes 自己**（不触发多模型编排） |

> **触发口令**：`多模型协作：<任务>` 或 `协作模式：<任务>`（显式走多模型）；也可直接说需求，由 Hermes 按上表路由。跨会话自动触发已固化为 skill **`multi-model-collaboration`** + 持久记忆。

### review 纪律（来自 2026-08-28 误报教训）

review 结论必须先实读相关代码与决策文档，引用原文位置（如 `chat-scroll-layout.md §3.10`）；凭印象的判断必须标注"待验证"，不得作为 blocker/major 提出。

### review 输出格式（硬性要求）

每条意见必须包含四要素：

```
[级别] 文件路径:行号
问题：一句话说清缺陷
建议改法：具体、可直接执行的修改方案
```

级别定义：
- **blocker** — 会崩溃 / 数据错误 / 功能不工作
- **major** — 逻辑缺陷 / 性能问题 / 明显偏离设计方案
- **minor** — 风格 / 命名 / 注释级别

处理规则：Hermes 按 blocker > major > minor 顺序处理；minor 可攒批处理；有争议的意见 Hermes 可在回复中说明理由驳回，reviewer 认可则撤销，不认可则进入下一轮（计入 3 轮上限）。

### 升级路径（3 轮上限）

1. Hermes 记录当前 review 轮次
2. 第 3 轮结束仍有未解决的 blocker/major → **停止循环，不再进入第 4 轮**
3. 将以下内容写入 `docs/review-escalations.md`（追加，含日期与任务 ID）：
   - 问题描述（每条未决意见 + 级别 + 位置）
   - 双方分歧点与各自理由（reviewer 为什么坚持 / Hermes 为什么驳回）
4. 通知用户决策；用户裁决后按裁决执行，不再进入新一轮循环

---

## 三、工具类内容（v2 下继续有效）

### 工作目录约定

三个 CLI 的会话都绑定工作目录（cwd）。**Hermes 发起任何调用前，必须显式 `cd` 到同一项目目录**（`.`），否则各 Agent 的会话历史和上下文会错乱。kimi 路径还需 `export PATH`（见"路径准备"）。

### 沟通机制

#### 1. 单向调用（简单任务）
```bash
# Hermes 调用 K3（设计/只读）
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "评审这个架构方案" --auto

# Hermes 调用 GLM（review/只读）
claude -p "review 这段代码" --dangerously-skip-permissions
```

#### 2. 多轮对话（需要追问）

**Kimi / K3**（使用 `-S/--session`）：
```bash
# 第一轮
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "设计方案" --auto -S task-001-kimi

# 第二轮：追问
kimi -p "Hermes 指出问题 X，请重新考虑" -S task-001-kimi
```

**GLM / Claude Code**（注意：没有 `-S`，用 `--session-id` 指定 + `-r` 恢复）：
```bash
# 第一轮：用固定 UUID 作为会话 ID（自行生成，如 uuidgen）
claude -p "实现功能" --dangerously-skip-permissions --session-id <uuid>

# 第二轮：恢复该会话追问
claude -p "Kimi 评审后要求调整 Y，请修改" -r <uuid> --dangerously-skip-permissions

# 或者简单场景：直接继续当前目录最近一次会话
claude -p "继续修改" -c --dangerously-skip-permissions
```

#### 3. 交叉评审（需要多方意见）

Hermes 作为中间人协调，**默认并行下发**（K3 与 GLM 同时收到各自的评审指令），减少串行等待：
```
Hermes → K3: "设计架构方案"
Hermes → GLM: "评估方案可行性"（只读评估，不改代码）
Hermes → K3: "GLM 指出问题，请修改"
Hermes → GLM: "修改后的方案，请实现"
```
**注意**：评审阶段 GLM 也是只读的（只评估不改代码）；v2 下"实现"阶段由 **Hermes** 写代码（唯一写者）。

**仲裁规则**：若 K3 与 GLM 意见相左、来回超过 3 轮仍无共识，Hermes 必须停止循环，基于已有信息拍板；无法拍板时把分歧点整理后升级给用户决策。禁止无限往返。

### 通信协议

CLI 默认输出为自然语言文本，**不要假设返回是结构化 JSON**。约定如下：

#### 任务下发（Hermes 在 prompt 中用文本模板描述）
```
任务ID: TASK-001
类型: implement | review | design
描述: 实现消息搜索功能
上下文文件: ./.hermes/tasks/TASK-001/context.md
  （Hermes 预先将相关限制、背景、K3 方案摘要等写入该文件，被调用方用文件工具读取，
   不受 prompt 长度限制，避免大上下文被截断）
涉及文件: NewPiApp/SearchView.swift
要求: 支持关键词搜索；高亮匹配结果
完成标准: xcodebuild 构建通过
```

**上下文传递规则**：
- 短上下文（几行到一段）可直接内联在 prompt 里
- 中大上下文（设计方案、多文件背景、长文档）必须写入**落盘的上下文文件**（markdown 或 JSON），并在 prompt 里给出文件路径，让被调用方用文件工具（读文件）读取，而不是塞进命令行参数
- 被调用方读取上下文文件后，如需再次追问，可继续基于该文件路径引用

#### 结果返回（要求被调用方在结尾附上摘要块）
```
---RESULT---
状态: completed | failed | blocked
变更文件: NewPiApp/SearchView.swift
验证: xcodebuild 构建通过
摘要: 实现了搜索功能
---END---
```

#### 解析规则（容错，不要假定完美）
Hermes 解析 `---RESULT---` 块提取状态和摘要，但必须**容错**：
1. 用正则提取 `状态: (completed|failed|blocked)`、`摘要:` 等字段，忽略块内其他内容与前后空白
2. **缺失块兜底**：若返回文本中找不到 `---RESULT---`/`---END---`，则把整段正文视为摘要，`状态` 默认置为 `completed`，附加一条 `解析警告: 未找到 RESULT 块`
3. 若状态为 `failed/blocked`，必须把正文中相关错误信息带出来展示给用户
4. 不要因为几处格式偏差就把一次成功调用判为失败

#### 可选：机器可读输出
如需程序化解析（而非给人看），可使用 CLI 的结构化输出：
```bash
claude -p "{task}" --output-format json
kimi -p "{task}" --output-format stream-json
```
注意此时输出是 CLI 自身的信封格式（含 token 用量等元数据），不是上面的 RESULT 协议，两者按需选用。**Kimi 只有 `stream-json`，没有 `json`**。

### 注意事项

1. **上下文传递** — CLI 调用无状态，需要显式传递上下文；中大上下文一律走**落盘上下文文件**（见"上下文传递规则"），不要在 prompt 里塞大段内容
2. **会话管理** — Kimi 用 `-S`；Claude Code 用 `--session-id` + `-r`（或 `-c`），**没有 `-S`**；`-r` 恢复会话要求在同一工作目录下发起
3. **单一写者（v2）** — **Hermes 是唯一写代码方**；K3、GLM 设计/评审阶段一律只读
4. **验证闭环** — 代码任务必须构建验证通过才算完成（v2 归 Hermes）
5. **工作目录** — 所有调用必须在同一项目目录下发起；kimi 还需 `export PATH="$PATH:$HOME/.kimi-code/bin"`
6. **错误处理** — 检查 CLI 返回码，处理超时和失败；Hermes 侧 shell 超时必须大于被调方的 API 超时（Claude Code 默认 `API_TIMEOUT_MS` 约 10 分钟），建议设 15 分钟以上
7. **成本控制** — 简单任务不要调用其他模型；可用 `--max-turns`（Claude Code）限制单次调用的 agent 循环上限。**注意固定成本地板**：`claude` 每次调用都自带约 2.1 万 input token 的系统提示开销，agentic 循环会成倍放大——能 Hermes 直接处理的就别跳模型，且多轮/评审尽量控制次数。需在额度内规划交叉评审频率
8. **改动隔离** — 涉及仓库文件修改先做 diff 审阅，保护主目录（v2 下改动集中在 Hermes 自己的实现，仍建议用小步提交 + 审阅）
9. **轮次上限与仲裁** — 多轮对话最多 3-5 轮；交叉评审 3 轮无共识由 Hermes 拍板或升级给用户
10. **输出解析容错** — 依赖 `---RESULT---` 文本协议，但必须容错解析：正则提取字段、缺失块兜底为成功+警告、失败块带出错误信息（见"解析规则"）
11. **流式/交互延迟敏感** — NewPi 本身对流式输出延迟敏感，本编排（Hermes→模型→Hermes 逐跳）天然放大延迟。因此：简单任务由 Hermes 直接做（不跳模型）；交叉评审并行下发；默认避免不必要的深度 agent 串联；仅把多模型编排用于真正需要"设计+实现+评审"的复杂任务
12. **模型/产物名** — 目标 CLI 是 Kimi **Code**（`~/.kimi-code/bin/kimi`），不要与模型名"Kimi K3"混淆
13. **GLM 运行方式（已实测）** — GLM 实为智谱 `glm-5.3`（Haiku 档 `glm-4.5-air`），经 Anthropic 兼容网关（`https://open.bigmodel.cn/api/anthropic`）由 Claude Code 驱动，配置见 `~/.claude/settings.json`。Claude Code 客户端会打印 `[claude-code:unrecognized_model]` 警告——它打在 **stderr**，不影响 `--output-format json` 在 stdout 上的干净 JSON；该警告仅为校验提示，**不阻断请求**（实测 worktree 建分支改文件提交、结构化输出均成功）。因 GLM 非原生 Claude、由 harness 驱动，复杂 agentic 任务（构建/调试/提交多步循环）的稳定性是主要观察点——已用验证闭环、`--max-turns`、worktree 隔离兜底；若某次复杂任务卡住或异常，按**模型能力波动**处理（重试/拆短/简化），勿误判为方案错误。若未来 Claude Code 版本升级后对新模型校验变严格（开始拒绝而非仅警告），重点检查 `~/.claude/settings.json` 的 `ANTHROPIC_MODEL` 映射或回退到已知 Claude 模型 ID

### 快速参考（调用命令）

```bash
# 调用 K3（设计/只读）
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "{task}" --auto

# 调用 GLM（review/只读）
claude -p "{task}" --dangerously-skip-permissions

# 带会话复用 — Kimi
export PATH="$PATH:$HOME/.kimi-code/bin"
kimi -p "{task}" --auto -S {session_id}

# 带会话复用 — Claude Code（首轮指定 ID，后续用 -r 恢复）
claude -p "{task}" --dangerously-skip-permissions --session-id {uuid}
claude -p "{追问}" --dangerously-skip-permissions -r {uuid}
```

---

## 四、v1 历史（勿参考，已被 v2 取代）

> ⚠️ 以下为早期 v1 的**角色分工 / 架构 / 路由 / 职责 / 工作流示例**，均已被上方「二、生效流程 v2」取代。仅存档备查，**不要据以执行**。尤需注意 v1 的"单一写者=GLM / Hermes 只读"与 v2（Hermes 唯一写者）**完全相反**。

### v1 参与模型

| 模型 | CLI | 角色 | 自动模式参数 |
|------|-----|------|-------------|
| Hermes | `hermes` | 中心枢纽 + 调度 | `--yolo` |
| GLM (Claude Code) | `claude` | 代码执行专家 | `--dangerously-skip-permissions` |
| Kimi (K3) | `kimi`（需 PATH） | 设计文档专家 | `--auto` / `-y` |

### v1 架构与单一写者原则（已被 v2 取代）

```
用户 (Hermes UI)
    ↓
Hermes (中心枢纽)
    ├→ GLM (Claude Code) — 代码执行
    └→ Kimi — 设计文档
```

**核心原则（v1）**：
- 用户通过 Hermes UI 交互
- Hermes 负责任务调度和结果汇总
- GLM 负责所有需要工具链的操作（代码、调试、Git）
- Kimi 负责设计评审、长文档分析、技术文档
- **单一写者原则（v1）**：只有 GLM 可以修改项目文件。Hermes 和 Kimi 只做只读操作，需要改动一律转交 GLM
- **Hermes 独立完成边界（v1）**：Hermes 只处理不需要改动仓库文件的任务

### v1 角色职责

- **Hermes — 调度中心（v1）**：只读 + 调度；不修改仓库文件（如需改动，转 GLM）
- **GLM — 代码执行者（v1）**：唯一的代码写入方；代码实现/调试/Git/审查/测试构建；改动隔离（worktree + 分支）
- **Kimi — 设计顾问（v1）**：架构设计方案评审、长文档阅读总结、中文需求分析拆解、API 设计评审、技术文档写作

### v1 任务路由规则（已被 v2 取代）

```
任务来了
├─ 简单任务，且无需改动仓库文件？ → Hermes 自己做（纯分析/问答/文本）
├─ 需要修改代码/运行命令/写文件？ → 调用 GLM
├─ 需要设计评审/写文档？ → 调用 Kimi
├─ 复杂任务？ → 拆分，分别调用
└─ 不确定？ → 先尝试，不行再切换
```

> **铁律（v1）**：只要任务最终会写仓库文件，就一定交给 GLM；Hermes 的"自己完成"永远限定在"不写仓库文件"的范围内。

### v1 路由速查表（已被 v2 取代）

| 你说 | v1 处理 |
|---|---|
| "实现 X / 修复 Y / 跑构建"（会写仓库文件） | **GLM**：worktree 独立分支实现 + `xcodebuild` 验证 → 审阅合并回主分支 |
| "出架构方案 / 评审设计 / 写技术文档" | **Kimi**：只读设计/文档评审 |
| "设计 + 实现"（混合） | **Kimi 出方案 → GLM 实现** → 审阅合并 |
| "评审最近改动" | **并行**：Kimi 架构审查 + GLM 实现审查（均只读）→ 汇总 |
| 简单查询/文本、不写文件 | **Hermes 自己** |

### v1 工作流示例（已被 v2 取代）

**场景：实现新功能（v1）**
```
用户: "实现消息搜索功能"
    ↓
Hermes: 分析任务，需要设计 + 实现（写文件 → 必然走 GLM）
    ↓
Hermes → Kimi: "设计搜索架构方案"（只读）
Kimi: 返回设计方案
    ↓
Hermes → GLM: "根据方案实现代码（在独立 worktree/分支上），完成后跑 xcodebuild 验证"
GLM: 返回实现结果 + 构建验证通过 + 分支/worktree 名
    ↓
Hermes: 审阅 diff，合并回主分支，汇总展示给用户
```

**场景：代码审查（v1）**
```
用户: "审查最近的代码变更"
    ↓
Hermes: 获取 git diff（只读）
    ↓
并行调用：
  Kimi: "从架构角度审查"（只读）
  GLM: "从实现角度审查"（只读，此阶段不改代码）
    ↓
Hermes: 汇总两方意见，展示给用户
（若两方意见冲突且 3 轮内无共识 → Hermes 拍板或升级给用户）
```

**场景：Bug 修复（v1）**
```
用户: "修复滚动跳变的 bug"
    ↓
Hermes → GLM: "定位并修复 bug（worktree/分支隔离），修复后构建验证"
    ↓
GLM: 修复完成，但需要确认方案
    ↓
Hermes → Kimi: "这个修复方案是否合理？"（只读）
    ↓
Kimi: 确认方案
    ↓
Hermes: 审阅合并，完成，展示结果
```
