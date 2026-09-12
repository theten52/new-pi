# 2026-09-12 · 文档工作台收尾验收

## 结论

**已执行的核心范围通过，非全量发布验收完成。** 本轮未发现新的产品缺陷，仅扩展/修正验收脚本。
产品源码基线 `7397551`，`feat/document-workbench-ui`。先完整 Debug 构建，再确认旧窗口为空输入、
无停止按钮后正常重启指定 `build/derived/Build/Products/Debug/NewPi.app`，没有使用旧 `dist`。
新实例 PID 为本轮的 66707，启动时间晚于本轮构建；PID 仅作为本机记录，不是固定脚本参数。

## 最新 App 实机结果

当前深色普通会话，公开 AX 接口 + 指定 PID 键盘事件：

- 系统 sidebar toggle 只有一个，无旧自定义按钮；收起/展开、输入框身份与内容保持通过。
- 空输入时临时键入固定草稿，发送按钮随之启用，未点击发送或按 Return。
- **真实 Session→聊天室→原 Session**：用系统选中状态记录返回目标，点击可见聊天室条目，
  核验聊天室操作入口出现且 Session 模型菜单消失，然后返回。输入框 AX 身份改变，证明确实重建；非空草稿恢复。
- 返回后的系统侧栏往返、模型菜单和用量弹窗打开/Escape 关闭、输入焦点恢复及续写均通过。
- 模型与思考级别的当前菜单值和原值一致，测试文本已清空，发送重新禁用；返回原 Session。
- 正式窗口 1200/900pt 下用量、模型、发送和更多入口均在窗口内，模型菜单与发送无碰撞，输入视口高 78pt、宽大于 400pt。
  原窗口尺寸已恢复（1539×839pt），新版 App 保持打开。
- 单窗口截图 `/private/tmp/newpi-ui/actual-initial.png` 已查看：深色侧栏、正文、身份栏及输入区可见，无重复侧栏图标。
  截图含已有会话内容，仅保存在本机，不加入 Git。

测试问题：首次导航后的末尾模型断言读取了重建前已卸载的 AX 菜单对象而失败；临时草稿仍正常清理。
改为重新定位当前菜单后整组复跑通过，没有放宽实际值一致性要求，也没有修改产品模型设置。

脚本入口为 `scripts/validation/NativeSidebarChecks.swift` 的 `check` / `composer` / `navigation` / `layout`。
`navigation-inspect` 只读辅助定位。正常运行需中文 UI、唯一输入框、原 Session 唯一选中、可见聊天室候选；
无法满足时失败，不猜坐标。模型菜单等 AX 节点在视图重建后必须重新定位。

## 本轮离线回归

| 检查 | 本轮结果 |
|---|---|
| 完整 NewPi scheme / Debug / macOS build | exit 0，BUILD SUCCEEDED |
| `check-draft-navigation.sh` | exit 0；跨视图文本/图片草稿、通知隔离、聊天室发送失败保稿及重试一致性通过 |
| `check-chatroom-controller.sh` | exit 0；运行/审批/取消/删除守卫及通知隔离通过 |
| `NEWPI_EXPECT_DRAFT_FIX=1 check-composer-streaming.sh` | exit 0；文本/选区、marked text 模拟、发送拒绝与外部恢复通过 |
| `check-transcript-dom.sh` | exit 0；19 语义、4 final geometry、8 浅深/宽度样式组合通过，本轮 SKIP 0 |
| `NEWPI_EXPECT_NO_UNUSED_HEIGHT=1 check-transcript-cold-load.sh` | 最终直接复跑 exit 0；500 条历史、聊天室 A/B/A、Session 返回，heightReads=0、anchorErrorPX=0；进程重建/迟到帧/隐藏追赶检查通过 |

冷加载首轮执行宿主超时，日志虽完成但未取到退出码，因此另行直接等待复跑后才记为通过。
最终复跑 throughTwoRAF：Session 首载 450.95ms，room A 373.18ms，B 211.65ms，A 返回 368.64ms，Session 返回 335.25ms。
这是受控 fixture 的单次结果，不是磁盘冷读、性能提升结论或真实 App 滚动像素精度证明。
日志中的文档进程终止来自恢复检查；DateFormatter nonisolated / AppIntents 提示为已有警告。
本轮未重新执行全部 Core 测试；此前 85 个 ChatRoom 核心测试结果见发送接受边界记录。

## 未覆盖（不能以本轮通过替代）

- 正式 App 的 Session A/B、Room A/B/A 非空草稿组合、真实滚动位置恢复误差、运行中后台切换。
  本轮实机仅完成 Session→一个聊天室→Session；更广组合当前仍只有隔离回归。
- 附件选择/粘贴/拖拽/预览全流程、真实中文输入法候选确认、跨重建的选区/撤销状态。
- 正式窗口浅色、系统高对比、VoiceOver 朗读与完整键盘路线；DOM 浅深色回归不替代这些。
- 真实模型发送/取消、聊天室阶段推进与审批。本轮未发送、未推进、未改变授权配置。
- 原型同内容完整视觉对照、Release 包安装/运行验收；未打包更新 `dist`、未推送或创建 PR。

临时键入已清理，但输入撤销栈可能保留测试编辑；导航和正常启动可能更新窗口偏好、滚动锚点和诊断日志，
不宣称磁盘零写入。用户学习资料和索引未纳入本轮修改。