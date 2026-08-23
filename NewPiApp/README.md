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
2. 粘贴 **Anthropic API Key** → **Save API Key**

或在终端设置环境变量后从 Xcode 启动：

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

（Xcode 默认不会继承 shell 环境；推荐用 Settings 存 Keychain。）

## 5. 开始对话

1. 左侧 **Open Project…** 选择代码目录
2. 右侧输入消息 → **Send**

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

## 要求

- macOS 15+
- Xcode 16+（Swift 6）
