# 2026-09-12 · 文档工作台 Release 打包

> 本文为 `debf613` 首次打包记录。后续错误与部分输出持久化已更新 Release 包并获用户复验通过；
> 最新校验值、回退包与结果见[持久化交付记录](2026-09-12-session-error-persistence.md#用户最终复验)，不要将下方旧校验值当作当前 dist。

## 产物

- 源码基线：`debf613`，分支 `feat/document-workbench-ui`。
- 执行：仓库根目录 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package.sh Release`，exit 0。
- 新包：`dist/NewPi.app`（约 11MiB）；构建产物：`build/derived/Build/Products/Release/NewPi.app`。
- Bundle ID：`com.newpi.app`；版本保持 `0.1.0 (1)`，最低系统 macOS 15.0；本次产物仅 arm64，不是 Universal 包。
- 签名：ad-hoc、无 TeamIdentifier；未做 Developer ID 签名或公证，不作为外部分发已就绪的证明。

## 校验

- 独立执行 `codesign --verify --deep --strict --verbose=2 dist/NewPi.app`：exit 0。
  不依赖打包脚本的成功提示（现有脚本签名失败只打印提示，不强制失败）。
- dist 与 Release 构建目录的主二进制 SHA-256 相同：
  `a2e8328f859d08409345992a573dcd849e43115b7cc0afe67fabe863e8d086dc`。
- 源码 `NewPiApp/MarkdownRenderer` 与包内资源逐文件比较：双方各 9 个文件，差异 0。
- `otool -L` 显示主二进制依赖系统 Framework 与 `/usr/lib` 中的运行库，无开发目录或 Homebrew 绝对库路径。
- 本轮没有修改生产源码；构建前工作区只有用户学习资料/索引改动，不纳入交付提交。

## 回退包

在替换 dist 前，旧包已复制到：
`dist-backup/NewPi-before-workbench-20260912-190047.app`。

旧主二进制 SHA-256：`c921525643c4735e5b4a47968f41ea647722b0064d5f079938e75bf93e41d2f3`。
回退位置与 dist/build 一样被 Git 忽略，不提交二进制或截图。

## 运行及交付边界

本次只完成 Release 构建、复制与静态校验，**尚未启动 Release 包进行运行验收**；
没有退出当前 Debug App，当前运行实例不会因替换 dist 自动升级。
用户可在任务结束、草稿妥善处理后正常退出旧 App，再打开 `dist/NewPi.app`，
避免两个同 Bundle ID 版本同时运行或误以为仍打开的 Debug 实例就是新 Release。

前述 Debug 实机与回归结果见[验收记录](2026-09-12-workbench-acceptance.md)，不能替代 Release 运行验收。
本轮未推送远程、未创建或合并 PR，未更改会话或凭据；VoiceOver 等尚未覆盖的项目保持原有边界。