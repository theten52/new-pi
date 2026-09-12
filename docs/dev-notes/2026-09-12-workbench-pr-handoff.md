# 文档工作台与会话恢复修复 · PR 草稿

> 本文是本地交付说明，不代表已创建远程 PR。产品实现与用户验收提交：`eecccc7`。
> 本地跟踪基线 `origin/main = 7b5d656`，当时范围为 13 个提交、49 个文件；发布前需刷新远程基线。

## 建议标题

feat(ui): 文档工作台与会话草稿、中断结果恢复

## 改动概要

- 接入 A 文档工作台：统一阅读列、输入区、项目/会话侧栏、身份栏、聊天室角色栏及按需用量弹窗。
- 使用系统自带侧栏开关与过渡，不为自动化测试替换原生交互。
- Session 文本/图片及聊天室文本草稿上移至独立运行时草稿对象，跨详情视图重建保留，逐键不通知根列表。
- 聊天室用户消息保存成功后才更新内存、清稿和落底；写入失败保留草稿，避免重试重复。
- Session 错误固定原轮次，并作为 JSONL entry 的可选展示元数据持久化，不作为模型消息。
- 取消/异常中断时保存已收到的正文和思考；完整回答保留正常完成状态，旧 run 的迟到事件不覆盖下一轮。
- 中断思考只用于历史展示，下一轮 AgentLoop 请求不重放其 reasoning/signature；原有正文可作为上下文。

## 验证证据

- 用户已明确复验：错误原轮次固定、错误跨重启恢复，以及取消前已输出内容保存正常。
- 对提交 `eecccc77910865adb2d40a09c0c524378a4abe2a` 使用 `git archive` 导出临时副本，
  在其 `Packages/NewPiCore/` 执行 `swift test`：**327 tests / 85 suites 全部通过，exit 0**。
  不包含工作区未跟踪 Labs；日志 `/private/tmp/newpi-ui/workbench-clean-head-core.log`。
- 工作区全量测试（包含学习套件）：345 tests / 90 suites 通过，两者数量不可混用。
- 生产方法提取回归覆盖错误排序/冷恢复正文思考、草稿重建/隔离和聊天室发送失败；Debug 构建通过。
- 前序实机/DOM验收的范围及未覆盖项见[验收记录](2026-09-12-workbench-acceptance.md)，
  中断结果和磁盘恢复的专项证据见[持久化记录](2026-09-12-session-error-persistence.md)。

## Release 交付

- `dist/NewPi.app` 已更新，本机 arm64 / macOS 15+ / `0.1.0 (1)`，ad-hoc 签名。
- 严格 `codesign --verify --deep --strict` 通过；dist 与 Release 构建目录主二进制一致：
  `f756601c07c5e8ee2929392c921273082279e2b6a9e6e39416f6f6476c37d7c0`。
- 最近回退包：`dist-backup/NewPi-before-partial-output-20260912-194729.app`。
- 二进制、回退包及用户截图不进入 Git；没有 Developer ID 签名、公证或 Universal 构建，不作为公开分发就绪的证明。

## 兼容性与剩余边界

- 旧 JSONL 无 `transcriptErrors` 字段仍可读取；降级旧 App 后重写文件可能丢弃新字段，回退前应备份会话。
- 已经由旧版丢失、从未保存的错误/输出无法追溯恢复。
- 草稿仍为内存态：Session LRU 淘汰、切项目、退出后的保留不在保证内。
- 强制杀进程/断电时未到保存边界的内容、持续磁盘失败、部分写入及多进程并发不承诺事务恢复。
- VoiceOver、全量 provider/附件格式及后台运行组合等仍按验收记录保留边界，不因核心测试通过而关闭。
- 学习索引 `docs/README.md` 的本地修改、`docs/learning/` 和 `Tests/NewPiCoreTests/Labs/` 未纳入本批提交。

## 发布前下一步

1. 明确授权后刷新远程基线并推送 `feat/document-workbench-ui`，禁止强推覆盖他人提交。
2. 用上述概要与证据创建指向 `main` 的 PR，检查差异及远程 CI。
3. 合并需单独确认；本地测试成功不意味着已推送、已通过远程 CI 或已合并。