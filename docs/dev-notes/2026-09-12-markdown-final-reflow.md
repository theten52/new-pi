# Markdown 流式收尾重排：语义分块修复与验证

日期：2026-09-12。关联：`BACKLOG-MARKDOWN-FINAL-REFLOW`（[TODO](../TODO.md)）。

## 1. 结论与证据边界

**语义分块导致的已复现问题已修复；用户原始那次场景仍待验收。**
原反馈为“不使用代码围栏包围的 Markdown”在结束阶段约一行跳动；反馈时仓库为 `f88a5b1`，
但未保存精确生成正文，也未核实当时运行 App 的版本，不能断言该次现象必为同一根因。
原始取证保留在 [性能复核 §16](2026-09-11-long-session-rendering-review.md#16-非围栏-markdown-结束时约一行跳动待修复)。

下列测试已在本次修复中实际运行，记录的是受控回归结果，并非所有真实输入的完整验收。
另已完成 `NewPi` scheme 的 Debug App 构建（`BUILD SUCCEEDED`，产物位于 `build/derived`）；
未运行全核心测试，未覆盖 `dist/NewPi.app` 或启动用户会话。

## 2. 修复前真实失败

旧 `splitBlocks` 按空行拆分再独立解析；空行不一定是 Markdown 顶层语义边界，
同一松散列表、嵌套容器或围栏会被拆坏，reference 定义也不能跨块共享。
最终 `renderFinal` 全文解析时恢复正确结构，产生高度变化，收尾钉底把变化体现为滚动位移。

| 真实 WKWebView 样例 | 修复前最后流式态 → 最终态 |
|---|---|
| 三项松散有序列表 | 正文高度 **77 → 103px（+26px）**；`scrollY` **701 → 727px（+26px）** |
| 嵌套列表 | 高度 **137 → 163px（+26px）** |
| 长围栏 | 高度 **234 → 151px（−83px）** |
| reference 链接 | 流式/最终 DOM 语义存在差异 |

原先 14 个合成样例中普通段落、标题、紧凑列表、简单表格、单围栏等无高度差；
这既不能覆盖空行容器，也不支持“所有非围栏 Markdown 都必现”的推断。
本次不抹去原始 26px 证据，也不把它与此前正文/工具交替的 160px 人工占位问题混为一谈。

## 3. 实现与未改动范围

源码入口：[`markdown-renderer.js`](../../NewPiApp/MarkdownRenderer/markdown-renderer.js)。

- 每次流式快照先全文 `markdown.parse(source, env)`，按 token 的 `nesting` 深度回到 0 分组为顶层块；
  直接 `markdown.renderer.render(tokens, markdown.options, env)`，不再把源片段当独立 Markdown 重解析。
  保留全文 inline、reference、typographer 上下文，列表和引用的内部结构由 parser 决定。
- DOM 更新仍保留每帧冻结前缀对齐与单个顶层围栏的 Text 追加；不是每帧全量替换 DOM。
  reference 环境变化时使旧冻结结果失效，避免新增、修改或删除定义后仍显示旧链接。
- `token.map` 对应的源片段保留尾换行，使“只追加 EOF 换行”也进入缓存比较；
  CRLF/CR 与 NUL 规范化对齐 markdown-it。
- 尾部 repair 只作用于最后一个有 `map` 的 inline 叶子，且其后须仅有空白；
  不扫描容器中先前代码块的标记，不把修复符追加进 reference 定义，也不猜无 `map` 表格单元格的位置。
- EOF 未闭合围栏直接交给 parser，不人工追加闭合围栏或闭合 newline；围栏长度、缩进及代码内容由 parser 保真。
  最终态仍对**原始正文**完整解析并高亮，不能把流式修复副本当最终内容。

没有 CSS、滚动状态机或原生布局改动；保留自然高度、统一 32px 尾距、CV、Warmer/Poller 和文档内唯一
scroll writer。没有接入持久 HTML replay，也不恢复原生高度表、160px 占位或用动画掩盖变化。

## 4. 真实 WKWebView 语义与几何回归

入口：`./scripts/validation/check-transcript-dom.sh`，用例位于
[`TranscriptStreamingDOMChecks.swift`](../../scripts/validation/TranscriptStreamingDOMChecks.swift)。

**19 个语义用例全部通过**：松散有序列表、松散无序列表、嵌套列表、引用段落、相邻块、表格、
前向 reference、后向 reference、列表内 reference、typographer 与链接、长围栏、未闭合围栏、
带尾换行的未闭合围栏、未闭合长围栏、嵌套围栏、列表内代码后接正文、缩进代码、围栏后接正文、规范化换行。

测试包含逐行输入、字符级增量与相同前缀一次性流式对照，以及同源最后流式快照与最终态的语义/高度对比。
语义比较只剥除流式 `.markdown-block` 包装与最终高亮 span，不忽略列表、链接和代码文本的真实差异。
另验证 reference 新增/修改/删除失效，以及未闭合 inline 在最终态恢复原始正文。

| 收尾几何样例 | heightDelta | scrollDelta |
|---|---:|---:|
| 松散有序列表 | 0px | 0px |
| 松散无序列表 | 0px | 0px |
| 嵌套列表 | 0px | 0px |
| 引用段落 | 0px | 0px |

四例末行屏幕位置与 32px 尾距保持，上翻阅读时收尾不改变锚点；比较前先让历史 CV 占位收敛，
收尾变更本身不额外补滚动意图。上述结论限受控样例，不是任意 Markdown 流永不重排的保证。

既有增量约束保持：**100 块 199 次插入**，**200 行单围栏 0 次子树重建**；
冻结前缀身份、高亮提升、非末尾流式、手动展开及预热暂停/恢复等回归通过。
DOM 修改保持增量，不等于解析成本也变为增量。

## 5. 原生呈现与冷恢复对照

真实 SwiftUI/Coordinator/WKWebView 的可见呈现探针包含状态栏、rail、礼花；每轮合成 200 行，共三轮。
基线实跑用 `NEWPI_RENDERER_REVISION=HEAD`，当时 HEAD 为 **`5b6f302`**。
只替换临时资源目录中的 `markdown-renderer.js`，不切分支、不改工作区；并非两个完整 App 版本的对照。

| 指标（依次为第 1/2/3 轮） | 基线 renderer `5b6f302` | 修复版 renderer |
|---|---|---|
| wall（s） | 9.63 / 9.57 / 9.61 | 9.60 / 9.63 / 9.57 |
| maxMainActorLag（ms） | 18.9 / 10.5 / 17.1 | 10.2 / 11.3 / 11.1 |
| domMax（ms） | 9 / 7 / 8 | 8 / 8 / 7 |

修复版另通过 **3 次正文/工具交替、6 个工具、最终折叠与 32px 尾距**检查，最大 MainActor 延迟 **8.3ms**。
这是有限样本的场景回归，**不是严密性能统计，不宣称加速，只支持该场景没有明显退化**；
JS DOM 计时不等于屏幕呈现耗时，合成探针也不等同于用户完整 Debug App 场景。

500 条历史的 `session-first`、`session-return`，以及聊天室 `room-A` / `room-B` / `room-A-return`
冷加载回归全部通过，各行结果均为 **`heightReads=0`、`anchorErrorPX=0`**。
这里 `heightReads` 指 article 上不被消费的旧高度读取，不代表文档完全不测量几何；
没有恢复锚点的首载场景偏差字段记 0，恢复精度证据来自带锚点的切回场景。
聊天室 B 为小历史；“500 条”不是 500 turn，也不表示 A/B/A 每页都是 500 行。

同一探针的通知去重、单飞/最新快照、隐藏后追赶、追加/重排/元数据、静态及隐藏流式
process-recovery、帧超时与迟到帧隔离等检查通过。进程恢复通过调用真实终止回调触发，
未实际杀死系统进程；重放的是 transcript 快照，不是 HTML 产物。
不覆盖 SessionManager 完整读盘、完整 SwiftUI 导航或 Session 保活命中；fixture 刚写后读取可能命中 OS 页缓存。

## 6. 复验命令与剩余工作

在仓库根目录、macOS 图形登录会话下运行；不调用模型，不改用户会话数据。

- DOM：`./scripts/validation/check-transcript-dom.sh`
- 固定基线呈现：`NEWPI_PRESENTATION_REPLAY=1 NEWPI_RENDERER_REVISION=5b6f302 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 ./scripts/validation/check-transcript-cold-load.sh`
- 修复版呈现：`NEWPI_PRESENTATION_REPLAY=1 NEWPI_EXPECT_RESPONSIVE_PRESENTATION=1 ./scripts/validation/check-transcript-cold-load.sh`
- 冷恢复：`NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 ./scripts/validation/check-transcript-cold-load.sh`

回溯命令固定 `5b6f302` 而非 HEAD，避免后续提交改变基线；修复版省略 `NEWPI_RENDERER_REVISION`。
`NEWPI_PRESENTATION_REPLAY=1` 切换到 `-Onone` 呈现探针，变量名中的 replay 仅指合成呈现回放。
脚本构建所需 Core target 并编译探针，本身不等于全核心测试或完整 App build；
上文 Debug 构建结果来自另行执行的 `xcodebuild build`，不是由探针结果推断。

剩余边界：

1. 保存精确正文与运行版本后复验用户原始结束跳动场景，不能仅靠合成用例关闭体验验收。
2. 全文 parse 每次 **O(n)**；触发尾部 repair 时还可能再解析一次。连续增长快照的累计解析成本
   仍需更大型正文与复杂容器样本观察，冻结 DOM 不消除这部分成本。
3. 嵌套围栏仍随所属顶层容器渲染，**嵌套围栏 DOM 细粒度优化不在本次保证内**。
4. 未闭合 inline 的虚拟修复最终须还原原文，**该语义还原可能重排**，不在本次零重排保证内。