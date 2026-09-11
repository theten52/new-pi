# 2026-09-12 · A 文档工作台 UI 实施与验证边界

> 用户已选择 **A · 文档工作台**：第一批阅读面/输入区、第二批生产外壳/侧栏/身份栏/角色栏已接入；HTML 原型不进入生产。
> 当前分支 `feat/document-workbench-ui`；第一批 checkpoint `eb95816`、ignore 调整 `db37b18`、第二批外壳 `1715150` 已提交。
> 第二批整窗布局、聊天室守卫和完整 Debug 构建已通过；后续授权实机验收已取得深色普通会话的完整玻璃侧栏截图，并修复重复侧栏按钮。独立 probe 的截图限制仍存在，不代表全量交互或原型同内容验收完成。第一批性能数据保留历史边界。

## 1. 选择与范围

- [A/B 原型](../design/ui-prototype/README.md) 保留为设计对照，B 不作为生产切换模式；原型的六种场景、用量数值与差异面板仍是演示。
- 第一批生产改动集中于正式 CSS、`NewPiChatView`、`NewPiAgentStatusView`、`NewPiApp` 的聊天室展示及 `NewPiChatEmptyStateView`。
- 第一批未全面调整侧栏；第二批已接入根级共享外壳、自定义侧栏、唯一身份 header 与角色栏，仍待用户实机视觉验收。设置页面/导航未重写，仅保留入口；**真实 diff 面板未实现**。
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
| 聊天室 | 第二批将独立目录身份信息统一交给 root header，阶段与实际发言角色另列；既有 `ViewThatFits` 窄栏阶段/发言操作保留，不改阶段业务规则。 |
| 空态 | 中文项目/会话引导与中性工作台风格；不自动创建会话或执行原型建议任务。 |

### 第二批：八项原型对照（实现映射，不是同内容截图验收）

| 对照项 | 生产接入与边界 |
|---|---|
| 1. 根级分栏与宽度 | `NewPiWorkbenchShell` 仅在 root 使用一个 `NavigationSplitView`；侧栏 min/ideal 226、max 250pt。host 实测 detail 左边界约 234pt，包含 macOS 容器边距，不能把它当作纯侧栏内容宽度或玻璃像素证据。 |
| 2. 原生窗口与侧栏开关 | 默认 `.all`，保留系统标题栏、红绿灯与分栏拖动；最终恢复 NavigationSplitView 自动提供的系统 sidebar toggle，不屏蔽系统按钮、不另加手动状态切换。系统负责收展过渡，正式 App 的 AXPress 往返已通过，见末节记录。 |
| 3. 项目卡片 | 自定义 `ScrollView` 侧栏复用 `NewPiWorkbenchProjectCard`；整卡可点击，沿用 `pickProject` → 打开项目流程，不自动创建会话。 |
| 4. 会话/聊天室条目 | 共用 `NewPiWorkbenchSidebarEntry`，默认入口与按钮中文化、轻底及绿色选中态统一；重命名/归档、编辑/删除、每次多显示 5 条及收起行为保留。目录只显示短名，分组/折叠身份仍用完整路径，完整路径提示保留，不合并同名文件夹。 |
| 5. 唯一身份 header | root 的 `NewPiWorkbenchHeader` 展示实际 session label/title（缺省回退）或聊天室名称及对应目录；删除旧 `Chat (branch)` navigationTitle、Session 额外目录行与聊天室重复身份栏。 |
| 6. header 操作 | 导出及“更多”中的日志/API 监控/设置入口保留；会话空 transcript、聊天室无消息或运行中的导出 guard，以及既有业务 guard 均保留。设置页面、真实 diff 面板不在本批实现范围。 |
| 7. 聊天室角色栏 | `NewPiWorkbenchRoleStrip` 显示当前 phase；发言标记使用 `runtime.isRunning && runtime.speakingRoleID == role.id`，不把轮转候选 `currentSpeaker` 当实际发言人。多角色区独立横滚，不挤占阶段文字。 |
| 8. 阅读与输入 | 沿用第一批生产正文和共享 composer；输入、阶段推进、steering 插话、审批/权限不改。原型 demo 的任务、指标、差异与模拟响应不进入生产，也不套用原型的聊天室 Return 规则。 |

### 输入行为不能混同

- 普通会话：空闲时 Return 发送；运行中仍可编辑草稿，但 Return **不发送、不停止**；明确点击停止才停止，发送成功才清空草稿/附件。
- 聊天室：保留既有运行中 Return 插话；运行时另有“发送插话”与停止两个明确动作。不能照原型规则把聊天室 Return 插话禁掉。
- Shift+Return 换行；IME marked text 确认不应误发送。既有模型能力检查、附件校验及授权范围不变。

### 用量是可空真实输入，不是原型占位值

`NewPiAgentStatusBar` 的 popover 固定五项：累计用量、最近一轮、缓存命中率、上下文占用、输出速率。
普通会话从 runtime/ViewModel 传入已有统计或估算；输出速率是流式文本估算，不冒充 provider 精确计量。
每项可为 nil/空白，展示“暂无数据”，不填假数字；聊天室目前只传累计用量与上下文占用，其余保持缺省。
后续鼠标事件探针已验证弹层实际开关及有值/无值数据，见下方鼠标验证；这不等于 VoiceOver 或真实会话计量已完整验收。

### 外观与高对比

生产 CSS 使用浅/深语义变量，原生共享样式在系统高对比外观下使用系统语义色。
普通浅深色的局部 style/contrast 检查不等于系统高对比验收；**Web 高对比尚未完整验收**，也未完成全量 VoiceOver 验收。

## 3. 验证状态（第一批历史结果）

以下为第一批已回填结果，不是第二批性能重跑，也不代表新显式 toolbar 版本的最终验证。

| 范围 | 已知结果 | 不能据此推断 |
|---|---|---|
| 真实 WKWebView | 统一横向 24 后，19 个语义用例、4 个 final geometry 样例零高度/滚动差，以及 light/dark × 900/701/700/480 的 8 组 style/contrast 检查通过。最终这 8 组页面未获得焦点，代码复制按钮键盘可见性检查明确 SKIP。 | 不是所有键盘、原始用户场景或系统对比度的验收；有页面焦点时该断言仍严格执行。 |
| Composer 专项 | 中文 marked text、草稿等验证已报告 PASS。 | 不替代真实中文输入法与完整 App 焦点验收。 |
| 完整 Debug build | 最终 `xcodebuild build`：`BUILD SUCCEEDED`，NewPi scheme / Debug / macOS，产物位于 `build/derived`。 | 不表示运行时交互全部通过；未替换 `dist/NewPi.app`。 |
| 工作台原生 probe | 900/620 × 浅/深四张真实共享组件合成截图；结果 **PARTIAL**，9 项 AX 检查 SKIP；独立输入键盘与 DOM 检查 PASS。 | **不能称发送/停止按钮或用量 popover 点击通过**，不能以退出码 0 等同全通过。 |
| 第一批冷加载/性能 | 500 条历史及聊天室 A/B/A 恢复通过，各场景旧高度读取为 0、锚点误差为 0。三轮 200 行呈现 wall 9.61/9.60/9.59s，最大 MainActor 延迟 13.9/9.1/8.4ms；3 次正文/工具交替、6 个工具与 32px 尾距通过，最大延迟 7.4ms。 | 有限合成场景，未进行严格 A/B 性能统计，不宣称加速；呈现探针仍保留原有 TextField/礼花，不等于新完整输入区性能验收。 |

冷恢复执行 `NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 bash scripts/validation/check-transcript-cold-load.sh`；
呈现执行 `NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 bash scripts/validation/check-transcript-cold-load.sh`。
前者同时覆盖单飞/最新快照、隐藏追赶、进程重建与迟到帧隔离。仅使用临时 fixture，不操作用户会话；
fixture 读取可能命中页缓存，不能视为真实磁盘冷读性能。

### 独立组件 probe 入口及限制

在仓库根目录运行 `NEWPI_WORKBENCH_UI=1 bash scripts/validation/check-transcript-cold-load.sh`。
该模式选择 `WorkbenchUIChecks.swift`（`-Onone`），编译真实共享状态栏、输入外壳/主按钮、生产 NSTextView、Coordinator 与本地渲染资源；
业务状态与指标为内存 fixture，不创建 AgentSession、不访问模型/凭据/用户会话，不执行真实工具。
它不是默认 cold-load 模式，也不是完整侧边栏/聊天室流程测试。

第一批独立组件合成截图位于 `/private/tmp/newpi-ui/`：

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

### 第二批：FULL_WINDOW probe 与截图缺口

入口：`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_FULL_WINDOW=1 bash scripts/validation/check-transcript-cold-load.sh`。
复用生产 `NewPiWorkbenchShell` / `Header` / `ProjectCard` / `SidebarEntry` / `RoleStrip`，侧栏为固定 mock list，
正文沿用独立组件模式的同一 document fixture。room 模式只改变 header/role fixture，**不运行真实 `ChatRoomFlowController`**；
键盘 fixture 仍按普通会话语义执行，不能用它验收真实聊天室插话或阶段流程。

- 已报告 **1200/900 × light/dark × session/room 共 8 组布局与草稿检查通过**，并通过独立真实 `NSEvent` keyDown → 生产 NSTextView 检查与 Web DOM 检查；不是 8 组完整业务交互验收。
- host 实测 detail 左边界约 234pt；这只证明布局读数。独立 component 模式的按钮/popover **9 项 AX SKIP** 仍存在，FULL_WINDOW 不补齐它们。
- 产物命名为 `/private/tmp/newpi-ui/shell-{1200,900}-{light,dark}-{session,room}.png`。根视图 `cacheDisplay` 加同坐标 WK snapshot 合成时，**macOS Tahoe 玻璃侧栏区域空白**；尝试缓存实际 `NSSplitView` 侧栏子视图后仍无有效像素。
- 因此完整窗口视觉捕获明确为 **UNVERIFIED / 不完整截图**。PNG 文件生成、正文非空检查或布局 PASS，都不等于玻璃侧栏截图正确；未完成与原型同内容对照验收，不宣称“完全还原”。该缺口记录为 SKIP，并汇总为 PARTIAL；严格模式下不完整截图会非零退出。
- 当时本机无屏幕录制权限；该 probe 不请求权限、不抓桌面或其他窗口，不以 HTML 重绘替代原生截图。后续用户主动授权的正式 App 验收见下节。
- 显式 toolbar 侧栏按钮接入后，完整 `NewPi` scheme Debug 构建最终通过（`BUILD SUCCEEDED`）；`check-chatroom-controller.sh` 通过通知隔离、目录传播、运行/审批/取消与删除守卫、订阅清理检查。未启动生产会话，未替换 `dist`，没有重新宣称第二批性能提升。

### 后续：窗口内鼠标事件验证

新增入口：`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_INTERACTION=1 bash scripts/validation/check-transcript-cold-load.sh`。
再加 `NEWPI_WORKBENCH_FULL_WINDOW=1` 可在生产共享分栏外壳中运行同一组交互；本轮两种模式均实跑。
此模式验证交互而非生成截图，不运行前述全宽度/外观截图矩阵。

- 使用探针自己的坐标转换视图与实测控件区域，投递 `NSEvent.leftMouseDown/leftMouseUp` 到所属 NSWindow。
	必须命中窗口内容；不调用 send/stop 模型回调冒充按钮，也不使用系统 AX 或 CGEvent 输入权限。
- 已验证：空白点击不发送、非空点击仅发送一次且清空接受的草稿、运行中 Return 不停止、点击停止只触发一次并保留同一 NSTextView 和下一条草稿。
- 已验证：用量点击真正打开/关闭 popover；公开 `NSAccessibility` 对象型 getter 读取到五个标题和全部五项传入值；切换为空值后出现“暂无数据”且不残留旧值。
	仅调用公开 label/title/value/children 接口，不强转未声明的协议，不调用私有属性，不对 CGRect/Bool 返回值做不安全转换。
- 修正了探针尺寸：`NSWindow.contentViewController` 赋值后重新设置 900×820 视口，避免初始 fitting size 导致点击落在窗口外。
- 完整外壳模式中的侧栏按钮定位仍 **SKIP**：独立 NSHostingController 探针未暴露可定位的原生 toolbar 按钮。
	不据此推断正式 WindowGroup 缺少按钮；strict 模式遇到该缺口非零退出。

新验证补齐的是按钮功能与弹层数据接线，不追溯把旧的 9 项 AX SKIP 改成 PASS，
也不证明系统工具栏、完整 VoiceOver、所有宽度/外观组合的鼠标交互或真实聊天室 steering 已通过。
本轮没有生产代码改动，没有访问真实会话、执行模型或修改系统权限。

### 授权后的正式 App 验收（05:42–05:48）

用户手动授予执行宿主辅助功能及屏幕录制权限后，两项系统查询均为 true。
启动的是 `build/derived/Build/Products/Debug/NewPi.app`，不是 `dist`，不再使用内存 fixture 代替正式 WindowGroup。
临时验收程序位于 `/private/tmp/newpi-ui/ActualAppChecks.swift`，编译产物为同目录 `actual-app-checks`，
通过公开 AX 接口定位控件、执行 AXPress；截图使用限定 NewPi window ID 的 `screencapture`，不抓桌面。
这是本机手动授权后的验收辅助程序，不是仓库内的 CI 入口，临时文件清理后不可直接重跑。

**发现并修复：重复侧栏按钮。** 最初截图同时出现系统默认和显式按钮。
`NewPiWorkbenchShell` 的 `.toolbar(removing: .sidebarToggle)` 原来放在 NavigationSplitView 外层，
移到 sidebar 列内后重建、正常重启正式 App；截图确认只剩一个按钮，toolbar AX 树也只列出
`workbench.sidebar.toggle`。这是中间修正；用户随后指出手动开关过渡生硬，最终改为恢复系统按钮，见下一节。

已完成的范围（当前系统深色、普通会话，非全量验收）：

- 正式按钮 AXPress 收起/展开通过，detail 布局恢复；输入框 AX 身份和现有输入内容不变。
	本次输入为空，未植入测试草稿，不能据此声称正式 App 的非空草稿或 IME 已验收。
- 用量弹窗实际打开/关闭，AX 暴露全部五项标题；截图显示历史累计/最近一轮/缓存/上下文值，输出速率缺省显示“暂无数据”。
	未发起新请求，不能验证 provider 计量准确性、流式更新或所有字段全部为空的正式会话场景。
- 原窗口 1539×839pt；1200/900pt 两档检查用量、模型菜单、发送、更多及侧栏按钮不超出窗口，
	输入视口高 78pt、宽大于 400pt，模型菜单与发送按钮无碰撞；随后恢复原尺寸。
- 完整玻璃侧栏截图已取得并查看，正文/身份栏/输入区在当前深色宽窄窗口可见；不是与原型同内容的像素级对照。
- 修正后完整 Debug build 为 `BUILD SUCCEEDED`；共享组件
	`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_INTERACTION=1 NEWPI_WORKBENCH_UI_STRICT=1` 回归通过。

截图在 `/private/tmp/newpi-ui/actual-{initial,sidebar-hidden,sidebar-restored,usage,width-1200,width-900}.png`。
含用户现有界面内容，**不纳入 Git、不上传远程**。未发送消息、调用模型、执行工具或修改会话正文/模型配置；
应用正常启动/退出可能更新既有窗口偏好、滚动状态与诊断日志，不声称磁盘零写入。
正式 App 保持打开，原窗口尺寸已恢复，`dist` 未替换。

尚未覆盖：真实 Session/聊天室切换和非空草稿、聊天室角色/阶段业务、真实发送/取消、附件/IME、
浅色与系统高对比、VoiceOver 朗读及完整焦点路线。前述独立 probe 的 AX/SKIP 结果保留历史边界。

### 最终恢复系统侧栏开关（05:54–05:56）

用户要求保留原系统按钮的平滑过渡。删除手动 ToolbarItem、`workbench.sidebar.toggle` 标识以及
`.toolbar(removing: .sidebarToggle)`；保留 `.all` 初始状态、既有侧栏宽度与外观。
不为测试标识替换系统 UI，也不另设动画时间覆盖 macOS 的过渡与辅助功能策略。

- 完整 Debug 构建通过，确认当前输入为空后正常重启正式 App。
- 新增工作区内 `scripts/validation/NativeSidebarChecks.swift`：显式指定已运行的 App，
	通过公开 AX 检查 toolbar 仅一个系统开关（本机描述为 `Hide Sidebar`），且无旧自定义标识；
	收起/展开、恢复输入区位置与宽度、输入框 AX 身份及现有输入内容保持均通过。
	本检查不写测试草稿、不发送消息、不测量动画帧率，也不冒充 VoiceOver 验收。
- `WorkbenchUIChecks` 的可选侧栏检查改为定位系统 `NSToolbarItem.Identifier.toggleSidebar`，
	不再依赖自定义中文标签。独立宿主若未暴露系统 toolbar 仍如实 SKIP。
- 本次共享组件鼠标 strict 回归两次均在「鼠标探针窗口获得焦点」5s 超时处中止；
	编译和前置 Markdown/详情检查通过，但本轮鼠标交互未执行，不能沿用上一轮 PASS 冒充本轮通过。
	未放宽断言或反复修改生产 UI 规避焦点限制。

新的源文件放在工作区内，避免工作区外编辑授权；旧临时 `ActualAppChecks` 的自定义按钮测试已过时，
不要再用其中 sidebar/resize 模式验收最终系统按钮。新入口见 [脚本文档](../../scripts/README.md#正式-app-系统侧栏开关验证)。

### 后续提交与四场景鼠标回归（06:00–06:03）

系统按钮修正与正式 App 验收脚本已独立提交为 `c7a158d`，学习资料及其索引未纳入。
后续只修改组件探针：增加激活结果、启动完成、key/main、可见性和前台 bundle ID 的焦点诊断，
保留原有 5s 严格断言。首次带诊断的 900pt 浅色实跑通过；此前两次焦点超时未复现，根因未确定，
不能把日志增加或时序变化称为焦点修复。

新增鼠标模式可选 `NEWPI_WORKBENCH_INTERACTION_NARROW=1` 与 `NEWPI_WORKBENCH_INTERACTION_DARK=1`，
分别选择组件 620pt 及深色；默认仍为 900pt 浅色，不改默认截图矩阵，也不改用户系统外观。
**900/620 × 浅/深四组 strict 均完整通过**：原生/WebKit 外观与宽度同步、max 800 阅读列、
无横向溢出、长模型名与发送按钮无碰撞、实际鼠标送停一次、运行中 Return 不停止、
保留下一条非空 fixture 草稿，以及用量开关/五项有值/无值无旧数据。
本轮未改生产逻辑、不访问模型或用户会话；仍不是正式 App 浅色/聊天室/VoiceOver 验收。

## 4. 尚需人工验收与结果回填

- [x] 回填第一批统一横向 24 后的最终 WKWebView 复跑及完整 Debug 构建结果，保留无页面焦点的 SKIP。
- [x] 回填第一批冷加载与呈现回归的命令、数值和限制，不覆盖旧修复记录，不声称第二批性能重跑或严格性能对照。
- [x] 回填第二批显式 toolbar 后的最终 Debug build/controller 结果；整窗布局复跑仍通过。
- [x] 独立与整窗探针的真实鼠标送停、草稿保留、用量开关和有值/无值展示通过；系统 toolbar 定位仍 SKIP。
- [x] 授权后正式 App 深色普通会话的侧栏往返、空输入保持、用量开关、宽窄布局和完整玻璃截图通过；重复按钮已修复并复验。
- [x] 按用户反馈恢复系统侧栏按钮，完整构建及正式 App 系统开关往返通过；本轮独立鼠标探针焦点超时单独保留。
- [x] 后续增加焦点诊断并补齐 900/620 × 浅/深四组组件鼠标 strict 回归；均通过，旧焦点超时保留未复现结论。
- [ ] 完成浅色/聊天室外壳与角色栏实机验收及原型同内容视觉对照；当前深色普通会话截图不能替代全部场景。
- [ ] 实际 App 侧边栏切换 Session/聊天室、草稿与滚动恢复；宽窄窗口目录 header 与全部阶段操作可达。
- [ ] 实际聊天室手动推进/指定角色/讨论/投票/执行/Review/暂停收尾，运行中 Return 与显式插话、停止互不混淆。
- [ ] 实际用量动态更新/全部缺省数据、发送/停止可用性、模型与思考级别菜单及运行中禁用状态（当前历史会话 popover 开关及五项展示已通过）。
- [ ] 实际附件选择/拖拽/粘贴/移除/预览，中文输入法确认、键盘焦点与弹层关闭后的焦点恢复。
- [ ] 系统高对比（尤其 Web 正文）、VoiceOver、深浅外观与不同缩放的可读性。

旧 `BACKLOG-BUBBLE-BG` 保留 ID，标为 **superseded by A**，不再按轮次彩色气泡要求验收。
统一待办见 [TODO](../TODO.md)；原有收尾修复和历史调研结论保留各自时间边界，不由本次外观调整追溯改写。