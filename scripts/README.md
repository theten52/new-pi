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
