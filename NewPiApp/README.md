# 用 Xcode 打开并运行 NewPi

## 1. 打开工程

任选一种方式：

```bash
open ./NewPi.xcodeproj
```

或在 Finder 中双击：

`new-pi/NewPi.xcodeproj`

## 2. 选择 Scheme

Xcode 顶部工具栏：

- **Scheme:** `NewPi`
- **Destination:** `My Mac`（本机）

## 3. 运行

按 **⌘R**（Product → Run）。

首次运行若提示签名问题：

1. 选中左侧 **NewPi** 工程 → **TARGETS → NewPi**
2. **Signing & Capabilities** → 勾选 **Automatically manage signing**
3. 选择你的 **Team**（个人 Apple ID 即可）

## 4. 配置 API Key

App 启动后：

1. 菜单 **NewPi → Settings…**（或 **⌘,**）
2. 在 **Providers** 中创建或选择 profile，配置端点、模型及对应 API key。
3. 按需开启图片能力、选择默认 provider；本地模型是否需要 key 取决于服务配置。

也可在 Xcode Scheme 的 **Run → Arguments → Environment Variables** 中设置
provider 对应的环境变量（例如 `ANTHROPIC_API_KEY`）。Xcode 默认不会继承终端中临时设置的变量。
环境变量优先于已保存凭据；默认凭据存储为 UserDefaults，Keychain 是可选的额外存储，不应视为默认安全存储。

## 5. 开始对话

1. 左侧 **Open Project…** 选择代码目录
2. 选择已有 Session，或点击 **New Session** 手动创建会话
3. 右侧输入消息 → **Send**；有副作用的工具调用按当前策略请求审批

---

## 仅运行核心库 / 测试（可选）

不打开 App，只测 `NewPiCore`：

```bash
open Packages/NewPiCore/Package.swift
```

在 Xcode 中 **Product → Test**（⌘U），或终端：

```bash
cd Packages/NewPiCore && swift test
```

CLI：

```bash
cd Packages/NewPiCore && swift run new-pi
```

无参数时显示 provider 配置状态；会话管理使用 `sessions list/show/export`。
CLI 当前不提供交互式 Agent 对话。App/WebKit 校验入口见 [校验脚本说明](../scripts/README.md)，
核心包测试不能替代渲染与 UI 验证。

## 要求

- macOS 15+
- Xcode 16+（Swift 6）
