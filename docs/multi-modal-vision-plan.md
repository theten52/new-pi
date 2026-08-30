# NewPi 聊天图片支持（Multi-modal Vision）设计方案

> 状态：**MVP 已实现**（2026-08-31 落地 UI 采集 + 气泡缩略图；此前 Core/provider/落盘层已就绪）
> 2026-08-31 补齐：Settings 模型行「支持图片识别」开关、点击放大预览、DeepSeek 双端点带图实测。
> 待办：Anthropic 带图端到端实测（本机无 key，格式已有单测覆盖）、HEIC 转 JPEG、Quick Look 预览。
> 目标：为聊天增加图片（vision）输入 —— 采集、持久化、provider 序列化、UI 展示全链路。
> 依据：`CLAUDE.md` 的 UI 渲染架构（单文档 transcript）+ `AgentMessage` / provider 现状。

## 1. 一句话结论

为 `UserMessage` 增加结构化附件 `attachments`，图片以**本地文件路径引用**持久化；
provider 序列化（Anthropic / OpenAI / Responses 三处）把用户 content 从纯文本升级为
「text + image」块数组；provider 模型以**并行 `imageCapableModels` 集合**标注是否支持图片；
UI 在用户气泡内以缩略图展示，并通过受控本地读取通道加载。

## 2. 现状（改动前必读）

当前聊天链路**完全没有图片概念**，整条链路都是纯文本：

| 层 | 现状 |
|---|---|
| 消息模型 | `UserMessage.content: String`（`AgentMessage.swift`），无附件字段 |
| provider 序列化 | 三个 provider 都把 `user.content` 序列化为 `"content": "<纯文本字符串>"` |
| UI 采集 | `send(_ text: String)` 只接受文本；composer 无附件按钮 / 拖拽 / 粘贴图片 |
| UI 展示 | `transcript-document.js::renderUser` 用 `bubble.textContent = op.body` 纯文本 |
| 持久化 | `SessionEntry.message: AgentMessage?` 随 JSONL 走，`UserMessage` 仅文本 |

相关文件：

- `Packages/NewPiCore/Sources/NewPiCore/AgentMessage.swift`（消息模型）
- `Packages/NewPiCore/Sources/NewPiCore/Anthropic/AnthropicProvider.swift`（Anthropic 序列化）
- `Packages/NewPiCore/Sources/NewPiCore/Providers/OpenAICompatible/OpenAICompatibleProvider.swift`（OpenAI 序列化）
- `Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesMessageEncoder.swift`（Responses 序列化）
- `NewPiApp/NewPiChatView.swift`（composer）
- `NewPiApp/NewPiViewModel.swift`（`send` / `NewPiTranscriptItem`）
- `NewPiApp/NewPiTranscriptDocumentView.swift`（diff → ops → JS）
- `NewPiApp/MarkdownRenderer/transcript-document.js`（`renderUser`）

## 3. 需求确认清单

| 需求点 | 结论 |
|---|---|
| 图片来源 | **C：文件选择 + 拖拽 + 粘贴（含 cmd+V 截图）** |
| 格式 / 大小 | 常见格式（PNG / JPEG / GIF / WebP），单张 ≤ 5MB |
| provider 能力 | 由用户在**新增 provider / 模型时手工指定**是否支持图片；不支持时提示用户 |
| 持久化 / 重放 | **图片存本地附件文件夹，用本地文件路径引用** |
| UI | 收发图片缩略图展示；点击放大为二期 |
| 范围 | **MVP**：当前模型（Claude 类）已支持 vision |

## 4. 三个核心设计决策

### 4.1 消息模型：`UserMessage` 增加结构化附件

`UserMessage` 增加 `attachments: [MessageAttachment]`，图片数据**不内联 base64**，只存路径引用。

```swift
// AgentMessage.swift
public struct MessageAttachment: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case image }
    public var kind: Kind          // 目前只有 image，后续可扩展 file
    public var mediaType: String   // "image/png" | "image/jpeg" | ...
    public var path: String        // 相对附件根目录的路径（见 4.2）
    public var displayName: String
}

public struct UserMessage: Sendable, Codable, Equatable {
    public var content: String
    public var attachments: [MessageAttachment]
    public var timestamp: Date
    // 自定义 decode：兼容旧文件（attachments 缺省为 []）
}
```

**为什么存路径而不存 base64：** base64 会让 JSONL 会话文件显著膨胀、且无法跨文件复用；
路径引用体积小。代价是附件目录需随会话一起管理（见 6.3 风险）。

### 4.2 图片落盘：会话关联的附件目录

```
~/.new-pi/agent/sessions/attachments/<sessionID>/<uuid>.<ext>
```

- 发送时把用户选中的图片**拷贝 / 重组**进该目录（以会话 UUID 隔离）。
- `MessageAttachment.path` 存**相对附件根目录的路径**（不存绝对路径），提高可移植性。
- 写盘前处理管道（对标 pi / osaurus 的实现，2026-08-31 强化）：**原样优先**（尺寸与
  base64 体积均在预算内 → 不动字节）；需处理时**PNG/JPEG 双编码取满足预算的最小者**
  （JPEG 质量阶梯 0.85→0.4），仍超则长边 ×0.75 递减；体积口径统一为 **base64 后字节**
  （Anthropic 单图 5MB 按此计，膨胀 ×4/3）；发生缩放时生成**坐标映射 note**，随 image
  块以 text 块下发（`MessageAttachment.note`，三 provider 序列化同构）。
- MVP 不自动清理附件（会话删除时附件的回收策略见 5.5 二期）。

### 4.3 Provider 模型图片能力标注：并行集合（方案 B）

在 `ProviderProfile` 上新增**并行集合**，`models: [String]` 保持不动（完全向后兼容）：

```swift
// ProviderProfile.swift
/// 支持图片识别的模型集合。缺省空 = 该 provider 下所有模型都不支持图片。
/// 旧配置解码时缺省为空，语义为「不支持」；preset 已知 vision 模型预填默认值。
public var imageCapableModels: Set<String> = []
```

**为什么不把 models 改成对象（方案 A）：** 会破坏 `models: [String]` 的解码与所有使用点，
迁移成本高。方案 B 只需新增一个字段 + 自定义 decode（缺省空），兼容旧 JSON。

**UI 勾选：** Settings 的模型行（`NewPiSettingsView.swift` 的 `ForEach(profile.models)`）
为每个模型加「支持图片识别」开关；新增 / 编辑模型时由用户勾选。

**preset 预填：** 已知 vision 模型（如 `deepseek-v4-flash-vision-exp`、`claude-*-4-*`、
`gpt-4o*` 等）在 `ProviderPresetCatalog` 定义时预填进默认 `imageCapableModels`。

## 5. 分层改动清单

### 5.1 Core 层（`Packages/NewPiCore/`）

| 文件 | 改动 |
|---|---|
| `AgentMessage.swift` | 加 `MessageAttachment`；`UserMessage.attachments`；`UserMessage.decode` 兼容；`AgentMessage.user()` 助手重载 |
| `SessionStore.swift` | 无需改（`AgentMessage` 已含在 `SessionEntry.message`，附件随之持久化） |
| `AgentLoop.swift` | 无需改（消息已携带附件自然流转） |
| `Providers/ProviderProfile.swift` | 加 `imageCapableModels: Set<String>` + 自定义 decode 缺省 + helper |
| `Providers/ProviderPreset.swift` | provider 定义处给已知 vision 模型预填 `imageCapableModels` |

### 5.2 Provider 序列化（三种格式差异大，核心改动）

| Provider | user content 序列化为 |
|---|---|
| **Anthropic** | `[{type:"text"}, {type:"image", source:{type:"base64", media_type, data}}]` |
| **OpenAI (chat)** | `[{type:"text"}, {type:"image_url", image_url:{url:"data:<mime>;base64,<data>"}}]` |
| **Responses** | `[{type:"input_text"}, {type:"input_image", image_url:"data:..."}]` |

各文件 user 分支从纯字符串升级为块数组，并读附件文件 → base64 注入：

- `AnthropicMessageEncoder.encodeMessages`（约第 24-29 行的 `.user` 分支）
- `OpenAICompatibleProvider`（约第 42-43 行）
- `ResponsesMessageEncoder`（约第 9-10 行）

**能力拦截：** 进入 loop 前，若 `attachments` 非空且当前模型 `imageCapableModels` 不包含
当前 `modelID` → 拦截并提示「当前模型不支持图片」，不发出请求。

### 5.3 输入采集层（`NewPiApp/NewPiChatView.swift`）

`send(_ text: String)` 扩展为同时接收附件；composer 增加附件状态：

1. **附件按钮**：composer 旁加图片按钮 → `NSOpenPanel`（限制 `UTType.image`）多选。
2. **拖拽**：`NewPiComposerInnerTextView` 支持 `registerForDraggedTypes([.fileURL])` 或外层 drop，
   收集图片文件为草稿附件。
3. **粘贴**：`textView` 的 `paste` 处理，检测剪贴板图片数据（`.tiff` / `.png`），转临时图写入草稿。
4. **草稿附件条**：composer 上方显示已选附件缩略图 + 移除按钮（`@State draftAttachments`）。
5. 发送时：采集 `draftAttachments` → 落盘到附件目录 → 组装 `UserMessage(attachments:)` →
   `session.prompt(...)`。

### 5.4 UI 展示层（`transcript-document.js` + 原生桥）

用户气泡显示图片缩略图。当前 `renderUser`（`transcript-document.js:613`）只设 `bubble.textContent`。

1. **JS**：`renderUser` 里若 `op.attachments` 非空，额外创建附件横排容器 + `<img>`。
2. **原生桥**：`NewPiTranscriptItem` 增加 `attachments: [MessageAttachment]`；
   diff → ops 时把附件传进 `op`，相对路径解析为可加载的本地 URL。
3. **受控本地读取通道**：当前渲染器 CSP 禁掉 image、禁 raw HTML（离线 + 隐私 + 安全）。
   附件图需单独开一条受控通道：只允许从附件根目录读取，路径经过校验，禁止任意本地文件读取。

### 5.5 二期（暂不做）

- HEIC 自动转 JPEG、GIF 动画帧支持
- 截屏工具（框选区域）
- 图片入库去重 / 会话删除时回收附件
- 点击图片放大 + Quick Look 预览
- 模型图片能力自动探测（查 `/models` 或硬编码能力表）

## 6. 风险与对策

### 6.1 路径引用的失效风险

用户选了路径引用方案。附件目录需**随会话路径一起管理**；移动会话目录后相对路径可能失效。
缓解：`MessageAttachment.path` 存相对附件根目录，根目录与会话目录同层级；若附件缺失，
UI 占位提示「图片已丢失」，不影响整条会话回放。

### 6.2 用户标注图片能力可能不准确

`imageCapableModels` 由用户手工标注，**不会自动校验**；标错可能触发 provider 400。
缓解：模型请求出错时，把「图片相关错误」友好提示给用户，并建议检查该模型的
「支持图片识别」开关。

### 6.3 渲染层本地读取是安全敏感点

WKWebView 默认不能访问任意本地 `file://`。需设计受控边界：`WKURLSchemeHandler` 自定义
scheme 只解析附件目录内路径，或 `loadFileURL:allowingReadAccessTo:` 限定到附件根。
**禁**用任意路径拼接，防止路径穿越读取宿主文件。

### 6.4 向后兼容

- `UserMessage.decode`：`attachments` 缺省 `[]`，旧 JSONL 无损读取。
- `ProviderProfile.decode`：`imageCapableModels` 缺省空（语义：不支持），无迁移。
- provider 序列化：无附件时仍输出纯字符串（维持旧格式），有附件时才升级为块数组。

## 7. 验收清单（MVP）

- [x] 新增 / 编辑 model 时能勾选「支持图片识别」，配置可持久化（模型行 photo 图标开关，Save 随 profile 落盘）
- [x] 点附件按钮选择多张图片，composer 上方显示草稿缩略图 + 可移除
- [x] 拖拽图片文件到 composer 能加入草稿；粘贴图片（或 cmd+V 截图）能加入草稿
- [x] 发送后用户气泡显示图片缩略图；附件落盘到会话附件目录
- [x] Anthropic / OpenAI / Responses 三种 provider 带图请求格式正确（**OpenAI 兼容与 Responses 已实测**：DeepSeek 官方双端点 200 且识图正确（红色图→"Red"）；Anthropic 无 key 未实测，格式有单测覆盖）
- [x] 模型不支持图片时带图发送被拦截并提示（`NewPiViewModel.send`）
- [ ] 会话重开 / 继续对话时 JSONL 重放附件正确（含图片显示 + 回传给模型）（rebuild 已携带 attachments，未端到端实测）
- [x] 旧会话（无附件字段）正常回放，不报错（decode 缺省 `[]`）
- [x] 图片 > 5MB 或不可解码时给出明确报错且不发送
- [x] 缩略图加载走受控本地通道，不借 CDN、不开任意本地文件读取（`pi-att://` scheme handler + `SessionAttachments.resolve` 唯一边界）
- [x] 点击缩略图放大预览（原生浮层窗：Esc / 点击背景关闭；路径同样经 `SessionAttachments.resolve` 受控解析）

## 8. 参考

- `CLAUDE.md`：「UI 渲染架构（改动前必读）」（单文档 transcript）
- `Packages/NewPiCore/Sources/NewPiCore/AgentMessage.swift`
- `Packages/NewPiCore/Sources/NewPiCore/Providers/ProviderProfile.swift`
- `Packages/NewPiCore/Sources/NewPiCore/Providers/ProviderPreset.swift`
- `NewPiApp/MarkdownRenderer/transcript-document.js`（`renderUser`）
- `NewPiApp/NewPiTranscriptDocumentView.swift`（diff → ops → JS）
- `NewPiApp/NewPiChatView.swift`（composer）
