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
