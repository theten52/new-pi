# A 原型与生产差距复核（2026-09-12）

## 结论与核验方法

**A 的阅读面、输入区和导航外壳已实施，不等于 A 原型全部实现。** 此前对话中
“全部完成”的表述不准确；下面的功能缺口不能用“原型是假数据”或“本批范围之外”消除。

基线：`04704d5`。恢复仓库白名单预览服务后，实际打开 `http://127.0.0.1:8765/`，
逐项切换 complete / running / approval / room / error / empty，检查可见状态与按钮，
实际打开改动弹窗、点击模拟重试并观察恢复态；再与生产源码交叉对照。
页面内容提取未能解析首页，浏览器实际导航成功；JS/CSS 可获取。
没有发起模型请求、审批真实工具或读取用户会话内容；这不是生产六场景实机全流程验收。

## 六场景矩阵

| 场景 | 已有生产能力 | 缺口 / 不一致 |
|---|---|---|
| 完成 · 长回答 | 单文档 Markdown、代码/表格/引用、流式收尾、思考/工具/详情折叠、回答及代码复制 | **未实现**顶部改动数量、回答的查看改动、逐文件逐行 diff；没有真实文件/检查结果汇总条。过程详情并非原型的步骤数/耗时摘要。 |
| 执行中 | 实时正文/思考/工具状态、显式停止、下一条草稿保留、运行中禁用模型切换 | **部分实现**状态呈现：没有通用任务步骤进度、完成/停止后的任务摘要；部分状态词仍是英文。不能用虚构的“2/3 步”补齐。 |
| 等待审批 | 真实风险/工具摘要、拒绝、允许一次、范围授权和聊天室上下文 | **设计偏差未解决**：生产是模态 sheet，不是内联卡；sheet 会阻挡底层 composer，不能像原型等待时继续编辑。**未实现**审批关联 diff。已有审批逻辑不需要重做。 |
| 多模型协作 | 独立目录、角色条、实际发言标记、手动推进/指定角色，以及真实讨论/投票/执行/评审/完成阶段 | **部分实现视觉**：SF Symbol 横向角色条不同于头像堆叠；正文无原型头像、模型徽章、消息时间。真实阶段能力比演示丰富，但不证明这些视觉细节已还原。 |
| 连接失败 | 错误文本、原轮次固定、错误及部分输出跨重启保存 | **未实现**专门失败卡、友好恢复说明、结构化详情、真实重试按钮、重试中/恢复状态。普通会话结束后回到 `NewPi is ready`，没有保留失败状态。 |
| 新会话 | 项目是否就绪的基础空态、真实新建入口、输入守卫 | **未实现**三条建议按钮及仅填入草稿的行为；标题与布局不同。快捷键原型 ⌘N，生产 ⇧⌘N，需明确是否保留差异。 |

### 跨场景缺口

- 正文日期分隔线、消息时间、用户头像/用户名行未接入。侧栏的会话日期不等于正文消息时间。
- 助手/聊天室角色名已显示，但不是完整头像 + 角色/模型 + 时间的消息头。
- 顶部导出/更多菜单不能当作原型“改动”入口的替代交付。
- 回答复制与代码复制均已存在；原型回答下方常驻按钮与生产悬停操作的布局不同。
- 已有设置中的跟随系统/浅色/深色、原生缩放窗口、系统侧栏开关、模型/思考菜单、真实可空用量、
  图片附件、回到最新与 rail，不重复列为“待补功能”。

### 两个易混淆的边界

1. **保稿不等于失败回填输入框**：发送前校验拒绝会保留草稿；发送已接受后 composer 清空，
   后续 provider 连接失败时原提问保存在 transcript，下一条草稿独立保留。没有真实重试/回填流程。
2. 原型的固定数字、示意 diff、演示任务、1.2 秒模拟恢复、A/B 选择器、场景/宽度/重置控件和假窗口装饰
   不应直接进入生产。但它们演示的**真实 diff、重试、空态建议、消息元数据等能力仍是未交付设计项**。

## 源码证据入口

| 入口 | 对照依据 |
|---|---|
| `docs/design/ui-prototype/prototype.js` | `scenes`、`fixture`、`approval`、`process`、`showChanges`、`retry`、`data-prompt` |
| `NewPiApp/NewPiApp.swift` | root header 的导出/更多、`NewPiToolApprovalSheet` 的 `.sheet`、聊天室阶段操作 |
| `NewPiApp/NewPiViewModel.swift` | `agentStatusPresentation`：审批/运行分支，空闲统一 ready；错误持久化与状态 UI 是不同路径 |
| `NewPiApp/NewPiMarkdownText.swift` | `NewPiChatEmptyStateView` 仅基础引导，无建议按钮 |
| `NewPiApp/MarkdownRenderer/transcript-document.js` | `ti-error` 文本条目、user body、assistant `speaker`、消息复制/Fork；没有 retry/diff action |
| `NewPiApp/MarkdownRenderer/markdown-renderer.js` | `attachCopyHandler` / `.code-block-copy` 已实现代码复制 |
| `NewPiApp/NewPiAgentStatusView.swift` | 共用外壳/角色条/模型菜单/状态与用量 popover |
| `NewPiApp/NewPiAppearanceMode.swift`、`NewPiSettingsView.swift` | 三种外观模式持久化及设置入口已有实现 |

## 后续交付次序建议（尚未实施）

1. 错误卡与真实失败恢复：先定义可重试范围、原轮次关联、重复提交防护及新草稿隔离，再接入 UI。
2. 真实改动/diff：明确本轮修改与用户原有修改的区分、文件范围和恢复边界；不能伪造文件/测试数。
3. 空态建议：只填草稿、不自动发起任务，不覆盖已有输入。
4. 消息元数据、状态词与有真实数据依据的过程/结果摘要。
5. 审批内联与模态差异：明确设计决策及交互验收，保留既有授权安全边界；不擅自宣布偏差已获接受。

## 附：已发送图片预览比例修复

> **后续纠正**：下方 11 组测试与首个修复包是历史记录，未解决用户原图。实际原图复现和第二次修复见本节末尾；首包不得继续标为此问题已解决。

用户新反馈覆盖了之前“附件操作正常”的笼统验收：之前附件处理测试**没有测试预览比例**。

- 旧预览使用 `NSImage(contentsOf:).size`；它受打印 DPI 影响。合成 320×160 图片在
  DPI 72×36 时逻辑尺寸为 320×320，真实窗口截图红色区域也为 **1:1**，应为 **2:1**。
- 修复 `AttachmentPreviewWindow.swift`：ImageIO 按像素解码并应用 EXIF 方向，建立像素尺寸的
  NSImage；明确图片、标题和窗口空间，整个窗口按可视区 70% 预算适配。受控路径解析不变，附件文件不改写。
- 新入口：在仓库根目录执行 `bash scripts/validation/check-attachment-preview.sh`。
  需要 macOS 图形会话与执行宿主的录屏权限，仅截图探针自己的合成图片窗口，不抓桌面/用户窗口。
  路径解析用临时目录替身，其余控制器/SwiftUI 视图直接编译生产源码；不会读用户附件。
- `NEWPI_PREVIEW_REVISION=04704d5` 可对照旧控制器。失败时可用 `NEWPI_PREVIEW_CAPTURE` 指定保存合成图截图的位置。
- 修复后 **11 组**真实 PNG/JPEG/TIFF、非等比 DPI、横竖/极端比例/小图/大图、EXIF 6/8 的
  渲染比例、屏幕预算、附件字节不变及程序关闭窗口检查通过。附件处理原有测试及完整 Debug build 通过。
- 日志：`/private/tmp/newpi-ui/preview-aspect-before.log`、`preview-aspect-expanded.log`、`preview-debug-build.log`。
- 探针调试中 `cacheDisplay` 未捕获 SwiftUI 合成图层，改为单窗口系统截图；ICC 转换后使用颜色通道优势判断，
  不用过严固定绿通道阈值。旧实现正常 DPI 通过、非等比 DPI 失败，新实现两者均通过。
- **未确认用户原图是否为同一原因**；需使用修复构建重新预览那张图片。未覆盖全量格式、动画播放、
  EXIF 镜像方向的角点位置、真实 WebView 点击路由、Escape/背景点击关闭及所有屏幕组合。

### 首次修复包（未解决用户原图，历史）

- Release 构建及独立 `codesign --verify --deep --strict` 通过，`dist/NewPi.app` 已更新；未退出/重启用户 App。
- 替换前备份：`dist-backup/NewPi-before-preview-aspect-20260912-204359.app`。
- dist 与 Release 构建主二进制 SHA-256 一致：
  `dc81234a0d45b64a746cb91110a687903a5a3e38d84ff994f8bffa0f5eadae2b`。
- 打包日志：`/private/tmp/newpi-ui/preview-release-package.log`；旧提交失败对照：`preview-aspect-old-head.log`。
- 本次没有修改 Core、重跑 Core 全套测试或提交/推送 Git；用户学习目录与 `docs/README.md` 本地改动未纳入。

### 第二次复验：原图的缺省方向与 DPI（20:50 起）

用户再次报告比例错误，并保持图片窗口打开。仅截取该 NewPi 浮动预览窗口、按精确展示文件名定位对应附件元数据，未输出会话正文或凭据。
当前进程是用户 Xcode 的 DerivedData Debug 构建，但已有首轮修复布局；**不是简单的旧版本误用**。

- 用户原图像素 **1244×1230**，DPI **72×144**，**没有 Orientation 字段**。对应历史副本元数据一致；原始像素没有被本次预览修改。
- `NSImage.size` 为 1244×615；首轮改用 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform`，
  在缺省方向时仍会按 DPI 重采样为 1244×615。因此首轮方案仍拉宽，而非预处理已把文件永久压扁。
- 漏测原因不只有 DPI 高低方向：合成图片始终写入显式 `Orientation=1`，ImageIO 在这条路径不复现。
  补齐尺寸、DPI 后仍通过；再省略 Orientation 才精准失败。字段缺省与显式默认值不能当作等价样本。
- 首轮方案在新合成回归下：窗口 1210×645pt，图片截图 2340×1156px，比例 **2.0242**，期望 **1.01138**，非零退出。
- 第二次修复：`CGImageSourceCreateImageAtIndex` 直接解码原始像素；仅在 EXIF 2–8 时通过
  `CIImage(cgImage:).oriented(forExifOrientation:)` 应用旋转/镜像。完全移除 thumbnail transform，不把打印 DPI 变成屏幕比例。
- **26 组**真实窗口回归通过，包含字段缺省/显式1、DPI 72×36/72×144、PNG/JPEG/TIFF、EXIF 1–8、大小图与极端比例。
  原场景参数截图为 1322×1308px，比例 **1.01070**（整像素舍入），窗口 702×720pt；屏幕预算与附件字节不变通过。
- 显式单文件验收入口：`bash scripts/validation/check-attachment-preview.sh <原图路径> <临时截图路径>`。
  它只读指定原图，复制到探针临时目录，由生产控制器显示；不写原附件，截图仅该测试窗口。默认无参数模式仍不读用户文件。
- 已用同一张真实附件进行该验收并查看截图，确认恢复接近正方形，源附件字节不变。
  用户随后于 2026-09-12 明确反馈「图片可以了，good。」，本次原图预览比例验收通过。
  本机截图不进入 Git，不用用户图片替代可重跑的合成 fixture；其他格式与方向的未覆盖边界保留。
- 日志：`/private/tmp/newpi-ui/preview-dpi144-missing-orientation-before.log`、`preview-dpi144-after.log`、`preview-original-inspect.log`。
  真实原图截图：`user-preview-aspect.png` / `user-preview-aspect-fixed.png`，仅留在本机临时目录。
- 未修改 `ImageAttachmentProcessor`、会话文件或 Core。EXIF 镜像的角点位置、动画与全量格式、全屏幕组合仍不在比例测试保证内。

第二次交付：Debug/Release 构建、独立严格签名及 `git diff --check` 通过。`dist/NewPi.app` 已更新，
与 Release 主二进制 SHA-256 同为 `8e26bc7cede5d374c07042abeab906a94865dfcc9e11b92df84329fa19b39206`；
替换前备份 `dist-backup/NewPi-before-preview-dpi144-20260912-205849.app`。
日志 `preview-dpi144-debug.log` / `preview-dpi144-release.log` 位于上述本机临时目录。
未重启用户 App，也未修改用户 Xcode 自有 DerivedData；用户可在 Xcode 重新构建运行，或退出后打开本次 dist 包。