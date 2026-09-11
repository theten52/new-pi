# 聊天室授权记忆与共用审批界面

基线 `875ccb1`；分支 `codex/chatroom-approval-memory`。

## 产品约定

- 聊天室提供拒绝、允许一次、本聊天室内允许该工具。
- 本聊天室授权覆盖同一聊天室所有角色、所有后续发言，仅保存在当前控制器的内存中；切页面不丢，重启/删除后不保留。
- 不影响 Session、其他聊天室，不读取或写入全局 approvals.json。
- 按整类工具记忆，不按单条命令参数记忆。允许 bash 不等于只允许访问工作目录，UI 明示这一点。
- 高风险始终逐次审批，不受已有授权、项目内免审影响；API 层也把高风险 session/forever 请求降为允许一次。
- 聊天室不支持 forever；Session 现有 once/session/forever 语义不变。
- 详情操作菜单提供“清除本聊天室工具授权”，忙碌期间禁用；清除时短暂占用任务状态，避免新发言与清除交错。

## 实现

`ToolApprovalTracker` 增加可选持久化存储。默认仍是 Session 的全局持久化实现；显式 nil 时只用内存，并拒绝 forever 写入。
`ChatRoomApprovalManager` 独立持有 nil 持久化 Tracker，每轮 AgentLoopConfig 注入同一个实例。

`PendingApproval` 保留工具、角色、摘要、风险等级/原因和参数指纹。批准返回实际选择的 ApprovalDecision，不再固定 allowOnce。
批准本聊天室工具时，已排队的同工具非高风险请求也纳入授权；不同工具与高风险请求仍等待用户决定。
请求先注册 continuation 再发布待审批项，取消/拒绝/迟到点击不会遗留挂起请求。兼容 provider 路径的 write_file 映射到 canonical write，并保留拒绝原因。

引擎每次发言读取保存的 ApprovalPolicy，风险缓存限定当轮，避免修改规则后继续命中旧评估。
可选 LLM assessor 不在本轮新增；此改动本身不会额外请求模型做风险评估。
引擎审批审计写入聊天室自己的 `approval-audit.jsonl`，记录原始参数、工作目录、批准来源与 scope；删除聊天室一起清理。
旧 provider 路径接通风险和授权记忆，但未新增与引擎等量的逐工具审计字段。

## UI

从 Session 审批页抽出 `NewPiApprovalContent`。Session 和聊天室共用风险标题、徽章、等宽操作详情、复制按钮及风险原因。
聊天室额外显示名称、申请角色、工作目录及整类工具授权边界说明。
Session 的“不再询问”菜单仍有本对话和一直允许；聊天室只提供本聊天室选项。
高风险隐藏记忆菜单。响应后禁用重复点击，按请求 ID 重置视图状态；聊天室 Sheet 不再手动 dismiss 后再切下一请求，防止审批队列被提前关闭，并禁止交互式关闭悬挂审批。

## 验证

- Core：9 个新增专项测试覆盖一次性/聊天室授权、跨角色与参数、跨聊天室/重建隔离、全局永久授权隔离、高风险、清除、拒绝/取消/迟到点击、排队请求和兼容写工具。
- 真实 ChatRoomLoop + 模拟 MCP 工具：首次弹框，下一角色不再弹框；清除后重问；修改风险规则为 high 后重问。审计依次为 prompted/session/prompted/prompted，最后 scope=once。
- App 控制器脚本新增清除授权期间的忙碌保护检查。
- 共用 UI 在浅色/深色独立窗口中进行真实 AX 点击，聊天室 session、高风险 once、Session forever 回调均通过；长名称/长路径截图由原生窗口采集。
- 不请求真实模型、不运行真实 shell 命令；所有测试授权文件和审计写入临时目录。

执行结果：Debug / Release 构建通过；291 tests / 80 suites 全部通过；App 控制器（含清除授权）、渲染适配器和 WKWebView 回归通过。
UI Probe 只操作真实共用组件的回调，Core 集成测试负责验证授权到引擎执行的行为；没有用用户真实项目执行写入来验收。

本次修改替代早期设计文档“聊天室所有批准仅一次、不跨发言记忆”的约定，不改变聊天室独立工作目录或 Session 的授权生命周期。
