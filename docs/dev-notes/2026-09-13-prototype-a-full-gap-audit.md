# 原型 A 全项差异审计（2026-09-13）

## 最新范围变更：删除差异查看能力

用户明确要求移除顶部「改动」、回答底部「查看改动」、审批「查看差异」，包括专用功能及测试代码。对应 Git 读取器/面板、正文差异弹窗、审批预览链路及其测试已删除；用量弹窗、审批与回执、工具执行、复制、统计及已有编辑记录继续保留。下文 A-06/A-09 的差异按钮部分、V-06/V-07 及 Git UI 待验收项目已被此决定撤销，不再作为遗漏或待恢复功能。旧记录格式、快照捕获和正文渲染自身的增量 diff 不属于此次删除范围。

## 后续实施检查点（本轮提交范围）

> 下方审计表保留 abbe77b 时的历史事实；本节记录后续代码接入，不代表整款 App 已验收。**当前仍有阻塞，不得称“全部完成”。**

### 提交前更新：输出圆环与最新构建

- 用户反馈输出时圆环不转，已将静态圆环改为独立 `CAShapeLayer` 旋转，每秒一圈，不逐帧发布 SwiftUI 状态；非活跃场景/减少动态效果时停止旋转，审批/结束切回圆点，卸载移除动画。
- `StatusSpinnerChecks.swift` 独立图层生命周期测试通过，覆盖旋转参数、连续更新不重启、停止/恢复、卸载；不显示窗口、不申请系统权限。
- `/private/tmp/newpi-ui/status-spinner-build.log` 已确认 **BUILD SUCCEEDED**（07:37），覆盖当前 Git 长行修正和圆环改动；取代下文“最新构建未知”的历史状态。
- Git 弹窗最终回归结果仍未确认，不沿用构建成功宣称 UI 全绿。下文其他剩余功能及实机验收边界保持不变。
- 本轮按用户要求提交代码、测试与审计记录，不打包、不推送；学习资料与 `docs/README.md` 独立改动不纳入。

| 清单 | 当前实施状态 |
|---|---|
| A-01–04 | 已接入分组/工具 SVG 状态、右侧折叠箭头、两行工具说明、逐条真实耗时。运行/展开工具用自然布局，保留32px尾距。 |
| A-05 | 已接入停止工具展示、已知调用计数，以及 `update_plan` 自报计划 X/Y。计划明确标注 Agent 自报，不当执行证明；历史没有计划不补造。 |
| A-06–07 | 已接入底部轻按钮图标与原生剪贴板结果确认反馈，保留旧复制桥接兼容。 |
| A-08 | 操作行移到图标化结果条之前；新增 `read_test_report` 读取项目内有界 JUnit，报告通过/失败/跳过及路径，随工具结果持久化/冷恢复/发言隔离。**任意“未修改某机制”的保护范围保证仍无可靠证明来源，未实现自动结论。** |
| A-09–11 | 正文审批风险徽章/盾牌/允许一次强调、原生领取确认回执、错误/重试图标已接入。回执只表示UI运行实例领取决策，不表示工具执行成功；仅当前文档内存，重新创建文档不保留。 |
| A-12–15 | 已接入输入框焦点边框、可见键盘提示、建议焦点token、附件文件名。 |
| A-16–17 | 已加载runtime行显示状态、相对时间及现有编辑记录去重路径数。**未加载历史仍显示未知，未新增全历史扫描；零记录不冒充全量零改动。** |
| A-18 | 已接入具名下一角色和真实推进操作，但为紧邻正文下方的**原生固定尾行**，尚非截图中随正文滚动的DOM行。 |
| A-19 | 显式阶段线已接入；**消息没有历史轮次字段，未补历史轮次数值**。 |
| A-20 | 无runtime时显示独立草稿输入框；仅显式发送才建Session，代次/项目身份守卫、修改期间保稿、附件交接已接入。 |
| V-01–05 | n/角色首字、气泡边框、正文标题/行高、表格/引用、代码色板与中文常显复制已接入。 |
| V-06–07 | Git改为窗口内居中模糊层、数字徽章及文件卡片；文档差异弹窗只改展示为模糊背景与顶部关闭，不改快照能力。**Git UI回归仍阻塞，见下。** |
| V-08–10 | 空态品牌/项目眉题、角色首字叠放/人数、⌘N、日期上下文已接入。 |
| V-11–12 | 中性发送禁用态、模型图标、静态点/环、系统分栏窄宽策略已接入。保留系统侧栏按钮；运行指示不加持续动画。完整系统分栏实机验收待完成。 |
| 上下文风险 | 普通Session超过80%显示真实输入/窗口警告；已有聊天室预算横幅保留。 |

### 已取得的验证结果

- `audit-core-full.log`：串行 **405 tests / 99 suites PASS**（含用户Labs，不是tracked-only结果）。
- `audit-full-build.log`：Debug build通过；之后Git长行布局有修正，**最终最新构建尚无可靠结果**。
- `audit-dom-fix.log`：**274元数据断言、60几何检查、8组浅深/宽窄样式**通过，保留32px尾距与Markdown增量语义。
- `audit-cold-final.log`：默认 `-O` Coordinator/Core/WK端到端与500历史恢复最终通过，5场景锚点误差均0；此前失败记录保留，不覆盖成从未失败。
- `audit-native.log`及后续修复结果：原生焦点/居中层/创建代次探针通过；输入框流式与38项历史检查通过。
- `audit-git-ui-recheck.log`：最新有完整汇总的一轮为 **689 PASS / 1 FAIL**，失败为双窗口宿主按钮基线点击，发生在打开overlay前。长行宽度已修复，原测试滚轮事件路由也已修正。
- 随后将测试鼠标统一为App队列顺序派发，`audit-git-ui-latest.log`有运行记录，但没有完整汇总/退出码。终端多次回传为空且无可查询执行ID，不盲目重启任务。
- 最终证据 `/private/tmp/newpi-ui/audit-final-proof.txt`：**UI=UNKNOWN，DEBUG_BUILD=UNKNOWN，BLOCKED**。前一轮689/1不能替代最终结果，也不能算全绿。

### 保持不变与剩余事项

- 快照捕获/覆盖/回滚继续冻结；不改系统权限或审批设置，不启动正式App、不录屏、不发全局键盘事件、不请求真实模型。
- 尚未完成：上述保护范围证明、未加载历史的完整摘要、聊天室随文具名尾行和历史轮次、Git双窗口回归最终确认、最新构建确认、整款App逐像素/真实IME/VoiceOver验收。
- 本轮新增计划/报告工具遵守现有工具策略与审批链，不为减少审批绕过权限。
- 未提交、未打包、未推送。后续从阻塞验证与明确剩余项继续，不能再按旧审计表重复建设已接入部分。

## 范围与方法

- 用户要求立即核查 `http://127.0.0.1:8765/`，不是继续实施。
- 对照基线：生产提交 `abbe77b`；原型 `docs/design/ui-prototype/index.html`、`prototype.js`、`prototype.css`。
- 已获取页面及所引用的本地资源；独立浏览器实际切换 complete / running / approval / room / error / empty 六场景，打开用量和改动弹窗，操作允许、拒绝、停止、重试、下一角色、建议填稿、附件添加/移除、窄窗口和浅深外观。
- 已查看原型截图：`/private/tmp/newpi-ui/prototype-a-audit-dark.png`、`prototype-a-audit-narrow.png`。浏览器任务已关闭。
- 生产侧是源码交叉核验，不是本次启动正式 App 的同内容逐像素对照；不能据此保证全部实机行为或视觉已验收。本次不运行新模型请求，不修改功能、快照、权限或用户数据。
- **底层功能存在、展示接入、交互完整、视觉验收是四件不同的事。** 以下状态不把演示数字当真实需求，也不以“演示”排除同类真实体验的缺口。

## 一、确定未实现或接入不完整

| ID | 原型要求 | 当前实际实现及缺口 | 生产源码依据 |
|---|---|---|---|
| A-01 | 过程总状态图标：完成勾 / 执行 / 停止 | 分组只有折叠箭头和计数文字，没有独立总状态图标；右侧折叠箭头也仍放在左边 | `transcript-document.js` `renderDetailGroup`、`syncBatchDecorations` |
| A-02 | 每步左侧完成勾 / 执行 / 停止图标 | 工具卡使用圆点＋“已完成/进行中/失败”，没有原型逐步状态图标 | `renderCard`；`transcript-document.css` `.card-badge::before` |
| A-03 | 步骤标题＋第二行文件/命令/说明 | 目前是工具名＋同一行结果首行预览，命令要展开；未实现语义标题和上下两行结构 | `renderCard` `.card-title` / `.card-preview` / `.card-cmd` |
| A-04 | 每步右侧耗时 | `durationSeconds` 已传入，但仅参与最终回答底部合计，单条工具卡未展示 | `upsert`、`syncAnswerFooters`、`renderCard` |
| A-05 | 执行中“已完成 2/3”及停止后“保留已完成步骤” | 只有 done/running/failed 工具计数；没有计划总步骤模型，也没有分组/单步骤专门的 stopped 呈现。全局停止状态已存在，不等于步骤区已实现 | `syncBatchDecorations`；`NewPiViewModel.swift` `turnSummaryText`、`NewPiToolState` |
| A-06 | 回答底部“复制回答 / 查看改动”图标与轻按钮 | 行为已接入，但均为纯文字带边框按钮，缺 copy/diff 图标 | `syncAnswerFooters`；`.answer-footer button` |
| A-07 | 复制回答后的可见反馈 | footer 仅发 `copyText`，原生仅写 NSPasteboard，未显示成功/失败或按钮反馈。代码块的勾选反馈已存在，不能拿来代替 footer | `syncAnswerFooters`；`NewPiTranscriptDocumentView.swift` `case "copyText"` |
| A-08 | 回答后操作行，再接图标化结果条 | 当前结果文字在按钮之前，未分成文件/检查/保护范围的图标化指标。已有工具统计与有限文件编辑记录；真实逐测试通过数、保护范围结论尚未结构化 | `syncAnswerFooters` 创建顺序；`.result-strip` |
| A-09 | 审批盾牌标题＋风险徽章＋突出“允许一次” | 正文审批真实接线已实现，但标题无盾牌、风险为普通段落、允许/拒绝/预览统一中性样式；缺主次层级 | `applyApproval`；`.approval-title` / `.approval-risk` / `.approval-action` |
| A-10 | 审批后原位保留允许/拒绝及授权范围结果 | 当前领取后先禁用按钮，随后清除待审批条目，不留下原型那种审批结果条。工具执行结果/审计日志不等于这个用户可见回执 | `applyApproval` 的 claimed 与清除路径；Coordinator 独立审批状态 |
| A-11 | 错误卡警告图标及重试图标 | Session 安全重试和错误持久化已实现，但正文错误标题与重试按钮均缺图标；不是“重试功能未实现” | `renderError` |
| A-12 | 输入框获焦点时整个外框强调＋柔和外圈 | 共用 composer 外框为静态颜色，没有根据输入焦点改变边框和外圈 | `NewPiAgentStatusView.swift` `NewPiComposerSurface` |
| A-13 | 普通会话可见的发送/换行提示和运行中草稿提示 | Session 仅 `.help` 与运行中 placeholder，没有原型工具行提示；聊天室已有可见发送/插话提示，不重复列为无实现 | `NewPiChatView.swift` `chatComposer`；`NewPiApp.swift` `inputBar` |
| A-14 | 点击建议后马上可以继续键入 | 三建议及保护现有草稿已实现，但仅填值，没有显式将焦点交给 NSTextView。原型实际观测 activeElement 为 message-input | `fillSuggestedDraft`、`fillSuggestion`；`NewPiComposerTextView` |
| A-15 | 附件条显示文件名 | 真实图片采集/缩略图/移除已实现，当前草稿条未展示 `displayName`，只有缩略图；无需照搬“演示附件”文字 | `NewPiChatView.swift` `NewPiDraftAttachmentStrip` |
| A-16 | 侧栏显示会话运行中/停止/完成 | Session 行只吃 `summary` 与是否选中，图标固定 bubble.left，没有运行状态摘要或执行态图标 | `NewPiApp.swift` `SessionRow` |
| A-17 | 侧栏相对时间＋文件数摘要 | 当前为创建时间（绝对日期）与消息数，无“刚刚/今天/昨天＋文件数”。文件数应先定义统计口径，不得用工作区文件数冒充本轮贡献 | `SessionRow`、`SessionSummary.workbenchTitle` |
| A-18 | 聊天室具名“下一位 · 评审员 / 让评审员发言” | 已有“推进下一发言”“指定角色”真实操作，但无正文尾部具名下一发言行，当前空闲状态也只写“聊天室就绪” | `NewPiApp.swift` `speakerActions`、`chatroomStatusPresentation`；room adapter |
| A-19 | 聊天室正文阶段横线＋轮次 | 已按消息 phase 插入普通 `.system` 文本“—— 某阶段 ——”，未按原型阶段线排版；讨论轮数没有数据，不能补假“第1轮” | `NewPiChatRoomTranscriptAdapter.swift` `snapshot`；`renderSystemLike` |
| A-20 | 新会话空态仍能直接在底部输入 | 已有空 Session 有 composer；尚无 runtime 时只显示空态，需要新建或点建议才出现 composer，与原型始终保留输入区不同 | `NewPiChatView.swift` `keptAliveRuntimes.isEmpty` 分支 |

### 数据/设计原则边界（不是原型按钮遗漏）

- 普通 Session 的上下文占用目前是用量弹窗中的文字，没有“接近上限则提升为可见警告”的 UI 通道。该原则写在原型用量弹窗说明中，但原型本身也没有高占用场景；聊天室已有 80% 预算横幅，不能说全 App 都没告警。依据：`contextUsageText`、`NewPiUsageDialogData` 与 `contextBudgetWarning`。
- 原型固定的步骤、检查数、文件数不能直接复制；计划步骤、测试结果结构化确实未完成，工具成功数不是测试通过数。
- 文件编辑快照按用户要求暂停修改，现有限覆盖只记录事实，不安排扩展或回滚。顶部工作区 Git diff 与回答已记录编辑不是同一口径。

## 二、已实现功能，但没有按原型还原的视觉/交互差异

以下不自动视为需重做，也不把未获用户确认的偏差擅称为“刻意设计”。

| ID | 差异 | 当前源码依据 |
|---|---|---|
| V-01 | NewPi 头像原型为 n，角色为首字；生产 assistant/room 正文均用 ✦，背景/尺寸/边框也不同 | `syncMetadata`；`.assistant-avatar::before`、`.message-avatar` |
| V-02 | 用户气泡缺原型细边框，圆角与 padding 不同；消息间距、署名间距不一致 | `.ti-user .bubble`、`.ti`、`.message-hd` |
| V-03 | 正文行高 1.75（原型1.85），h2 1.2em（原型20px）、h3 1.1em（原型14px）；标题分隔线/段落边距仍受旧 GitHub 样式影响 | `markdown-renderer.css`；`transcript-document.css`；`github-markdown-light.css` |
| V-04 | 引用是3px中性竖线，原型2px强调色；表格为全网格/隔行底色，原型轻水平分隔；代码高亮仍为GitHub式配色 | `markdown-renderer.css`；`transcript-document.css` 的表格、blockquote、hljs 规则 |
| V-05 | 代码块语言栏与复制已存在，但按钮为英文 Copy 且 hover/focus 才显示，原型中文复制常显；头部内边距/代码行高不同 | `markdown-renderer.js` `enhanceCodeBlocks`、`attachCopyHandler`；`.code-block-copy` |
| V-06 | 顶部“改动”已有真实数量，但图标是分支符号，数字无原型徽章底；使用原生 sheet/文件列表＋diff，不是原型居中多文件卡片弹窗 | `NewPiChangesView.swift` `NewPiChangesButton`、`NewPiChangesPanelContent` |
| V-07 | 正文中的差异 dialog 有居中/限高/Escape，但只有背景 dim，没有原型 backdrop blur；关闭按钮在普通文档流中，缺顶部右侧固定标题/关闭布局 | `showChanges`；`.changes-dialog`、`.changes-dialog::backdrop` |
| V-08 | 空态缺 n· 品牌块和 NEW SESSION / 项目眉题，说明文案与大小/间距不同；三建议本身已存在 | `NewPiMarkdownText.swift` `NewPiChatEmptyStateView` |
| V-09 | 房间顶部是角色图标/名字横排与发言标识，不是重叠首字头像＋角色数＋手动推进文字 | `NewPiWorkbenchRoleStrip`、`roleBar` |
| V-10 | 新会话快捷键为 ⌘⇧N，原型为 ⌘N；日期线只有今日/昨日，不带项目/多模型协作上下文 | `NewPiApp.swift` commands；`syncBatchDecorations` |
| V-11 | 模型菜单是 cpu＋思考图标，原型 sparkle；发送禁用态是按钮透明度降低，原型中性底；状态栏用静态语义图标而不是点/旋转圆环 | `NewPiModelPickerMenu`、`NewPiComposerPrimaryAction`、`NewPiAgentStatusIcon` |
| V-12 | 原型800px窄窗侧栏188px，生产侧栏最小226px；原型≤700px自动隐藏侧栏/压缩辅助信息，生产走系统分栏与布局优先级，无相同断点规则 | `NewPiWorkbenchShell`、`NewPiWorkbenchHeader`、`NewPiAgentStatusBar` |

V-07 仅记录展示差异，不授权修改已暂停的快照功能。V-12 是适配策略差异，不凭源码断言某尺寸一定溢出。

## 三、明确已接入，不应再次列成“未实现”

| 范围 | 已有能力 | 仍需区分 |
|---|---|---|
| 外壳 | A 的中性阅读面、共用输入区、项目卡、会话/聊天室列表、标题与实际目录 | 不是逐像素一致；系统侧栏按钮/动画是用户明确选择，不再重写 |
| 建会话/草稿 | 手动新建、会话内草稿保活、建议只填空稿、方向键取回历史 | 不宣称退出/LRU/切项目后的草稿永久保存 |
| 输入 | Return发送、Shift+Return换行、运行中草稿编辑、显式Stop、模型/思考菜单、图片选择/粘贴/拖拽/移除/预览 | room运行中Return插话是既有业务行为，不按普通Session覆盖 |
| 用量 | 前置柱状图标、居中窗口内模糊弹窗、真实四卡片、关闭/背景/Escape | 图标已在abbe77b补齐；未知数据保持未知，原生blur不称CSS逐像素相同 |
| 改动 | 顶部真实Git文件数、staged/unstaged diff、untracked预览、只读边界、加载/失败/非Git状态 | 不是本轮Agent独占改动；已有计数不能重复列缺口 |
| 正文 | 真正日期/时间、身份/模型元数据、Markdown/代码高亮/表格横滚、代码复制、最终回答复制/查看改动 | 普通Session没有协议徽章，room有实际模型；旧历史无数据不造值 |
| 过程 | 详情分组折叠、工具命令/结果、成功/失败/运行计数、已记录总耗时 | 不能当作A-01至A-05已完成 |
| 审批/错误 | Session/room真正随文审批、受限只读预览、范围守卫；Session最新安全错误重试、保留历史/中断输出 | 旧原生审批sheet有图标不代表当前DOM有；room重试不在原型场景且未实现 |
| 聊天室 | 阶段切换消息、实际角色/模型/发言态、手动推进与指定角色、插话/停止 | A-18/A-19是具体展示缺口，不说协作功能不存在 |
| 阅读 | 回到最新、滚动锚点恢复、rail、单文档渲染 | 不更改现有滚动架构；恢复体验仍需实机复核 |

## 四、不移植的演示控件与待验证事项

- 不移植：A/B切换、场景选择、重置场景、模拟完成/重试计时器、设计说明、演示免责声明、网页标题/页脚和假交通灯。这些是原型控制台，不是生产功能缺口。
- 正式App的浅深/高对比/窄窗像素、VoiceOver、真实IME候选窗及焦点路径，本次未重新实测；不得将“源码未见显式焦点交接”扩大成所有机器必现失焦。
- 代码块复制已有原位勾选反馈，footer复制没有；审批结果是用户可见回执缺失，不是审批失效；总/逐步图标缺失不是工具未执行。
- 本次只新增本审计文件，未改生产功能、未打包、未提交。

## 收尾标准

后续按本清单ID逐项记录：源码实现 → 状态覆盖 → 原型同内容对照 → 用户验收。不能只依据编译、DOM存在、成功计数或旧组件测试把整项标为完成；新增/保留差异需明确理由，不用“原生化”替用户确认。