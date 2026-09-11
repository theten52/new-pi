# 2026-09-12 · A 文档工作台 UI 实施与验证边界

> 用户已选择 **A · 文档工作台**，生产阅读面与共用输入区已调整；不是把 HTML 原型直接接入 App。
> 本文记录本轮实际执行的构建、渲染/输入回归与验证限制；不是全量产品交互验收。
> 最终复跑、冷加载及呈现结果已回填；AX 按压与无页面焦点的键盘样式检查仍未验证。

## 1. 选择与范围

- [A/B 原型](../design/ui-prototype/README.md) 保留为设计对照，B 不作为生产切换模式；原型的六种场景、用量数值与差异面板仍是演示。
- 本轮生产改动集中于正式 CSS、`NewPiChatView`、`NewPiAgentStatusView`、`NewPiApp` 的聊天室展示及 `NewPiChatEmptyStateView`。
- 侧边栏和设置导航没有全面重写；**真实 diff 面板未实现**。不因原型存在对应按钮就宣称已有生产功能。
- 模型选择、思考级别、provider、权限与审批逻辑未改；不更改单文档架构、流式持久化边界或会话保活机制。

## 2. 已实施的展示规则

| 区域 | 当前实现与保留边界 |
|---|---|
| 阅读列 | Web `#transcript` 最大 800px（含 padding），横向统一 24px、顶部 24px、底部 32px；原生 composer 外层同为最大 800pt（含横向 24pt）。按各自可用视口居中，Web 常驻滚动条可能占用宽度；不是正文净宽 800。 |
| 正文 | assistant 无彩色底板，user 左对齐、中性背景；自然高度、块级增量、收尾语义修复、CV 与文档内唯一 scroll writer 保持，不恢复人工高度占位。 |
| 内容与操作 | 保留复制、Fork、代码块、思考/工具/处理详情折叠、错误语义和附件展示。Fork 仍仅在有对应消息索引的普通会话提供，不给聊天室新增 Fork。 |
| 输入区 | `NewPiComposerSurface` 共用外壳；普通会话模型菜单移到底栏，附件入口保留；沿用同一 NSTextView、固定四行视口、草稿与 marked text 同步机制。 |
| 状态 | 默认仅主要状态与“用量”入口；状态标签静态，不再用 timer 呼吸/闪烁；普通 Session 完成礼花移除，不宣称所有调试探针也移除了礼花。 |
| 主操作 | `NewPiComposerPrimaryAction` 共用发送/停止按钮，固定 32×32，不绑定 Return 为停止快捷键。 |
| 聊天室 | 独立目录 header、角色与阶段控制全部保留；`ViewThatFits` 让发言/阶段操作在窄栏改为两行，不改阶段业务规则。 |
| 空态 | 中文项目/会话引导与中性工作台风格；不自动创建会话或执行原型建议任务。 |

### 输入行为不能混同

- 普通会话：空闲时 Return 发送；运行中仍可编辑草稿，但 Return **不发送、不停止**；明确点击停止才停止，发送成功才清空草稿/附件。
- 聊天室：保留既有运行中 Return 插话；运行时另有“发送插话”与停止两个明确动作。不能照原型规则把聊天室 Return 插话禁掉。
- Shift+Return 换行；IME marked text 确认不应误发送。既有模型能力检查、附件校验及授权范围不变。

### 用量是可空真实输入，不是原型占位值

`NewPiAgentStatusBar` 的 popover 固定五项：累计用量、最近一轮、缓存命中率、上下文占用、输出速率。
普通会话从 runtime/ViewModel 传入已有统计或估算；输出速率是流式文本估算，不冒充 provider 精确计量。
每项可为 nil/空白，展示“暂无数据”，不填假数字；聊天室目前只传累计用量与上下文占用，其余保持缺省。
存在视图与数据接线不代表真实弹层点击已经验收，见下方 AX 限制。

### 外观与高对比

生产 CSS 使用浅/深语义变量，原生共享样式在系统高对比外观下使用系统语义色。
普通浅深色的局部 style/contrast 检查不等于系统高对比验收；**Web 高对比尚未完整验收**，也未完成全量 VoiceOver 验收。

## 3. 验证状态（本轮最终复跑）

| 范围 | 已知结果 | 不能据此推断 |
|---|---|---|
| 真实 WKWebView | 统一横向 24 后，19 个语义用例、4 个 final geometry 样例零高度/滚动差，以及 light/dark × 900/701/700/480 的 8 组 style/contrast 检查通过。最终这 8 组页面未获得焦点，代码复制按钮键盘可见性检查明确 SKIP。 | 不是所有键盘、原始用户场景或系统对比度的验收；有页面焦点时该断言仍严格执行。 |
| Composer 专项 | 中文 marked text、草稿等验证已报告 PASS。 | 不替代真实中文输入法与完整 App 焦点验收。 |
| 完整 Debug build | 最终 `xcodebuild build`：`BUILD SUCCEEDED`，NewPi scheme / Debug / macOS，产物位于 `build/derived`。 | 不表示运行时交互全部通过；未替换 `dist/NewPi.app`。 |
| 工作台原生 probe | 900/620 × 浅/深四张真实共享组件合成截图；结果 **PARTIAL**，9 项 AX 检查 SKIP；独立输入键盘与 DOM 检查 PASS。 | **不能称发送/停止按钮或用量 popover 点击通过**，不能以退出码 0 等同全通过。 |
| 本轮冷加载/性能 | 500 条历史及聊天室 A/B/A 恢复通过，各场景旧高度读取为 0、锚点误差为 0。三轮 200 行呈现 wall 9.61/9.60/9.59s，最大 MainActor 延迟 13.9/9.1/8.4ms；3 次正文/工具交替、6 个工具与 32px 尾距通过，最大延迟 7.4ms。 | 有限合成场景，未进行严格 A/B 性能统计，不宣称加速；呈现探针仍保留原有 TextField/礼花，不等于新完整输入区性能验收。 |

冷恢复执行 `NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 bash scripts/validation/check-transcript-cold-load.sh`；
呈现执行 `NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 bash scripts/validation/check-transcript-cold-load.sh`。
前者同时覆盖单飞/最新快照、隐藏追赶、进程重建与迟到帧隔离。仅使用临时 fixture，不操作用户会话；
fixture 读取可能命中页缓存，不能视为真实磁盘冷读性能。

### 真实组件 probe 入口及限制

在仓库根目录运行 `NEWPI_WORKBENCH_UI=1 bash scripts/validation/check-transcript-cold-load.sh`。
该模式选择 `WorkbenchUIChecks.swift`（`-Onone`），编译真实共享状态栏、输入外壳/主按钮、生产 NSTextView、Coordinator 与本地渲染资源；
业务状态与指标为内存 fixture，不创建 AgentSession、不访问模型/凭据/用户会话，不执行真实工具。
它不是默认 cold-load 模式，也不是完整侧边栏/聊天室流程测试。

本次交接截图位于 `/private/tmp/newpi-ui/`：

- `workbench-light.png`：900 浅色。
- `workbench-dark.png`：900 深色。
- `workbench-narrow.png`：620 浅色。
- `workbench-narrow-dark.png`：620 深色。

截图为原生 NSView `cacheDisplay` 与同坐标 WK `takeSnapshot` 合成，不是 HTML 原型或完整 App 屏幕截图。
本机 `SwiftUI.AccessibilityNode` 未声明完整 `NSAccessibilityProtocol`，公开协议路径无法找到所需按钮，
故四组 AX 主按钮边界、四组用量 popover 按压/有值与空值展示、一次 disabled/send/stop 按压检查，共 **9 项 SKIP**。
不强转协议、不用替代回调冒充按钮按压；键盘与 DOM 独立 PASS 不补齐这些缺口。

严格模式入口：`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_UI_STRICT=1 bash scripts/validation/check-transcript-cold-load.sh`。
任一 FAIL，或 strict 下任一 SKIP，都会非零退出；上述 AX 限制仍在时 strict 会失败。
可用 `NEWPI_UI_SNAPSHOTS` 指定截图目录；入口说明另见 [脚本文档](../../scripts/README.md#文档工作台真实组件-probe2026-09-12)。

## 4. 尚需人工验收与结果回填

- [x] 回填统一横向 24 后的最终 WKWebView 复跑及完整 Debug 构建结果，保留无页面焦点的 SKIP。
- [x] 回填本轮冷加载与呈现回归的命令、数值和限制，不覆盖旧修复记录，不声称严格性能对照。
- [ ] 实际 App 侧边栏切换 Session/聊天室、草稿与滚动恢复；宽窄窗口目录 header 与全部阶段操作可达。
- [ ] 实际聊天室手动推进/指定角色/讨论/投票/执行/Review/暂停收尾，运行中 Return 与显式插话、停止互不混淆。
- [ ] 实际用量 popover 开关、五项真实/缺省数据，发送/停止可用性、模型与思考级别菜单及运行中禁用状态。
- [ ] 实际附件选择/拖拽/粘贴/移除/预览，中文输入法确认、键盘焦点与弹层关闭后的焦点恢复。
- [ ] 系统高对比（尤其 Web 正文）、VoiceOver、深浅外观与不同缩放的可读性。

旧 `BACKLOG-BUBBLE-BG` 保留 ID，标为 **superseded by A**，不再按轮次彩色气泡要求验收。
统一待办见 [TODO](../TODO.md)；原有收尾修复和历史调研结论保留各自时间边界，不由本次外观调整追溯改写。