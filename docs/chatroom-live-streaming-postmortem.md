# 聊天室实时流式显示——Bug 技术复盘

> 2026-09-06。记录聊天室「发言实时进度显示」功能从实现到定位一个隐蔽的
> Swift 派发陷阱的完整过程。功能本身（流式事件通道、临时消息、thinking
> 展示、增量渲染）见 commit `17c95f1` 及后续；本文聚焦根因与教训。

## 一、问题现象

聊天室角色发言期间（尤其 extended thinking 阶段，可持续 1-2 分钟），对话流
完全空白，仅底部状态栏显示「架构师 正在思考...」。发言结束后最终消息一次性
出现。用户诉求：与 Session 对话一致，实时显示思考/正文/工具执行进度。

## 二、排查时间线

| 阶段 | 动作 | 结论 |
|------|------|------|
| 1 | 第一轮实现：`ChatRoomSpeechEvent` 事件通道 + 临时消息实时改写 + 增量渲染接入 | 功能就位，但用户报告不生效 |
| 2 | 补 thinking 转发（`thinkingDelta` → `reasoningContent` → thinking 条目） | 仍不生效 |
| 3 | 静态审查渲染链（SwiftUI 观察 → transcript diff → JS ops） | 代码逻辑全部正确，无果 |
| 4 | **实测 provider**：写临时诊断测试直连真实 GLM 端点流式请求 | **3.1s 收到 140 个增量事件**——provider 层完全正常，排除服务端/传输层 |
| 5 | 发现 `xcodebuild` 增量构建**假成功**（touch 源文件后 dylib mtime 不变） | clean 重建排除构建产物过期问题 |
| 6 | **五环埋点**：流事件到达（provider）→ 回调改写（loop）→ 快照重算（视图 body）→ apply 调用（WebView 桥）→ ops 下发（diff） | 真实运行日志显示：provider 侧事件到达并记录（埋点在回调之后），但 loop 侧改写探针 **从未触发** |
| 7 | 定位：`onEvent` 被调用链静态派发到 **extension 默认实现**，默认实现丢弃 `onEvent` | 根因确认 |

阶段 6 的关键推理：`flushPendingDelta` 里「DIAG live textDelta flowing」日志位于
`await onEvent?(...)` **之后**——日志出现并不能证明回调执行了（`onEvent` 为 nil 时
可选链直接跳过、日志照打）。而 loop 侧两个互斥探针（改写成功 / guard 失败）均未
出现 → **回调从未进入** → `onEvent` 在运行时为 nil。

## 三、根因：协议扩展方法的静态派发陷阱

### 最初的写法

```swift
public protocol ChatRoomLLMProvider: Sendable {
    func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse
}

// chatWithEvents 只定义在 extension 里——不是协议要求
public extension ChatRoomLLMProvider {
    func chatWithEvents(..., onEvent: (...)? ) async throws -> ChatRoomLLMResponse {
        try await chat(systemPrompt: systemPrompt, messages: messages)  // onEvent 被丢弃
    }
}

public struct ChatRoomLLMProviderImpl: ChatRoomLLMProvider {
    // 同名 override，带完整的流式/工具事件实现
    func chatWithEvents(..., onEvent: ...) async throws -> ChatRoomLLMResponse { ... }
}
```

### 触发条件

app 里 provider 的持有类型是**存在容器**：

```swift
private let llmFactory: any ChatRoomLLMProviderFactory   // 返回 any ChatRoomLLMProvider
let provider = try llmFactory.createProvider(...)        // 类型是 any ChatRoomLLMProvider
let response = try await provider.chatWithEvents(...)    // ← 静态派发！
```

Swift 的派发规则：**通过存在容器（`any Protocol`）调用「非协议要求」的扩展方法时，
调用静态绑定到扩展默认实现**，具体类型（struct）的同名方法被完全绕过。于是运行时
走的是「丢弃 onEvent、转发无事件 chat()」的默认实现——最终消息能正常显示，实时
事件从头到尾没有发出去。

### 修复

把 `chatWithEvents` 提升为**协议要求**（extension 默认实现保留，用于满足只实现
`chat()` 的测试 mock）：

```swift
public protocol ChatRoomLLMProvider: Sendable {
    func chat(systemPrompt: String, messages: [ChatRoomLLMMessage]) async throws -> ChatRoomLLMResponse

    /// 必须是协议要求：app 通过 `any ChatRoomLLMProvider` 存在容器调用……
    func chatWithEvents(
        systemPrompt: String,
        messages: [ChatRoomLLMMessage],
        onEvent: (@MainActor @Sendable (ChatRoomSpeechEvent) -> Void)?
    ) async throws -> ChatRoomLLMResponse
}
```

协议要求进 witness table，存在容器调用动态派发到 `ChatRoomLLMProviderImpl` 的实现。

## 四、为什么单元测试没抓到

当时的三条测试（事件序列、实时改写定型、失败清理）**全部通过具体类型调用**：

```swift
let impl = ChatRoomLLMProviderImpl(provider: mock, ...)   // 具体类型
let response = try await impl.chatWithEvents(...)          // 编译期静态绑定到 override ✓
```

具体类型调用在编译期绑定到 override，与运行时的存在容器派发行为完全不同。
**测试的调用形态必须与生产一致**。已补回归测试：

```swift
let provider: any ChatRoomLLMProvider = ChatRoomLLMProviderImpl(...)  // 存在容器
let response = try await provider.chatWithEvents(..., onEvent: { collector.append($0) })
#expect(!collector.snapshot.isEmpty)   // 修复前此断言必失败
```

## 五、排查方法论沉淀

1. **分层埋点 + 真实复现**是定位「链路无显示」类问题最有效的手段。五个探针
   （每层一个、1s 节流）一次运行即可把断点夹逼到相邻两层之间。
2. **先排除传输层再怀疑业务层**：直连真实端点的流式诊断测试（一次请求、
   打印事件时间序）一步就证明了 provider 正常，避免了在 provider 层浪费排查时间。
3. **日志位置决定证据效力**：「回调之后」打的日志不能证明回调执行了
   （前置的可选调用跳过后日志照打）。互斥的双探针（成功路径 + 失败路径）
   都不出现才是「回调未执行」的可靠证据。
4. **构建产物验证的坑**：
   - `xcodebuild` 对 local package 的增量构建可能**假成功**（touch 源文件后
     产物 mtime 不变）。怀疑产物过期时，`clean` 是唯一裁决手段。
   - `strings` / `nm` 验证 Swift 二进制不可靠：中文字面量会被 ASCII 过滤、
     枚举 case 没有独立链接符号、且同名成员会跨类型冲突（`LLMStreamEvent.thinkingDelta`
     vs `ChatRoomSpeechEvent.thinkingDelta`）。用 **mangled 名前缀**
     （如 `19ChatRoomSpeechEventO13thinkingDelta`）+ `grep -a` 才是精确判据。
5. **环境差异要当回事**：本例中 key 存储位置（UserDefaults 而非钥匙串）、
   测试进程与 app 的 UserDefaults 域不同、GLM 端点无视 `thinkingLevel=off`
   仍下发 `reasoning_content` 等，都是实测才暴露的事实。

## 六、同批附带修复与改进

- **thinking 实时展示**：`thinkingDelta` 事件 → `ChatRoomMessage.reasoningContent`
  （随消息落盘，可回看）→ transcript 正文前 `.thinking(isStreaming:)` 条目
  （正文开始后冻结），复用 Session 的思考渲染管线。
- **增量渲染接入**：聊天室 `messageList` 的 `isStreaming`/`streamingBubbleComplete`
  按 `runtime.isRunning` 推导——实时气泡走 `renderStreaming`（块级增量 + ✦ 光标），
  定型一次 `renderFinal`（此前的硬编码 `false` 导致每次更新全量重解析）。
- **工具卡 running 状态**：结果未到达的工具卡显示 running，执行完翻 ✓/✗。
- **文本增量节流**：120ms 攒批下发，避免每 delta 一次 MainActor 往返。

## 七、遗留观察项

- agentic loop 中间轮的解说文字实时可见，定型时以最后一轮文本覆盖——观感待
  真机确认；若突兀，可改为累积文本（代价：与工具卡的交错时序无法表达）。
- voting 阶段「进入执行」按钮缺 `isRunning` 守卫（预存在，非本次引入）。
