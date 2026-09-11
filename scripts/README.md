# NewPi 打包脚本使用说明

`scripts/package.sh` 一键构建 NewPi macOS 应用，并产出本机可直接运行的 `.app` 包。

---

## 先决条件

- macOS + **Xcode**（含 Command Line Tools：Swift 6、cocoa 工具链）
- **仅本机运行**：无需 Apple 开发者账号（脚本默认使用 **ad-hoc 签名**）
- **分发给别人**：需要 Apple Developer 证书 + 公证（见[签名说明](#签名说明)）

---

## 用法

### 默认（Release）

```bash
./scripts/package.sh
```

### 指定配置

```bash
./scripts/package.sh Debug
```

### 自定义（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `SCHEME` | `NewPi` | 构建的 scheme |
| `CODE_SIGN_STYLE` | `Manual` | 签名方式 |
| `CODE_SIGN_IDENTITY` | `-` (ad-hoc) | 本地签名身份 |
| `DEVELOPMENT_TEAM` | （空） | 开发团队（正式签名时填写） |

示例（正式签名时）：

```bash
DEVELOPMENT_TEAM=TEAMID CODE_SIGN_IDENTITY="Apple Development" ./scripts/package.sh
```

---

## 产物与运行

- **产物位置**：`<项目根>/dist/NewPi.app`
- **运行**：双击 `NewPi.app`，或

```bash
open dist/NewPi.app
```

- **构建中间产物**：`<项目根>/build/derived`（已被 `.gitignore` 忽略，不进入版本库）

---

## 脚本做了什么

1. `xcodebuild` 构建指定配置（默认 Release，ad-hoc 本地签名）
2. 将产物 `NewPi.app` 拷贝到 `./dist/`
3. 清除 `com.apple.quarantine` 标记并执行 `codesign --verify` 校验签名
4. 打印产物路径与运行命令

---

## 签名说明

| 场景 | 签名方式 | 是否可分发 |
|---|---|---|
| **本地开发 / 自用** | ad-hoc（默认，`CODE_SIGN_IDENTITY=-`） | 仅本机 |
| **分发给他人** | Apple Development / Distribution 证书 + 公证 | 是 |

> ad-hoc 签名的 `.app` 只有构建它的这台机器能运行；拿到别的 Mac 上会被 Gatekeeper 提示「无法验证开发者」。正式分发需配置证书（证书在 `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY` 传入）并执行 `notarytool` 公证。

---

## 常见问题

**问：点击 `dist/NewPi.app` 提示「已损坏，无法打开」或「无法验证开发者」**
答：这是 ad-hoc 签名的预期现象，仅本机有效。构建这台机器上已清除 quarantine，可直接运行；其他机器需正式签名。

**问：想强制全量重编**
答：删除本地构建缓存后重新运行脚本即可：

```bash
rm -rf build/derived && ./scripts/package.sh
```

**问：想导出 `.dmg` 归档**
答：对打包后的 `.app` 用 `hdiutil create`：

```bash
hdiutil create -volname NewPi -srcfolder dist/NewPi.app -ov -format UDZO dist/NewPi.dmg
```

## 聊天室 App 层守卫验证

macOS + Swift 6 环境运行 `scripts/validation/check-chatroom-controller.sh`。
脚本编译真实聊天室控制器，检查运行/取消收尾/待审批的删除保护，以及失效目录的发言拦截和恢复。
转录适配器使用空测试替身；不会调用模型、执行工具或修改已有聊天数据。
可用 `NEWPI_VALIDATION_SCRATCH` 指定 SwiftPM 临时构建目录。

## 聊天室输出渲染验证

- `scripts/validation/check-chatroom-rendering.sh`：编译真实条目模型、共享流式判定和聊天室适配器，覆盖插话、Thinking、分段、完成态、中断标记及 Session 兼容。
- `scripts/validation/check-transcript-dom.sh`：使用独立 WKWebView 加载真实 JS/CSS，验证非末尾消息继续流式、DOM 身份、卡片手动展开、正文定型；需要 macOS 图形登录会话，不发送模型请求。
- Swift Package 的 `ChatRoomRenderingTests.swift` 覆盖 120ms 缓冲、事件/审批顺序、取消/失败保留及磁盘重载顺序。

### Markdown 收尾语义与原生呈现回归（2026-09-12）

`./scripts/validation/check-transcript-dom.sh` 新增 19 个真实 WKWebView 语义用例，覆盖松散/嵌套列表、
引用、表格、前向/后向及列表内 reference、typographer、长/未闭合/嵌套围栏、缩进代码和换行。
字符级增量与同前缀一次性流式结果对照，另检查同源最后流式快照与最终态；四个列表/引用几何样例
检查高度、滚动、末行位置、32px 尾距与上翻保锚。19 个用例已全部通过，四例 `heightDelta=0`、
`scrollDelta=0`；既有 100 块 199 次插入与 200 行单围栏 0 次子树重建保持。

原生 200 行三轮呈现对照（仓库根目录运行；基线只替换临时资源中的 renderer）：

- 固定基线：`NEWPI_PRESENTATION_REPLAY=1 NEWPI_RENDERER_REVISION=5b6f302 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 ./scripts/validation/check-transcript-cold-load.sh`
- 修复版：`NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 ./scripts/validation/check-transcript-cold-load.sh`
- 冷恢复：`NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 ./scripts/validation/check-transcript-cold-load.sh`

基线实跑时使用 `NEWPI_RENDERER_REVISION=HEAD`，当时为 `5b6f302`；回溯命令固定提交，避免 HEAD 漂移。
`NEWPI_PRESENTATION_REPLAY=1` 选择真实 SwiftUI/Coordinator/WKWebView 的可见合成呈现探针（`-Onone`），
含状态栏、rail、礼花及正文/工具交替与折叠；不是持久 HTML replay，也不是完整 App 构建或全核心测试。
上述对照已运行，仅支持该场景无明显性能退化，不宣称加速。500 条历史首载/切回、聊天室 A/B/A 的
`heightReads=0`、`anchorErrorPX=0`，进程恢复等回归通过；首载无恢复锚点时偏差字段记 0，不能当作恢复精度证据。
完整数据、解析成本与原始用户场景待验收边界见 [修复记录](../docs/dev-notes/2026-09-12-markdown-final-reflow.md)。

## 聊天室性能基线

`bash scripts/validation/check-chatroom-performance.sh` 使用真实控制器、适配器和签名函数，输出短对话、长对话、多工具历史的 CSV。
每个场景先预热，再合成 100 次正文更新；统计 Store/详情通知数，以及适配和签名比较的 P50/P95。
Swift 探针以 `-O` 编译，链接 Debug Core；不是整个 Release App 的帧率测试。
只读现有存储、不保存合成聊天室，不访问模型。

对比通知优化前后（不切分支、不修改工作区）：

```bash
NEWPI_CONTROLLER_REVISION=e7b1daf bash scripts/validation/check-chatroom-performance.sh
NEWPI_EXPECT_FILTERED_NOTIFICATIONS=1 bash scripts/validation/check-chatroom-performance.sh
```

`NEWPI_CONTROLLER_REVISION` 仅替换该基准中的控制器源码，要求与当前数据类型兼容；并非任意历史版本的完整 App 对比。

`NEWPI_TRANSCRIPT_PERFORMANCE=1 bash scripts/validation/check-transcript-dom.sh` 在独立 WKWebView 中测量真实 JS/CSS 的首次载入和 30 次增量 apply。
该计时包含同步 JSON 序列化、DOM 修改及被触发的同步布局，不含 Swift→JS 跨进程排队、异步绘制、GPU 提交和屏幕呈现。
三个 DOM 场景与原生基准的体量相近，但不保证条目组成逐项相同（原生适配器还会插入阶段行）。

## 历史冷加载与锚点恢复

`bash scripts/validation/check-transcript-cold-load.sh` 编译真实 Coordinator、HTML 工厂、聊天室适配器和 WKWebView，使用临时生成的 500 条带代码块历史。
对比前后的命令：

```bash
NEWPI_RENDERER_REVISION=0c5d8fc bash scripts/validation/check-transcript-cold-load.sh
NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 bash scripts/validation/check-transcript-cold-load.sh
```

`NEWPI_RENDERER_REVISION` 仅在临时 App 的资源目录替换指定版本的 `markdown-renderer.js`，不修改工作区。
测量 JSONL 读取、消息适配、外壳加载、原生 diff/编码/投递、JS apply 及首次投递后两个 RAF 的时间。
检查多次待加载快照只投递一次、消息 ID 不重复、正文和代码非空、切回后的锚点偏差、重复快照不重复投递。
覆盖 Session 形态首次加载、聊天室 A/B/A 冷恢复及跨类型切回；不包括 SessionManager 解码、完整 SwiftUI 导航或 Session 保活命中。
探针使用真实生产源码，只有诊断 logger/metrics 替换为空实现，滚动 sessionID 为 nil，不写用户滚动位置。
文件读取紧接着 fixture 写入，可能命中 OS 页缓存；不能作为真实磁盘冷读或整个 App 的首屏性能结论。

## 文档工作台真实组件 probe（2026-09-12）

仓库根目录运行 `NEWPI_WORKBENCH_UI=1 bash scripts/validation/check-transcript-cold-load.sh`。
该模式选择 `WorkbenchUIChecks.swift`（`-Onone`），使用真实共享状态栏、composer 外壳/主按钮、生产 NSTextView、Coordinator 与 WKWebView；
业务状态和指标为内存 fixture，不调用模型、不访问凭据或用户会话，不代表完整 App、侧边栏或聊天室阶段集成验收，也不是默认冷加载/性能模式。
需要 macOS 图形登录会话；采用进程内公开 AppKit 接口，不请求系统辅助功能或屏幕录制权限。

独立 component 模式：900/620 × 浅深四张 NSView + WK snapshot 合成截图默认写入 `/private/tmp/newpi-ui/`：
`workbench-light.png`、`workbench-dark.png`、`workbench-narrow.png`、`workbench-narrow-dark.png`；可用 `NEWPI_UI_SNAPSHOTS` 改目录。
本次交接结果为 **PARTIAL**：四张截图已生成，独立键盘/DOM 检查 PASS；`SwiftUI.AccessibilityNode` 未声明完整 `NSAccessibilityProtocol`，
9 项 AX 按钮边界/用量 popover/disabled-send-stop 按压检查 **SKIP**，不能称按钮或用量点击通过，退出码 0 不等于全部通过。

严格入口：`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_UI_STRICT=1 bash scripts/validation/check-transcript-cold-load.sh`。
实际 FAIL 总会非零退出；strict 下任何 SKIP 也失败，故上述 AX 限制仍在时 strict 会失败。

第二批新增完整窗口选择：`NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_FULL_WINDOW=1 bash scripts/validation/check-transcript-cold-load.sh`。
复用生产 `NewPiWorkbenchShell` / `Header` / `ProjectCard` / `SidebarEntry` / `RoleStrip`；固定 mock list 与上述同一 document fixture，
room 模式只切换 header/role fixture，不运行真实 `ChatRoomFlowController`，不能验收聊天室阶段或 steering 业务。
已报告 1200/900 × light/dark × session/room 共 8 组布局/草稿、独立真实 keyDown 与 Web DOM 检查通过；
host 实测 detail 左边界约 234pt（含 macOS 容器边距；侧栏 min/ideal 226、max 250pt），不代表玻璃材质截图正确。

全窗口产物为同目录下 `shell-{1200,900}-{light,dark}-{session,room}.png`，但**完整截图 UNVERIFIED**：
根 NSView `cacheDisplay` + WK snapshot 在 macOS Tahoe 的玻璃侧栏区域空白，即使尝试实际 `NSSplitView` 子视图缓存仍无有效像素。
生成 PNG 或退出码 0 不等于完整视觉捕获，未完成与原型同内容对照验收；玻璃缺口计入 SKIP/PARTIAL，strict 会因此失败。
该轮无录屏权限，probe 本身不请求权限、不抓桌面；独立 component 模式的按钮/popover **9 项 AX SKIP** 仍需单独解决。

第一批 WK/Debug 复跑及 cold/performance 数据已记录，不能当作第二批性能重跑；
显式 toolbar 侧栏按钮后的完整 Debug build 和聊天室 controller 守卫最终复跑已通过。
八项原型对照、人工验收清单及证据边界见 [实施记录](../docs/dev-notes/2026-09-12-document-workbench-ui.md)。

### 原生鼠标送停与用量验证

运行 `NEWPI_WORKBENCH_UI=1 NEWPI_WORKBENCH_INTERACTION=1 bash scripts/validation/check-transcript-cold-load.sh`。
可追加 `NEWPI_WORKBENCH_FULL_WINDOW=1` 使用完整生产共享外壳；该模式只验证交互，不运行全尺寸截图矩阵。
两种模式已实跑：窗口内真实鼠标事件触发送停，断言回调次数、禁用行为和草稿保留；用量 popover 实际开关，
公开对象型可访问性 getter 核对五项传入值及无值时无旧数据。不直接调用 fixture 回调作为通过证据，不请求系统输入或录屏权限。

完整窗口的侧栏 toolbar 按钮在独立宿主中仍无法定位，明确 SKIP；加 `NEWPI_WORKBENCH_UI_STRICT=1` 时因此失败。
鼠标检查通过不等于旧 AX 按压检查或 VoiceOver 已通过，也不包括真实会话网络调用、聊天室阶段业务及全部外观组合。

组件鼠标模式可附加 `NEWPI_WORKBENCH_INTERACTION_NARROW=1`（620pt，默认 900pt）与
`NEWPI_WORKBENCH_INTERACTION_DARK=1`（深色，默认浅色）；NARROW 在 FULL_WINDOW 模式不生效。
2026-09-12 后续实跑四种组合均在 strict 下通过：原生/WebKit 外观尺寸一致、阅读列无横向溢出、
长模型名与 32×32 主按钮无碰撞，鼠标送停、草稿保持及用量有值/无值开关通过。
焦点检查前及超时时打印 `FOCUS` 状态（应用激活结果、启动完成、key/main、可见性和前台 bundle ID）；
保留 5s 焦点断言。此前两次焦点超时本轮未复现，不宣称已修复间歇性激活问题。

### 正式 App 系统侧栏开关验证

`scripts/validation/NativeSidebarChecks.swift` 检查真正 WindowGroup 中系统提供的侧栏按钮。
需手动授权执行宿主辅助功能，并提前打开指定版本的 NewPi 普通会话、展开侧栏；不自动启动/退出应用，不请求权限，不截图。

- 编译：`swiftc -parse-as-library scripts/validation/NativeSidebarChecks.swift -o /private/tmp/newpi-native-sidebar-checks`
- 只读定位：`/private/tmp/newpi-native-sidebar-checks "$PWD/build/derived/Build/Products/Debug/NewPi.app" inspect`
- 往返验收：`/private/tmp/newpi-native-sidebar-checks "$PWD/build/derived/Build/Products/Debug/NewPi.app" check`

检查无旧自定义标识、仅一个系统开关，AXPress 收起/展开后恢复输入区布局与 AX 身份，现有文本保持。
只识别 toolbar 内公开标识/英文或中文侧栏描述，未能唯一定位则失败，不猜坐标点击。
不写草稿、调用模型或遍历 Web 正文；不验证动画帧率和 VoiceOver。系统收展可能正常更新窗口或滚动状态。
源码保持在工作区内，临时目录只存编译产物，避免工作区外源码编辑授权。

同一可执行文件新增两个显式模式（替换上述最后的 `check` 参数）：
- `composer-inspect`：只读检查输入和菜单的 AX 属性，不打印草稿内容；属性未暴露时标为 `unavailable`，不误当作禁用。
- `composer`：**会临时编辑输入框**。要求唯一输入框、空输入、发送禁用、当前会话未运行且侧栏展开；已有草稿/附件则中止。
	经 AX 定位焦点后，仅向目标 App PID 投递键盘事件，输入固定文本；验证非空草稿经侧栏往返保持，
	模型菜单及用量弹窗经 Escape 关闭后恢复焦点并可续写。不按 Return、不点击发送、不选模型、不使用剪贴板。
	完成后仅清除与本次测试文本精确匹配的草稿；若检测到外部改动或 App 失去前台则报错，不覆盖用户输入。
	测试结束核验空输入与发送禁用；原有撤销历史不清除，因此 undo 栈可能包含测试编辑。
	运行期间请勿同时操作目标窗口；不代表真实输入法候选确认、跨会话草稿、模型切换或全部键盘路线通过。

## 共用审批 UI 验证

`bash scripts/validation/check-approval-ui.sh` 编译真实 `NewPiApprovalContent`，通过独立 Accessibility 进程操作按钮/菜单并验证回调范围：

- 聊天室普通风险有“本聊天室内允许”，没有永久授权选项。
- 高风险无记忆授权菜单，只允许一次。
- Session 保留“一直允许”选项。

需要 macOS 图形登录和辅助功能权限。使用 `NEWPI_UI_DARK=1` 验证深色模式；可设置 `NEWPI_UI_SNAPSHOTS=/private/tmp/newpi-approval-ui` 保存原生窗口截图。
探针仅验证 UI 回调，不执行命令、不写授权；临时进程退出后清理。Core 的 `ChatRoomAuthorizationTests` 覆盖真正的授权记忆、隔离、撤销、取消、兼容工具与多角色引擎链路。

## 输出刷新期间输入草稿保护

### 导航重建与草稿归属

`bash scripts/validation/check-draft-navigation.sh` 提取生产草稿声明、初始化、绑定及 Session 提交守卫，
用真实运行时/控制器和 NSTextView 验证强制重建后的 Session/Room 草稿隔离、图片保留、接受/拒绝发送与父级零通知。
ViewModel 发送后端和 transcript 渲染是测试替身；不等于正式 App 导航、模型发送或图片采集验收。
Session 不启动事件循环，聊天室用临时存储及空角色配置，不访问用户会话、不调用模型；需要 macOS 图形会话，不请求 AX 权限。

`NEWPI_DRAFT_REVISION=61259c1 bash scripts/validation/check-draft-navigation.sh` 在临时目录提取旧版生产声明，
会在 Room A→B→A 保留断言失败；不切分支、不覆盖工作区。仅用于相容版本的失败对照，非任意版本完整构建。
生命周期边界见[修复记录](../docs/dev-notes/2026-09-12-navigation-draft-lifetime.md)。

### 流式刷新与输入法组词

`NEWPI_EXPECT_DRAFT_FIX=1 bash scripts/validation/check-composer-streaming.sh` 用真实 SwiftUI `@State`、共用输入框和 AppKit NSTextInputClient 组词 API 模拟持续输出时的输入。
覆盖普通文本/选区、未提交的中文拼音组词、空草稿多次组词、确认后发送、外部清空/恢复、同一事件循环内输入后立即发送及固定四行内部滚动。
不调用模型、不改系统输入法或剪贴板。

`NEWPI_COMPOSER_REVISION=dee1ff8 bash scripts/validation/check-composer-streaming.sh` 可复现旧代码的 `composition-preserved=false`；只在临时编译目录提取旧组件，不切换当前分支。
