# 2026-09-12 · Session 运行错误重启后恢复

## 根因与修复范围

`debf613` 解决的是内存 transcript 重建时错误跨轮移动；错误本身并未落盘，
重启时 `makeTranscriptItems` 只从 AgentMessage 构建正文，因此取消/失败提示消失。

本次把 AgentSession 的运行错误保存为用户（或摘要）entry 的可选 `transcriptErrors` 元数据：
每条包含 UUID、消息和时间。不是 AgentMessage，不改变消息索引、计数或 leaf，不作为 provider 上下文。
旧 JSONL 无该字段仍可解码；新文件仍使用现有 entry 类型。降级旧 App 虽能读取文件，
但旧版重写时可能丢弃它不认识的字段，不保证降级后继续保留错误。

## 保存与恢复

- AgentSession actor 在错误广播之前尝试保存，使用其现有 persistenceContext，避免 UI 另写 JSONL 被下一快照覆盖。
- 每次 prompt 的 RunErrorState 独立保存锚点、待写错误和已见文案；首个本轮快照前先排队，
  不用上一轮用户条目兜底。尚未形成任何本轮快照就结束时没有可保存的轮次，不承诺恢复该提示。
- 同一 run 的 abort 即时报错与循环取消收尾同文案去重；不同 run 的同文案分别保存。
- 首次磁盘写入失败时记录日志、不递归广播；错误元数据仍留在 actor 内存，后续快照/shutdown 可重试。
  持续磁盘失败或退出前未能成功保存时仍可能丢失，不宣称断电事务保证。
- 当前分支通过 `SessionManager.transcriptErrors` 单独投影展示错误；兄弟分支中不属于祖先的条目不进入当前视图。
  用户节点作为共有祖先时，该轮错误随祖先继承，不改变现有“轮次归属”的规则。
- 冷恢复读取该投影，放在对应用户轮次末尾；原轮次被压缩而不再显示时，保留在摘要之前，不挂到新轮次。
  重载后的错误使用已保存 UUID，再次重建仍遵循上一轮的位置规则。

仅保存运行产生的 AgentEvent.error，包括取消和 provider 错误；没有会话归属的配置/加载错误及
纯 UI 操作校验提示不在此范围。已被旧版丢弃、从未写盘的错误无法追溯重建。

## 验证

- `SessionTranscriptErrorTests` 六项：真实流式后取消、错误广播前可读磁盘、新 actor 恢复、
  模型失败自动保存、后续同步/压缩保留、分支继承与隔离、旧文件兼容、
  写失败后的 shutdown 重试、跨轮同错误隔离、新轮次立即取消不污染旧轮次。
- `check-transcript-error-order.sh`：24 项断言通过，增加真实 JSONL 编解码后调用生产冷恢复工厂，
  核对错误内容/轮次/ID、后续重建不移动，以及压缩前错误不丢失。
- `check-draft-navigation.sh`：40 项断言通过。
- 完整 Debug 构建通过。核心包实际执行 `swift test`：**340 tests / 89 suites 全部通过，exit 0**，
  含工作区本地学习测试，非纯净检出测试数量；日志 `/private/tmp/newpi-ui/error-persistence-core.log`。
- 测试最初两处比较失败来自秒级 ISO8601 序列化与亚秒内存时间戳差异，改为比较同一序列化精度下的消息后通过。

上述为临时文件与假 provider 的回归，不读取/修改用户会话，不等于用户的真实网络场景已复验。
请使用包含本修复的新版本，新建一轮输出后取消，确认提示出现；退出并重新打开 App，
应仍在该轮末尾看到提示，再继续下一轮检查它不移动。

## 本次 Release 产物

基于 `debf613` 加本次未提交修复重新执行 `scripts/package.sh Release`，日志包含 BUILD SUCCEEDED 和 dist 复制完成。
旧包备份：`dist-backup/NewPi-before-error-persistence-20260912-191752.app`。
新包：`dist/NewPi.app`；独立 `codesign --verify --deep --strict` 返回 0。
dist 与 Release 构建目录主二进制 SHA-256 相同：
`45e8f87a014836e42c528336d8bcdfd3f57c6b832ba12fab5dc44d23fc23b655`。
没有自动退出或重启用户当前 App，故当前运行实例不会自动加载新代码。未提交或推送本次修复，学习资料未动。

## 后续：中断前已输出内容一同保存

用户确认上述错误重启恢复正常，并提出取消前已有正常输出也应保留。
检查发现旧 `inFlightText` 只在 shutdown 路径补存正文，abort 不立即保存，
错误后的旧快照还会清空缓冲；思考没有对应缓冲，无法在重启时恢复。

本次将正文/思考和已收到的完整 assistant messageEnd 放到每个 run 的状态内：

- `abort()` 返回前保存已经被 Session 消费、交付给 UI 的正文/思考；未完成回答使用 `.aborted`，异常断流使用 `.error`。
- `shutdown()` 与新 prompt 替换旧 run 复用这条保存路径；取消/已替换 run 的迟到事件不能覆盖新上下文或投递到新轮次。
- 完整 messageEnd 但尚未收到快照的回答原样保存，保留完成原因与真实 usage；不再把它降级为部分输出。
- 部分回答只保存已收到的文本/思考，不虚构工具调用、签名或精确 token 计量；空输出不造空白 assistant。
- 自然错误的最终快照合并已保存的部分回答，不允许回退到只有 user 的旧上下文。
- 下次 AgentLoop 请求时，未完成的 reasoning/signature 只用于历史展示，不重放给 provider；
  已有正文仍可作为上下文。只有思考的中断回答不会构成空 assistant 请求。完整回答的思考策略保持不变。
- 已完成的工具调用声明保留；下一轮仍经过现有 `AgentMessageHistoryRepair` 补齐缺失结果，
  不自动执行旧工具，也不把没有结果的调用直接发送给 provider。

验证：新回归在旧行为下出现部分正文/思考未保存的10个断言失败；修复后通过。
新增 `AgentSessionPartialOutputTests` 覆盖取消立即落盘、快速下一轮、重启重载、纯思考/空输出、
正常完成不重复或降级、异常快照不覆盖、请求过滤中断思考以及孤立工具历史保护。
错误持久化测试同步更新为「用户消息 + 已输出回答」，错误元数据仍不进入模型消息计数。
最终核心回归 **345 tests / 90 suites 全部通过**（含工作区学习测试）；
`check-transcript-error-order.sh` 冷恢复正文/思考/错误同轮展示通过，草稿回归与完整 Debug build 通过。
日志 `/private/tmp/newpi-ui/partial-output-final-{core,transcript,draft,build}.log`。

不保证强制杀进程/断电时尚未经过中断或消息边界的输出；不从旧版已经丢失的内容推断补写。
本次仍未提交，也没有操作用户会话或真实模型。用户对错误持久化的确认不等同于已复验本次部分回答保存。

部分回答修复已重新构建 Release 并更新 `dist/NewPi.app`，构建日志有 BUILD SUCCEEDED 与复制完成标记，
独立严格签名 exit 0。新主二进制 SHA-256：
`f756601c07c5e8ee2929392c921273082279e2b6a9e6e39416f6f6476c37d7c0`，与 Release 构建目录一致。
覆盖前的旧包保存在 `dist-backup/NewPi-before-partial-output-20260912-194729.app`。
请退出旧实例后打开新包，在新一轮出现正文后取消，再重启检查正文和错误仍在；未自动退出用户当前 App。

## 用户最终复验

用户在上述新包交付后明确反馈「验收，正常。提交，继续后续工作」。
错误重启恢复以及取消前已输出内容保存记为用户实机 PASS；前述各阶段的“未复验/未提交”描述保留为历史过程。
本次按要求提交实现、回归与记录；不将该反馈扩大为所有 provider、强制杀进程或断电场景通过。