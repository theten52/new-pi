# NewPi Development TODOs

当前待办与已完成项索引。2026-09-13 核对工作台最新代码与日志；`open` / `deferred` 表示仍需处理，
`待验收` 表示已有实现但未确认满足原始体验要求，`待复核` 不等于问题仍存在。
旧设计和审查证据保留在链接文档中，不能直接当作当前 backlog；分类入口见 [文档索引](README.md)。

## UI 后续 — 2026-09-12 A 文档工作台

### 当前原型剩余结论（2026-09-13，基线 e0de77a）

**剩余 4 类，对应旧清单 5 个部分完成项**，不是此前的 20 项功能缺口＋12 组视觉差异：

| 类别 | ID | 当前缺口 |
|---|---|---|
| 侧栏历史摘要 | A-16、A-17 | 已加载会话有状态/相对时间/编辑数；未加载历史缺完整状态和编辑摘要 |
| 聊天室下一位 | A-18 | 具名推进按钮已存在，但仍为原生固定尾行，未随正文滚动 |
| 聊天室历史轮次 | A-19 | 阶段线已存在，历史消息缺轮次字段，不能显示准确历史轮数 |
| 保护范围结论 | A-08 | 真实工具统计和JUnit报告已存在，尚不能自动证明“未修改某机制” |

- 不再计为缺失：已接入的步骤图标/耗时/计划、复制反馈、审批回执、焦点/附件/空态、主要排版与圆环旋转等；详细源码依据见[当前审计结论](dev-notes/2026-09-13-prototype-a-full-gap-audit.md#当前结论剩余-4-类涉及-5-个部分完成项)。
- 已撤销：三个 diff 查看入口及专用代码/测试、两条无快照/无报告空提示；不恢复已删除功能。计划和报告读取、实际统计与已有记录仍保留。
- **验证欠账独立记录**：完整实机视觉、真实IME、VoiceOver、导航/焦点验收尚未全部完成；不算新增功能缺口，也不据组件测试宣布全部验收。
- 生产实现与圆环修复已提交 `187b0fe`，diff移除和空提示清理已提交 `e0de77a`。本次仅更新文档；最后两条空提示的正文回归通过，冷恢复结果未确认。
- 本节是当前结论；下方旧六项/迁移/验证记录保留历史语境，不得用其中“未实现”“未提交”再次统计当前欠账。

### 2026-09-13 差异查看功能移除（用户决定）

- 删除顶部「改动」、回答底部「查看改动」、审批「查看差异」，包括 Git 读取器/面板、审批只读预览、正文差异弹窗及专用测试；不只是隐藏按钮。
- 保留审批/回执、工具执行、复制反馈、用量、步骤/测试报告统计和已有编辑记录；`ToolFileChange` 的持久化格式与捕获保持兼容，不删除或迁移用户历史。
- 结果条不再显示「本轮未记录文件编辑快照」；没有记录时省略该项，有实际编辑记录时仍保留数量统计。
- 结果条也不再显示「未提供测试报告」；无报告时省略报告区，有真实报告时继续展示通过/失败/跳过、来源和时效限制，不把无报告当作零失败。
- 下方及历史审计中的 diff 展示和预览描述被此决定取代，不再作为待恢复功能；原 Git UI 验收随能力删除撤销，不声称其历史失败已修复。
- **移除后验证**：Core 386 tests / 98 suites、DOM 319 断言、冷恢复5场景、原生焦点/创建回归和Debug构建通过。DOM的8组键盘可见性因页面无焦点跳过；用量最终704 PASS / 0 FAIL / 4截图SKIP（exit 2，无录屏）。此前用量输入保留失败未复现，HEAD对照另有焦点恢复失败，根因未定，不称所有实机交互均已验证。证据：`/private/tmp/newpi-ui/remove-diff-final-proof.txt`、`remove-diff-usage-proof.txt`。未提交、未打包。

### 2026-09-13 用户决定与交互修正（早期记录）

- **文件编辑快照暂停修改**：用户明确表示该功能之后可能移除；保持现状，不继续扩展捕获、差异或历史快照能力，也不自行删除已有记录。本轮复制去重未修改快照逻辑。
- **回答复制去重已实现**：有最终回答 footer 时顶部仅保留原有 Fork，底部保留「复制回答」；流式/中断/中间回答及摘要无 footer 时继续提供顶部复制，用户消息不变。状态切换与元数据更新不会重复或丢失复制入口。
- **设置 Escape 已实现**：独立 Settings 窗口原先没有取消关闭处理；现通过窗口 responder chain 正常关闭，五个 Provider/模板编辑取消按钮显式绑定 Escape。优先取消当前子 sheet/组合输入，不保存编辑弹窗草稿；主设置已即时应用的选项不回滚。没有全局键盘监听。
- **本轮验证**：复制 DOM 227 条断言及 cold 回归通过；Settings Escape 139 条真实事件合成检查通过；完整 Debug build 通过。真实 IME 候选窗、菜单 tracking、完整 Settings ViewModel 集成仍待人工确认。本轮未提交、未打包，`dist` 不含这次复制/设置修正。
- **六项当前结论**：失败恢复（Session 安全最新节点）、顶部只读 Git diff、三建议、真实消息元数据、随文审批均已接入；步骤/结果摘要仅完成工具执行统计，计划总步数/百分比/测试通过数未实现。Room 重试未实现；用量居中弹窗已接入，未知数据不补造。代码接入不等于整款 App 人工验收全部关闭。

### BACKLOG-WORKBENCH-PROTOTYPE-GAPS — 原型功能缺口

> 当前仅余上方4类/5项部分完成项。以下为早期接入与验证记录；尤其 Git diff/审批预览已撤销，计划与JUnit报告已后续接入，不能沿用旧段落当当前状态。

- **状态（09-13 后续）**：用量居中对话框、Session/room 随文审批及只读拟执行预览、回答底部复制/查看改动与真实结果条均已接入，**implemented / 待用户验收**；不再将固定审批位置列为未完成。改动捕获仍是部分覆盖，原型像素与整款 App 验收仍 open。当前依据见[弹窗、审批与结果记录](dev-notes/2026-09-13-workbench-dialogs-and-results.md)；[再次对照](dev-notes/2026-09-13-prototype-presentation-review.md)与[六项实施记录](dev-notes/2026-09-12-workbench-six-features.md)保留历史，不当作最新缺口表。
- **失败卡与重试**：仅普通 Session 的最新、已持久化且锚点/快照仍有效的 `available` 错误可显式领取；保存 `retrying/recovered/unavailable` 状态，不重复追加用户或执行历史工具。重试首个请求仅裁掉末尾 aborted/error assistant 的请求投影，磁盘原文保留；旧错误、取消、未完成工具不自动重试。VM 同步防双击、结束串行 await 后才解锁。原型 error 是 Session，**不宣称聊天室失败恢复已交付**。
- **真实改动**：Session/room header 共用 `NewPiChangesButton`，读取所选目录所属的整个 Git root，分别展示 staged/unstaged diff 与 untracked 文本预览；包含用户原有修改，只读、无撤销/回滚，不冒充本轮 Agent 独占。超时/输出有上限、链接安全与外部 hooks/filter 等禁用已接入。
- **空态三建议**：仅填空草稿，不发送、不覆盖文本（含纯空白）或图片；初始无 runtime 时仅显式点击创建 Session 并填稿，不请求模型。
- **用量对话框**：`NewPiUsagePresentation` 属于打开按钮实际窗口，居中圆角、最大 600pt；四卡片为最近一轮输入/输出、缓存命中率、上下文，另有累计/最近一轮/速率三摘要，缺数据不造值。父 content 顶层 `.withinWindow` 模糊与 dim、透明子面板；关闭/背景/Escape、焦点与 marked text 保留、AX 模态隔离已接入，后台生成不暂停。浅深合成截图已查看，原生 blur 不等于 CSS 3px，不称 pixel-perfect。
- **审批**：`NewPiTranscriptApproval` → Coordinator 独立待发态 → HTML `.ti-approval`，位于正文并同批保锚；父 Session/room 原生 dock 已移除。runtime/request/nonce、main-frame、可见性和当前回调守卫限制一次领取；高危仅 once，room 无 forever。`ToolChangePreview` 对 write/edit/write_file 提供根内、nofollow、64 KiB 有界只读预览，明确尚未执行、文件可能变化及不可用原因；等待时仍可编辑草稿。
- **元数据与结果**：协议徽章及重复主状态已纠偏；最终回答 footer 显示原文复制、查看改动及实际工具成功/失败/未完成数、已记录耗时、编辑记录次数/唯一路径数。Session 按用户轮次、room 按角色发言隔离，partial/intermediate 不冒充 final。`ToolFileChange` 仅捕获新发生的内置 write/edit/write_file 成功编辑；无变化为 []，旧记录缺失保持 nil，不回读当前文件补历史。bash/子代理/MCP 不覆盖，**不是全部 Agent-only changes**，也不造规划总步骤或测试通过数。
- **验证与待办**：已读 `remaining-core-v2.log`：串行 392 tests / 96 suites PASS（含 Labs，无 tracked-only 结论）；`remaining-dom.log`：54断言、19语义、4组零几何差、8组样式，无 SKIP；`cold-debug-agent-final.log`：生产桥接合成回归与500条历史恢复，heightReads/anchorErrorPX 均0；`usage-dialog-blur-final.log`：712 PASS / 0 FAIL / 0 SKIP。`remaining-final-build/retry/draft/room.log` 已有成功结束记录；`remaining-final-actions.log` 当前读取末尾中断，无汇总，不能沿用旧493。额外 Core+Coordinator 端到端新测试尚无本轮运行结果，待 main 回填；默认并行 logger 隔离问题未关闭。全端点、逐测试结果计数、普通旧历史追溯补齐、完整 App/VoiceOver/原型像素仍未覆盖；当前 Release/提交/推送状态不能从旧包或上述日志推断。
- **不重复建设**：代码/回答复制、三种外观模式、模型/思考菜单、用量、附件、滚动与聊天室真实阶段能力已存在。模拟数字不照搬，也不能据此取消对应真实功能缺口。

### BACKLOG-ATTACHMENT-PREVIEW-ASPECT — 已发送图片放大比例

- **状态**：done / 用户验收通过（2026-09-12，反馈「图片可以了，good。」）。首轮修复未解决原图，第二轮修复已获确认；仅关闭本次原图预览比例问题，不扩大为全量格式验收。
- **根因与修复**：原图1244×1230、DPI72×144、缺省Orientation；首轮ImageIO thumbnail transform仍缩成1244×615。改为原始像素解码＋独立EXIF旋转/镜像，不改附件文件。
- **证据**：首轮代码在缺省方向新用例下比例2.0242（期望1.01138）失败；修正后26组真实窗口回归通过，原参数比例1.01070（舍入误差）。此前11组仅测显式方向字段，不能关闭问题。
- **入口**：`AttachmentPreviewWindow.swift`；`bash scripts/validation/check-attachment-preview.sh`；范围与限制见[审计附录](dev-notes/2026-09-12-prototype-production-gap-audit.md#附已发送图片预览比例修复)。

### BACKLOG-DOCUMENT-WORKBENCH-ACCEPTANCE — 生产 UI 人工验收与最终验证回填

- **状态**：阶段 1、阶段 2 已实施 / 待用户验收，不关闭本项。第一批阅读列、共用输入区与静态状态已调整，用量后续升级为窗口内居中对话框；第二批 root-only 共享分栏、自定义侧栏、项目卡片/统一条目、唯一身份 header 与实际发言角色横滚栏已接入。后续审批改为随文呈现，既有阶段、steering、权限语义与单文档架构保留。
- **第一批验证（历史）**：WK 19 语义、4 final geometry 零差、浅深 × 900/701/700/480 的 8 组样式/对比度、composer marked text 与完整 Debug build 已报告通过；无页面焦点的键盘样式 SKIP 保留。统一横向 24 后复跑及 cold/performance 数据已回填，不是第二批性能重跑。
- **独立组件 probe**：早期 900/620 × 浅深合成截图为 **PARTIAL，9 项 AX SKIP**，不追溯改成 PASS；后续真实鼠标模式在 900/620 × 浅深四组 strict 全部通过，覆盖送停、草稿及用量开关。曾出现的焦点超时已增加诊断，后续未复现，根因未确定。
- **第二批 FULL_WINDOW**：1200/900 × 浅深 × session/room 共 8 组布局/草稿、独立真实 keyDown 与 Web DOM 检查已通过；固定列表与同一 document fixture，room 仅变 header/role，不是 `ChatRoomFlowController` 业务验收。host detail 左边界约 234pt（含 macOS 容器边距），不证明玻璃截图正确。
- **视觉状态**：独立 cacheDisplay + WK snapshot 的 Tahoe 玻璃侧栏仍无有效像素；用户后续主动授权后，正式 App 深色普通会话的完整玻璃截图已取得并查看，900/1200pt 布局通过。未完成原型同内容对照与全部外观/聊天室场景，不称完全还原。
- **正式 App 已验收**：恢复系统侧栏按钮及其过渡（不再使用显式自定义按钮），构建与 AX 开关往返通过；历史会话用量五项展示、非空临时草稿经侧栏往返保持、模型菜单/用量弹层 Escape 关闭后焦点恢复与续写通过。临时草稿已清空，未发送、未切模型；controller 守卫构建验证已回填。
- **后续补齐**：失败卡/Session 重试、Git 改动、三建议、消息元数据与摘要继续保留；用量对话框、随文审批/预览、回答级结果入口已实施。最新 Debug 构建和冷恢复日志已回填，但合成窗口/桥接验证不是整款 App 用户验收，不能沿用上行历史验收关闭本项。详见[当前记录](dev-notes/2026-09-13-workbench-dialogs-and-results.md)。
- **仍需**：项目/会话/聊天室切换时的草稿与滚动恢复、聊天室 header/角色栏及 phase/插话/停止、模型实际切换与运行中禁用、附件与真实 IME、浅色/系统高对比及 VoiceOver。已验证的菜单关闭焦点不代表完整键盘路线通过。
- **范围**：侧栏“未全面调整”仅为阶段 1 历史范围；第二批已接入、仍待实机视觉验收。设置页面/导航未重写；header Git diff 仍是独立的全工作区视图，不能与审批拟执行预览或回答内已捕获编辑记录混同；均不提供回滚。原型 demo 不进入生产；前两批八项对照与证据见 [实施与验收记录](dev-notes/2026-09-12-document-workbench-ui.md)。

### BACKLOG-NAVIGATION-DRAFT — 视图重建丢失输入草稿

- **状态**：运行时存活期间的视图重建丢稿已修复，正式整窗组合验收待完成。
- **修复**：Session 文本/图片与聊天室文本改由运行时持有独立草稿对象，输入面板直接观察，不向父级逐键广播。
- **证据**：固定旧提交 `61259c1` 在 Room A→B→A 断言失败；修复版强制重建、跨模式隔离、图片保留、Session 发送守卫及父通知为 0 的回归通过，完整 Debug build 通过。
- **边界**：不保证 Session LRU 淘汰、切项目、退出后的保留，不保存未提交 IME/光标/撤销栈。聊天室消息追加抛错后清稿及内存重复问题已在后续修复；实际导航/滚动组合待验收。
- **记录**：[草稿生命周期](dev-notes/2026-09-12-navigation-draft-lifetime.md)。

### BACKLOG-CHATROOM-SEND-ACCEPTANCE — 发送失败清稿与内存重复

- **状态**：已修复已复现的追加抛错路径。消息先落盘再加入内存/steering，控制器返回接受结果，UI 仅成功后清稿和落底。
- **证据**：故障注入前旧版清稿、内存多出消息且重试重复；修复后空闲/运行中两场景的保稿、错误提示、重试和磁盘 ID 一致性通过。聊天室 85 个核心测试、App 守卫和完整 Debug 构建通过。
- **边界**：不新增自动重试、消息幂等键或事务存储；FileHandle 部分写入、断电、跨进程并发及排序元数据保存失败恢复不在本次保证内。详见[发送接受边界](dev-notes/2026-09-12-navigation-draft-lifetime.md#后续聊天室发送接受边界)。

## 渲染后续 — 2026-09-11 Markdown 结束时小幅跳动

### BACKLOG-MARKDOWN-FINAL-REFLOW — 流式与最终 Markdown 结构不一致

- **状态（2026-09-12）**：语义分块导致的已复现问题已修复；用户原始场景仍待验收。
- **用户反馈**：提示“输出一个 markdown，我在测试 markdown 渲染，不要使用代码围栏包围”时，
  结束阶段必现约一行的小幅跳动。与上一轮正文/工具交替的 160px 人工占位问题分开跟踪。
  反馈时仓库为 `f88a5b1`；尚未核实运行中 App 的版本和该次生成正文的精确内容。
- **修复前证据（保留）**：旧 `splitBlocks` 按空行切分，可能把同一个松散列表拆成多个独立列表；
  `renderFinal` 再全文解析为单个含 `li > p` 的列表，触发不同的边距和高度。
  真实 WKWebView 对相同 source 的检查中，三项空行分隔有序列表结束时正文高度 **77 → 103px**；
  收尾钉底使 `scrollY` **701 → 727px**，实际形成 **26px** 的滚动位移。
- **边界**：14 个合成样例中，普通段落、标题、紧凑列表、简单表格、单围栏代码等没有高度差；
  因而不能推断“所有非围栏 Markdown 都必现”，也未证明用户该次输出一定是同一原因。
- **已修复**：流式全文 `markdown.parse` 后按 `nesting` 分顶层 token，直接 `renderer.render`；
  保留 DOM 冻结前缀与单围栏 Text 追加，reference 环境变化时失效；源片段保留尾换行，
  repair 仅限末尾有 `map` 的 inline 叶子，EOF 围栏交给 parser。不改 CSS、滚动或原生布局，不接入 HTML replay。
- **已运行验证**：真实 WKWebView 19 个语义用例全部通过，含字符级与一次性流式对照；
  松散有序/无序列表、嵌套列表、引用四类收尾 `heightDelta=0`、`scrollDelta=0`，32px 尾距与上翻锚点保持。
  100 块仍为 199 次插入、200 行单围栏仍为 0 次子树重建；原生 200 行三轮对照无该场景明显退化，
  500 条历史首载/切回、聊天室 A/B/A 及进程恢复回归通过。不是严密性能统计，也不代表完整 App 验收。
- **剩余边界**：用户原始那次精确正文与运行版本未保存，仍待原场景验收；全文 parse 每次 O(n)，
  连续增长的累计成本需大型样本观察。嵌套围栏 DOM 细粒度优化、未闭合 inline 最终还原产生的重排不在本次保证内。
- **详细记录**：[2026-09-12 修复与验证](dev-notes/2026-09-12-markdown-final-reflow.md)；
  原始证据与最小复现保留于 [性能复核 §16](dev-notes/2026-09-11-long-session-rendering-review.md#16-非围栏-markdown-结束时约一行跳动待修复)。

## 性能后续 — 2026-09-11 多轮测试（暂缓实施）

用户要求先记录，后续再处理。以下证据来自 09:11–09:25 的测试与同机对照，不表示已修复。

### BACKLOG-SHELL-STARTUP — 优化登录 shell 的重复启动成本

- **状态**：open / deferred；优先于下面的工具参数打点。
- **现象与证据**：23 次 bash 调用累计 13.03s，单次多数为 0.48–0.75s。
  使用无操作命令 `:` 各测 5 次，`zsh -lc ':'` 中位数 512ms，
  `zsh -c ':'` 为 10ms，`zsh -fc ':'` 为 9ms。最后一轮任务的 9 次 bash 调用累计约 5s。
- **代码入口**：[BashTool](../Packages/NewPiCore/Sources/NewPiCore/Tools/BuiltInTools.swift)
  每次执行都会新建 `/bin/zsh -lc`。对照支持“当前机器的登录 shell 初始化有明显固定成本”，
  不代表所有机器都有同样耗时，也尚未定位具体启动配置。
- **后续方向**：评估如何减少重复环境初始化，同时保留 PATH、版本管理器、工具查找、
  工作目录与环境覆盖行为；不能直接删除 `-l` 后就认定等价，也不预先决定复用常驻 shell。
- **验收**：相同环境下对照空命令与真实多工具任务的启动/总耗时；验证命令可用性、
  超时/取消、退出码与输出捕获，避免环境或命令状态跨调用意外泄漏。

### BACKLOG-TOOL-ARGUMENT-TIMING — 补工具参数生成阶段打点

- **状态**：open / deferred。
- **现象与证据**：09:23:54 发起的一次 Responses 请求，正文停止后约 4.4s 才结束；
  终态为 `toolUse`，包含一个 `write` 调用，正文仅 85 字符但总输出为 1392 tokens。
  这段时间可能在生成工具参数，**不能仅凭无正文就判定为服务端静默或 UI 卡顿**。
- **已有能力**：发送到首字的 runID 时间线、正文末次 delta、text done 和请求终态已经记录，
  见 [API 指标设计](api-metrics-design.md)。不重做这些已有打点。
- **待补充**：按 API 请求及工具调用标识关联参数首个 delta、最后 delta、arguments done，
  并记录事件数/长度；与正文、请求终态和实际工具执行边界分开。
  入口：[ResponsesSSEDecoder](../Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesSSEDecoder.swift)、
  [ResponsesAPIProvider](../Packages/NewPiCore/Sources/NewPiCore/Providers/ResponsesAPI/ResponsesAPIProvider.swift)、
  [RequestLatencyTrace](../Packages/NewPiCore/Sources/NewPiCore/Diagnostics/RequestLatencyTrace.swift)。
- **边界与验收**：日志不记录参数正文、文件内容或凭据，不逐 token 写日志；覆盖多个工具调用、
  多轮请求、子 Agent、无 delta 直接 done、错误与取消。已有 run 级阶段只记首次，
  不能将后续请求的工具参数时间混入首个请求；不得改变完成语义或提前执行不完整参数。

## Phase 4 — Session persistence

| ID | Item | Status | Notes |
|---|---|---|---|
| P4-UI | Sidebar session list + resume | done | Phase 4b/c |
| P4-BRANCH | Branch/fork UI for tree sessions | done | Fork from transcript row |
| P4-RESUME-PROVIDER | Restore provider profile from session header on resume | done | 恢复会话时读取 header 中的 profile |
| P4-CLI | CLI session commands | done | `new-pi sessions list/show/export` |
| P4-AUTO-RESUME | 打开 App / 项目时自动恢复上次离开时的 Session | done | `NewPiLastSessionStore` 按项目记录最后活跃会话；`openProject` 后 `restoreLastSessionIfPossible` 恢复；归档当前会话时清除记录 |

## Phase 8 — Advanced session & agent

| ID | Item | Status | Notes |
|---|---|---|---|
| P8-EXPORT | Export transcript/session | done | Markdown/JSON/text; App + CLI |
| P8-SUBAGENT | 子 agent 任务委派 | done | `subagent` 继承审批链；工具批次当前逐个执行，真实并行调度未实现 |

## Phase 5 — 已完成

| ID | Item | Status | Notes |
|---|---|---|---|
| P5-AGENTS | AGENTS.md loader | done | `.new-pi/AGENTS.md` then project root |
| P5-SKILLS | Swift Skills protocol + SKILL.md loader | done | `~/.new-pi/agent/skills/`, `.new-pi/skills/` |
| P5-COMPACT | Context compaction | done | `CompactionService` before each turn |

## Phase 6 — UI polish

| ID | Item | Status | Notes |
|---|---|---|---|
| P6-PROVIDER-PICKER | In-chat provider switch | done | Sidebar picker, preserves session |
| P6-TEST-CONN | Settings "Test provider" button | done | Provider 设置中测试连接 |
| P6-MARKDOWN | Transcript markdown rendering | done | 当前正文统一使用单文档 WebView，AttributedString 仅为早期里程碑 |
| P6-MARKDOWN-WEB | WKWebView markdown + streaming | done | 单文档迁移已完成；结束时重排问题单独跟踪 `BACKLOG-MARKDOWN-FINAL-REFLOW` |

## Phase 6c — 旧 per-message 滚动待办（已归档）

`UX-REBUILD-ID`、`UX-HEIGHT-CLIP`、`UX-SCROLL-MONITOR`、`UX-FLUSH-HEIGHT-RACE`、
`UX-FLUSH-SHRINK`、`UX-SCROLL-BODY`、`UX-THINKING-LAYOUT`、`UX-NC-COUPLING`
来自旧原生列表与逐消息 WebView 路径，不再按原方案排期。
历史问题与证据见 [2026-08-26 记录](dev-notes/2026-08-26-streaming-markdown-scroll-ux.md)，
当前滚动边界见 [UI 架构 ADR](ui-architecture-decision.md)。这不表示所有新架构视觉问题都已解决，
仍需跟踪本文的 final reflow 与冷恢复体验条目。

## Credentials / debug

| ID | Item | Status | Notes |
|---|---|---|---|
| CRED-DEBUG-STORE | UserDefaults-first API key storage | done | AIChatMac-style; Keychain opt-in via Settings |
| CRED-DEV-ENV | Development `.env` loader | done | `NEW_PI_ENV_FILE` or repo-root `.env` |

## Phase 7 — From AIChatMac learnings

| ID | Item | Status | Notes |
|---|---|---|---|
| P7-LOGS | In-app debug logs | done | `NewPiLogger` + Logs sheet |
| P7-UX | Chat UX polish | done | empty state, auto-scroll, copy, bubbles |
| P7-MCP | MCP client | done | stdio MCP + Settings UI |

## 功能状态 — 待办与已完成项

> 2026-09-13 展示更新：下表 `BACKLOG-TOKEN-BAR` 的内联用量/tooltip/Divider 描述保留为历史实施记录；当前为静态主状态与窗口内居中用量对话框（四卡片＋三摘要，真实可空数据）。实现、验证与待验收边界见上方工作台条目。

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-TOKEN-BAR | 状态栏显示当前对话的 token 用量 | done | P1 | 已实现：`SessionRuntime` 新增 `totalUsage`/`lastTurnUsage`（@Published），`messageEnd(.assistant)` 时累计；冷恢复由历史消息的 usage 重建（`accumulateUsage`）；输入框上方状态栏右侧显示累计 `↑输入 ↓输出`（紧凑格式，tooltip 含最近一轮明细）+ 缓存命中率（⚡xx%，`UsageStats` 新增 cacheRead/cacheCreation 字段，Anthropic/OpenAI 兼容/Responses 三个 provider 均已解析，含 DeepSeek `prompt_cache_hit_tokens` 变体；旧 JSONL 解码兼容缺省 0）。另：状态栏与输入框间的 Divider 移到状态栏上方。注意：OpenAI 兼容 provider 流式原本不报 usage（REV-PROV-6），需端点支持才显示。 |
| BACKLOG-SESSION-HOVER-GLASS | Session 列表鼠标悬浮玻璃高亮效果 | 待验收 | P2 | 第一批前的 `SessionRow` 曾使用 `onHover`、`thinMaterial` 与描边；第二批改为共用 `WorkbenchSidebarRowSurface` 的轻底 hover / 绿色选中态。保留 ID，待用户确认 A 风格及原生玻璃侧栏效果；现有不完整截图不能证明视觉验收通过。 |
| BACKLOG-BUBBLE-BG | 输入/输出气泡背景色一致并可区分 | superseded by A | P2 | 2026-09-12 用户选择 A 文档工作台：assistant 无彩色底、user 左对齐中性底；旧按 turn 分色要求被取代，保留 ID，不再按彩色气泡验收。tint 数据通道保留不等于仍以彩色底板展示；见 [实施记录](dev-notes/2026-09-12-document-workbench-ui.md)。 |
| BACKLOG-THINKING-COLLAPSE | 思考过程默认折叠，提供按钮手动展开查看 | done | P2 | 已实现并归并到 `BACKLOG-FOLD-THINKING-TOOL`；JS 卡片保留手动展开状态，不再重复排期。 |
| BACKLOG-SESSION-AUTO-SELECT | 存档/删除 session 后自动切换到下一个 session | done | P2 | 已实现：`archiveSession` 归档当前会话后自动切到同项目列表中的下一条（优先下面一条，末条则回退到最新一条）；同项目无更多会话时保持空态。「下一个项目」暂未实现（App 是单项目模型，无项目列表概念）。 |
| BACKLOG-SESSION-RELOAD-SCROLL-JUMP | 重新加载 Session 时 loading 结束后滚动条跳动 | open | P2 | 已有后台恢复、generation 防竞态、首批 `restoreAnchor` 和文档内逐帧校正；不能再按“缺少锚点恢复”处理。仍需复验冷加载遮罩消失后的稳定性，代码存在不代表体验问题已关闭。入口：`NewPiViewModel.swift`、`NewPiTranscriptDocumentView.swift`、`transcript-document.js`；见 [冷加载记录](dev-notes/2026-09-11-transcript-cold-load.md)。 |
| BACKLOG-SESSION-MANUAL-CREATE | 新 Session 由用户手动创建，系统不自动新建 | done | P1 | 打开项目和更改 provider 不自动新建会话；恢复已有会话不属于新建。归档后的选择行为见 `BACKLOG-SESSION-AUTO-SELECT`，无剩余会话时回到空态。 |
| BACKLOG-DEFAULT-PROVIDER | 新增默认 Provider 设置，新建 Session 默认使用该 Provider | done | P1 | 已实现：Settings「Default Provider」picker 语义改为「Default for new sessions」并加说明（只影响新建会话）；侧边栏 Provider 区新增「Set as Default」快捷入口（当前会话 provider ≠ 默认时显示）；默认 provider 不影响已有会话，会话内切换随 header 逐会话记忆并立即落盘。 |
| BACKLOG-FORK-COMPACT-HISTORY | fork + compaction 叠加时，被压缩历史无法在 fork 后恢复 | open | P2 | **已知限制（方案 A 已接受）**：对话先触发 compaction（历史被 summary 取代，`context.messages` 只剩 `[summary] + 最近8条`），随后用户 fork。fork 路径保留 `rebuildTranscript` 全量重建，但此时 `context.messages` 已不含被压缩的完整历史，重建后那段历史只剩 summary 占位、无法恢复。根治需把完整 transcript 独立落盘（不依赖 `context.messages`），或 fork 时合并 `runtime.transcript` 的存量完整历史。当前主流程（单分支长对话）已由方案 A 修复（agentEnd 就地校准、不再清空重建），本条仅针对罕见的 fork+compaction 叠加。 |

## Backlog — 对话流滚动

| ID | Item | Status | Notes |
|---|---|---|---|
| BACKLOG-SCROLL-LAG | 旧原生列表滑动不跟手 | closed / obsolete | 旧窗口化、高度表与多个原生滚动机制已删除；历史分析见 [旧滚动笔记](dev-notes/chat-scroll-layout.md)。新单文档路径的性能问题应按新证据单列，不恢复旧路径。 |

## Backlog — 状态栏

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-STATUS-READY-LAG | 状态栏从 working/writing 翻回 ready 比正文完成晚数秒 | done | P2 | 现象：正文输出完毕、气泡光标已提前消失（streamingBubbleComplete）后，状态栏仍等 `agentEnd` 才翻回 ready；agentEnd 排在流式积压与收尾事件（messageStart/messageEnd/contextSnapshot×2/persist）之后，每一步主线程渲染提交 ~1s，累计晚 2-6s。**已实现（feat/agent-output-optimization）**：`SessionRuntime.finalAnswerComplete` —— messageEnd 且该 assistant 消息无工具调用时置位（有工具调用则后续还有 turn，不置位；textDelta/toolExecutionStart/agentStart 复位），`agentStatusPresentation` 在 `isStreaming && !finalAnswerComplete` 时才展示进行态。保守边界：只影响状态栏展示，isStreaming（Stop/composer/钉底）仍跟 agentEnd，无并发风险。原分析：方向：状态跟 messageEnd 走（「正文完成即 finishing」，工具调用/多轮场景需区分）。涉及 `NewPiViewModel.handle`、`agentStatusPresentation`。 |

## Backlog — 输入框

### 2026-09-13 方向键取回历史输入

- **已实现 / 待用户验收**：普通会话和聊天室均可在首显示行按裸 ↑ 取上一条用户文字，在末显示行按裸 ↓ 取下一条；回到最新位置恢复浏览前草稿，不自动发送。取回多行后光标置于开头，需到末显示行再向下翻阅；自动换行也按显示行处理。
- **范围**：仅当前会话已有用户文本，跳过空白/纯图片消息；不回填历史附件、不改当前附件。历史取自当前 transcript/room messages，不补查已压缩且不在当前转录中的记录。浏览状态随运行时草稿保活，编辑或发送清稿后退出；没有跨会话全局历史。
- **验证**：`check-composer-history.sh` 38 项隔离原生键盘/草稿检查、`NEWPI_EXPECT_DRAFT_FIX=1 check-composer-streaming.sh` 及完整 Debug 构建通过。覆盖显示行、选区/修饰键、合成 marked text、草稿恢复及附件保留；不使用 AX/全局事件，不代替真实输入法候选窗与完整 App 人工验收。

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-HISTORY-COUNT | 历史记录展示条数由 5 条改为 7 条 | cancelled | P2 | 已决定不做，保留编号备查。 |
| BACKLOG-SHOWALL-INCREMENT | 点击 Show all 按钮时每次只多显示 5 条（增量展开） | done | P2 | 已实现：`showsAllSessions` 布尔开关改为 `sessionDisplayLimit` 计数器（默认 5，点击 Show all 每次 +5 封顶，Show less 收回默认；切项目重置）。见 `NewPiApp.swift`。 |
| BACKLOG-COMPOSER-MULTILINE | 多行输入框 | done | P1 | `NewPiComposerTextView` 使用 NSTextView，支持内部滚动、Return 发送、Shift+Return 换行及 IME 组词保护；后续输入法与流式交互核验见 [composer 记录](dev-notes/2026-09-11-composer-marked-text.md)。 |
| BACKLOG-STATUS-BAR | 状态栏位于输入框上方、正文之外 | done | P2 | `NewPiAgentStatusBar` 位于原生 composer 区域，已显示状态及 token 用量，不再作为未来扩展计划。 |
| BACKLOG-HOVER-BUTTON-DISAPPEAR | 鼠标放到 Copy / Fork 按钮上时消失 | done | P1 | 原生 `NewPiTranscriptRow` 的历史修复已随旧路径退出；当前操作按钮由单文档 JS/CSS 管理，不应再修改已删除的逐消息 hover 机制。 |
| BACKLOG-IMAGE-INPUT | 图片选择、拖拽、粘贴与移除 | done | P1 | 已实现草稿缩略图、预处理、会话附件落盘、三类 provider 编码和原生预览；发送前要求模型标记为支持图片。后续验证与限制见 [图片设计记录](multi-modal-vision-plan.md)，Snipaste 历史修复见 [粘贴记录](dev-notes/2026-08-31-snipaste-paste-fix.md)。 |

## Backlog — 思考过程 / 工具输出折叠

| ID | Item | Status | Priority | Notes |
|---|---|---|---|---|
| BACKLOG-FOLD-THINKING-TOOL | 思考过程与工具输出统一折叠及预览 | done | P1 | thinking 已经由增量缓冲进入 transcript，冷恢复从 `reasoningContent` 重建；JS 的 thinking/tool 卡片默认折叠并保留手动展开状态。更高层的详情分组见 [详情折叠记录](detail-collapse-plan.md)。 |

## Code review 2026-08-27 — 历史审查索引

原始发现与当时行号见 [审查记录](dev-notes/2026-08-27-code-review-findings.md)。
以下核心条目于 2026-09-12 对照源码确认已有修复；本次为文档核对，未重跑测试，也不是完整安全审计。

| ID | 原问题 | 当前状态 | 源码依据 |
|---|---|---|---|
| REV-CORE-1 | 错误路径回滚上下文 | done | `AgentLoop.run` 在 do 外保留运行中的可变 context |
| REV-CORE-2 | Anthropic 跨块解析状态丢失 | done | `AnthropicSSEDecoder` / `AnthropicStreamParser` 持有事件、工具参数与终态状态 |
| REV-CORE-3 | MCP actor 同步读取死锁 | done | `MCPStdioTransport.startReadLoop` 使用 readabilityHandler + AsyncStream |
| REV-CORE-4 | SubAgent 绕过审批 | done | `SubAgentTool` 透传 policy、审批回调、危险评估、tracker 和审计 |
| REV-CORE-5 | Compaction 后持久化失效 | done | `SessionManager.syncMessages` 写入 `.compaction` 屏障并挂载保留消息 |
| REV-CORE-6 | JSON 数字 0/1 被当作 Bool | done | `JSONValueDecoder.parse` 先通过 CFBoolean 类型判定 |
| REV-CORE-7 | 留空 API key 删除已存凭据 | done | `NewPiViewModel.saveProfile` 对空 key 跳过保存 |
| REV-CORE-8 | Bash 输出无限累积 | done | `BashTool.readPipe` 限制保留字节，超限后继续排空管道 |

以下分组尚未逐项重审，保留原优先级用于后续复核，不能笼统称为“仍未修复”或“全部关闭”：

| ID | 范围 | 状态 | 原优先级 |
|---|---|---|---|
| REV-SEC | SEC-1..8：危险规则、参数摘要、取消与授权 | 待复核 | P1 |
| REV-PROV | PROV-1..9：凭据边界、存储、超时与 thinking 兼容 | 待复核 | P1 |
| REV-MCP | MCP-1..7：协议、分帧、通知、环境与生命周期 | 待复核 | P1 |
| REV-UI | UI-1..9：项目切换、runtime 生命周期和状态展示 | 待复核 | P2 |
| REV-TEST | TEST-1..6：测试隔离与覆盖范围 | 待复核 | P2 |

## Known environment noise (no action)

- `com.apple.linkd.autoShortcut` — App Intents registration in Xcode debug; benign
- `ViewBridge Terminated` — Settings window close; benign
