# Snipaste 图片粘贴修复 (2026-08-31)

## 问题描述

使用 Snipaste 截图后，在 NewPi 输入框中按 Cmd+V 粘贴图片时：
- 无任何反应
- 系统发出 beep 声
- 控制台无日志输出（说明 `paste()` 方法从未被调用）

## 根本原因

**NSTextView 的 `validateUserInterfaceItem` 默认行为导致粘贴命令被禁用。**

`NewPiComposerInnerTextView`（继承自 NSTextView）未重写 `validateUserInterfaceItem` 方法。NSTextView 的默认实现在以下情况会返回 `false`，禁用粘贴命令：

1. `isEditable` 被设为 `false`（当 `isStreaming` 为 true 时，输入框被禁用）
2. Responder chain 异常
3. 其他 NSTextView 内部状态判断

当 `validateUserInterfaceItem` 返回 `false` 时：
- `paste()` 方法永远不会被调用
- 系统发出 beep 声表示命令被拒绝

## 修复方案

### 1. 重写 `validateUserInterfaceItem`

```swift
// 始终允许粘贴图片（即使 isEditable=false）。
// 不重写时，NSTextView 默认在 isEditable=false 或 responder chain 异常时返回 false，
// 导致 Cmd+V 被拒绝（beep）而 paste() 永远不被调用（Snipaste 粘贴问题的根因）。
override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(paste(_:)) {
        return true
    }
    return super.validateUserInterfaceItem(item)
}
```

### 2. 扩展 `PasteboardImageReader` 支持的类型

新增以下 pasteboard 类型支持：
- `public.jpeg` - JPEG UTI
- `image/png` - MIME 类型格式
- `image/tiff` - MIME 类型格式
- `image/jpeg` - MIME 类型格式
- `com.apple.pasteboard.tiff` - Apple TIFF 变体

同时增加数据有效性验证（通过魔数检查）和 `NSImage(pasteboard:)` 兜底方案。

## 涉及文件

- `NewPiApp/NewPiChatView.swift` - `NewPiComposerInnerTextView`
- `NewPiApp/ImageAttachmentProcessor.swift` - `PasteboardImageReader`

## 调试方法

如需调试类似问题，可在 `PasteboardImageReader.readImageData()` 和 `paste()` 方法中添加日志：

```swift
print("[PasteboardImageReader] pasteboard types: \(pasteboard.types?.map { $0.rawValue } ?? [])")
```

## 相关工具

调试脚本 `/tmp/snipaste_debug.swift` 可用于检查剪贴板内容：

```bash
swift /tmp/snipaste_debug.swift
```
