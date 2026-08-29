# NewPi

macOS 编码 agent 应用（SwiftUI + AppKit + WKWebView），支持 Anthropic / OpenAI-compatible / Responses 三种 provider。

## 构建与测试

**Swift 命令必须在 `Packages/NewPiCore/` 下运行**，不是仓库根目录：

```bash
cd Packages/NewPiCore
swift test                    # 21 个测试文件
swift build
swift run new-pi              # CLI 入口
```

打包 macOS app（从仓库根目录）：

```bash
./scripts/package.sh          # Release → dist/NewPi.app
./scripts/package.sh Debug
```

部署目标 **macOS 15.0**（可用 Safari 18 / WebKit 特性，如 `content-visibility`；
`overflow-anchor` 实测不支持）。

## 目录结构

```
Packages/NewPiCore/    SwiftPM library + CLI（agent loop、providers、session 存储）
  Sources/NewPiCore/Anthropic/      AnthropicProvider
  Sources/NewPiCore/Providers/      OpenAICompatible / ResponsesAPI / 配置
NewPiApp/              SwiftUI macOS app 源码（不在 SwiftPM 包内）
  MarkdownRenderer/    渲染器本地资源：markdown-it / highlight.js / CSS（无 CDN 依赖）
scripts/               打包脚本
docs/                  架构与设计文档
research-repos/        13 个第三方仓库克隆，仅供参考 —— 只读，禁止修改
```

## 关键约束

- **`research-repos/` 是第三方代码**，已 gitignore，任何情况下不要编辑
- **渲染器资源必须保持本地**，不引入 CDN（离线可用 + 隐私 + CSP 无 `unsafe-inline`）
- **流式期间不写持久模型**：provider delta → 易失渲染态；流结束才落 transcript
- 注释与文档用中文，与既有代码保持一致

## UI 渲染架构（改动前必读）

正文 Markdown 走 WKWebView，当前**每条消息一个 WebView**。相关文件：

| 文件 | 职责 |
|---|---|
| `NewPiApp/MarkdownRenderer/markdown-renderer.js` | 块级增量渲染、尾部规范化、产物快照/重放 |
| `NewPiApp/NewPiMarkdownWebRenderer.swift` | WebView 宿主 + `MarkdownRenderingCache`（宽度桶 + 内容 SHA256，持久化） |
| `NewPiApp/NewPiMarkdownHeightPreheater.swift` | 冷恢复离屏探针测高 |
| `NewPiApp/NewPiChatView.swift` | 手动窗口化（用 `VStack` 不是 `LazyVStack`）、rail、滚动 |
| `NewPiApp/NewPiTranscriptHeightMap.swift` | 高度表（rail 定位与占位的共同数据源） |

已实现、**不要重做**：块级增量 + 冻结前缀对齐、尾部未闭合标记修复、
rail pending jump + 有界校正、render-once/replay、ResizeObserver 高度桥。

已知待办与目标架构见 `docs/`（下节）。

## 文档

`docs/` 下三份 UI 文档互相引用，改动结论时需同步：

| 文档 | 内容 |
|---|---|
| `ui-architecture-research.md` | 13 仓库调研（含 §4.0 现状台账：已完成 vs 待办） |
| `ui-architecture-research-verification.md` | 上文的源码级核验记录与修正依据 |
| `ui-target-architecture.md` | 单文档 transcript 目标架构提案（架构前提与前两份不同） |

其他：`architecture.md`、`TODO.md`、`approval-permissions-design.md`、
`multi-model-collaboration-plan.md`、`session-switch-instant-resume-plan.md`、
`rendered-result-replay-plan.md`

## 工作约定

- 引用文档结论前先用代码交叉验证 —— 文档可能落后于实现
- 提出「补上 X」类建议前，先确认 X 是否已实现（历史上出现过把已完成项列为待办）
