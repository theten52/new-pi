# rail 跳转定位 bug —— 修复状态交接（2026-08-28）

> 给后续会话/协作 Agent 的交接说明。**读这份，不用重新排查。**

## 一、Bug
长对话/多轮对话（消息列表很长、滚动偏移大）时，点击右侧"用户消息轨道"（`NewPiUserMessageRail`）某根横线，对应 You 消息气泡**定位不准**。

## 二、已确诊根因（实测证据）
1. **`ScrollViewReader.scrollTo(id, .top)` 在 macOS 上对 LazyVStack 尚未实例化的远距离行不生效**（找不到 `.id` 视图，目标行从不实例化）。→ 已改用 **`ScrollView` + `.scrollPosition(id: anchor:)` 绑定 + `LazyVStack.scrollTargetLayout()`**。**已实测生效**：目标行能被实例化（诊断日志 `row-appeared` 出现），用户确认"点击后已能跳到目标消息/视口顶部附近"。**核心定位已解决。**
2. **`loadInitial` 无条件 `self?.height = 44` 架空高度缓存**（`NewPiMarkdownText` 已用缓存高度初始化 `webHeight`，`makeNSView→loadInitial` 又打回 44）→ 已修为仅当 `height <= 0` 才兜底 44。
3. **剩余：精确贴顶差几 pt**。根因：目标行 `minY` 通过 `ChatJumpTargetPreferenceKey`（PreferenceKey）上报，但 GeometryReader 位于 **LazyVStack 内的行 `.background`**，而 **LazyVStack 内 preference 不向父级传播**（对比：底部锚点 `ChatBottomAnchorPreferenceKey` 在 LazyVStack **外面**、能正常传播）。因此 `onPreferenceChange(ChatJumpTargetPreferenceKey)` 从未触发、`correctJumpTargetIfNeeded` 从未执行、收敛不启动。

## 三、当前代码状态（build 通过，本分支 `feat/streaming-markdown-blocks`）
已改未提交（swift 文件）：
- `NewPiApp/NewPiChatView.swift`：`scrollPosition(id:anchor:)` + `scrollTargetLayout()`；`jumpToUserMessage` 去掉失效的 `scrollTo`；`correctJumpTargetIfNeeded` 改"连续 2 帧 minY 不漂移即稳定收敛"；`jumpScrollPosition`/`jumpTargetID` 等 @State；`onSelect` 用 `scrollPosition` 定位；DEBUG os.Logger 打点（`rail-jump → target=` / `row-appeared` / `minY=`，subsystem `com.newpi.app` category `railjump`）。
- `NewPiApp/NewPiChatScrollHelper.swift`：`ChatJumpTargetPreferenceKey.defaultValue` 改 `.infinity` 哨兵。
- `NewPiApp/NewPiMarkdownWebRenderer.swift`：`loadInitial` 不再无条件 =44（`height <= 0` 才兜底）。

## 四、诊断日志（复现/验证用）
```bash
log stream --predicate 'subsystem == "com.newpi.app" && category == "railjump"' --level debug
```
三类：`rail-jump → target=... 启动收敛`（onSelect 触发）、`row-appeared target=...`（**目标行被实例化**，scrollPosition 生效标志）、`minY=...`（收敛校正执行标志——当前为 0）。

## 五、剩余任务
- **精确贴顶几 pt**：已把全部实测结论交给 GLM（后台进程 `proc_3e8aab559da9`，用户指派 GLM 执行、**Hermes 不再改代码**）用**非 preference** 方案校正（onAppear + @Binding 回调，或测高稳定后二次 scrollPosition）。GLM 完成后核对 git diff + 独立 xcodebuild 验证 + 让用户实测。
- **待议项**（`docs/session-switch-instant-resume-plan.md` §七）：③快照兜底、高度缓存宽度敏感、`keptAliveRuntimes` 隐式刷新加固、单测。

## 六、约束/注意
- **不要**把 LazyVStack 改回 VStack（`docs/dev-notes/chat-scroll-layout.md` §3.10 明确禁止：WebView 急切挂载内存/WebContent 进程问题）。
- 提交避开 `docs/TODO.md`（用户已有改动）、`.understand-anything/`、`.vscode/`、`MarkdownRenderer/markdown-renderer.js`（他人改动）。
- 协作走 v2：Hermes 执行/写代码，K3(Kimi) 设计，GLM(claude CLI) review。
- 滚动定位是视觉组件，**用用户实测反馈**（别仅凭推理/LLM 结论改坐标）。
