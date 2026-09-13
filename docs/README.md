# NewPi 文档索引

> 2026-09-12 整理。文档按用途区分；“已实施”表示已有代码，不代表所有端点和体验均已验收。
> 以当前源码核实行为，不从旧计划的未来时态推断缺失功能。

## 从这里开始

| 文档 | 用途 |
|---|---|
| [项目 README](../README.md) | 产品能力、开发与打包入口 |
| [架构总览](architecture.md) | 当前模块、事件流、存储与渲染边界 |
| [UI 架构 ADR](ui-architecture-decision.md) | 当前单文档决策及历史迁移依据；先读状态说明 |
| [完全 Swift 原生 UI 路线评估](swift-native-route-assessment.md) | 2026-09-14：暂不全面去掉 WebView；收益、迁移成本与重新评估条件 |
| [TODO](TODO.md) | 未解决问题、待验收/待复核项与已完成条目索引 |
| [App 运行指南](../NewPiApp/README.md) | Xcode 运行、provider 配置与会话入口 |
| [构建与校验脚本](../scripts/README.md) | App 打包及原生 UI/WebKit 校验；区别于核心包测试 |

## 界面设计实验（非生产实现）

- [主聊天界面 A/B 原型](design/ui-prototype/README.md)：可交互的文档工作台与轻量聊天方案，含六种演示场景、深浅色及窄窗口。尚未接入 App，不替代当前架构或已实现功能说明。

## 功能设计与实现记录

| 文档 | 当前阅读定位 |
|---|---|
| [A 文档工作台 UI](dev-notes/2026-09-12-document-workbench-ui.md) | 用户已选 A；生产阅读面/共用输入区已调整，原型仍仅作设计对照；probe PARTIAL、最终复跑与人工验收边界 |
| [Provider 配置](provider-config-design.md) | 配置设计与演进记录；示例类型不代替当前 Swift schema |
| [审批权限](approval-permissions-design.md) | 审批设计与实现记录；“现状与痛点”为实施前背景，聊天室后续见下方授权记录 |
| [API 指标](api-metrics-design.md) | 指标模型、请求时间线及实现边界 |
| [聊天室设计](chatroom-design.md) | 当前聊天室功能、流程与实现清单 |
| [聊天室 Session 复用分析](chatroom-session-reuse-analysis.md) | 已落地的引擎复用与历史原始计划；聊天室存储仍独立 |
| [图片输入](multi-modal-vision-plan.md) | MVP 已实现；保留压缩、端点兼容及未完成验证的边界 |
| [详情折叠](detail-collapse-plan.md) | 已实施的 thinking/工具/中间输出分组记录 |
| [多模型协作流程](multi-model-collaboration-plan.md) | 人与模型的开发协作约定，不等同于 App 聊天室引擎；v1 为历史流程 |

## 已实施、被取代或未实施的方案

| 文档 | 状态 |
|---|---|
| [聊天室平铺与 Markdown 复用](chatroom-flat-markdown-reuse-plan.md) | Phase 0–2 已落地；旧 sheet/列表与需求确认段落仅作实施前快照 |
| [会话瞬时恢复方案](session-switch-instant-resume-plan.md) | 热 runtime 与锚点恢复已实现；旧逐消息高度方案已被单文档取代，快照兜底不代表已实现 |
| [渲染产物 replay 方案](rendered-result-replay-plan.md) | 单文档持久化 HTML replay 尚未接入；不等同于 WebView 热保活 |
| [UI 目标架构](ui-target-architecture.md) | 单文档迁移已完成；原迁移计划与未来方向按小节区分 |
| [UI 外部调研](ui-architecture-research.md) | 13 个第三方仓库调研与迁移前台账，不是当前待办表 |
| [UI 调研核验](ui-architecture-research-verification.md) | 历史源码核验及后续校正，旧原生高度路径结论不再直接适用 |

## 复盘与证据

- [流式停滞复盘](streaming-stall-postmortem.md)：事件消费、服务端尾段与 UI 性能的边界。
- [聊天室流式复盘](chatroom-live-streaming-postmortem.md)：当时故障与修复过程，不作为当前缺失功能清单。
- [聊天室授权记录](dev-notes/2026-09-11-chatroom-authorization.md)：较新的审批行为与验证记录。
- [长会话渲染复核](dev-notes/2026-09-11-long-session-rendering-review.md)、[冷加载记录](dev-notes/2026-09-11-transcript-cold-load.md)：性能证据与未解决问题。
- [dev-notes/](dev-notes/)：按日期保留的调试、实验和历史审查；旧行号、旧实现、旧测试结果只对当时版本成立。
- [早期 Provider spec](superpowers/specs/2026-08-24-provider-config-design.md)：原始设计，不代替当前配置实现。

## 维护约定

1. 当前架构概述维护在 `architecture.md`，渲染决策维护在 ADR；调研和迁移计划保留历史证据，避免重复复制整份待办。
2. 新问题记入 `TODO.md` 并链接证据；已完成、待验收、待复核必须区分，不凭“存在相关代码”直接关闭用户体验问题。
3. 改变 UI 跨文档结论时，同步 ADR、research、verification、target 的状态说明，不恢复已删除的原生高度路径。
4. 未实施的建议路径明确标为建议/按需创建；不要写成现有文件，也不要为消除引用而创建无内容文档。
5. 不在入口文档固定测试文件数量；验证记录注明范围，不把核心包测试等同于 App/WebKit 验证。