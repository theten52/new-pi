import AppKit
import SwiftUI

/// 仅合成 AppKit 窗口／内存草稿；无 AX、全局事件、剪贴板、录屏、模型请求或用户文件。
@main @MainActor struct NativeAuditChecks {
    static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        print("PASS: \(label)")
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        Task { @MainActor in
            await run()
            print("PASS: native audit focused checks; production app/real IME/visual acceptance NOT covered")
            exit(0)
        }
        NSApp.run()
    }

    static func run() async {
        let draft = NewPiComposerDraft(), destination = NewPiComposerDraft()
        check(draft.focusRequest == nil, "新草稿不主动抢焦点")
        check(draft.fillSuggestion("建议"), "建议填空稿")
        let focus = draft.focusRequest
        check(focus != nil && !draft.fillSuggestion("覆盖") && draft.focusRequest == focus, "建议请求焦点但不覆盖现稿")
        let image = DraftImageAttachment(data: Data([1]), displayName: "真实名字.png", mediaType: "image/png")
        draft.attachments = [image]
        let lateDelivery = draft.attachmentReceiver()
        destination.text = "目标已有草稿"
        check(!draft.transfer(to: destination) && draft.text == "建议" && draft.attachments.count == 1, "交接失败保留全部输入")
        destination.text = ""
        draft.isComposing = true
        check(!draft.transfer(to: destination), "输入法组合期间拒绝交接")
        draft.isComposing = false
        draft.text += "创建期间编辑"
        check(draft.transfer(to: destination), "交接最新文本与附件")
        check(destination.text == "建议创建期间编辑" && destination.attachments.map(\.id) == [image.id], "编辑不丢失，附件身份保留")
        check(draft.text.isEmpty && draft.attachments.isEmpty && destination.focusRequest != nil, "单次转移并请求目标焦点")
        check(!draft.transfer(to: destination), "空稿不重复转移")
        let late = DraftImageAttachment(data: Data([2]), displayName: "晚到.png", mediaType: "image/png")
        lateDelivery([late])
        check(destination.attachments.map(\.id) == [image.id, late.id], "旧解码回调只交给已接收草稿的会话")
        draft.attachmentReceiver()([image])
        check(draft.attachments.count == 1 && destination.attachments.count == 2, "新一代附件不串入旧会话")

        check(NewPiContextWarning.text(input: 0, window: 100) == nil, "未知输入不造警告")
        check(NewPiContextWarning.text(input: 99, window: 0) == nil, "未知窗口不造警告")
        check(NewPiContextWarning.text(input: 80, window: 100) == nil, "恰好80%不超过阈值")
        check(NewPiContextWarning.text(input: 81, window: 100)?.contains("81 / 当前模型窗口 100") == true, "超过80%显示实际分子分母")
        check(NewPiSidebarFacts.statusIcon(isRunning: false, outcome: nil) == "bubble.left", "冷数据不伪造完成")
        check(NewPiSidebarFacts.statusIcon(isRunning: true, outcome: "已完成") == "circle.dotted", "运行态优先")
        check(NewPiSidebarFacts.statusIcon(isRunning: false, outcome: "已停止（未完成）") == "stop.circle", "停止态")
        check(NewPiSidebarFacts.statusIcon(isRunning: false, outcome: "已完成") == "checkmark.circle", "真实完成态")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(NewPiSidebarFacts.relativeDate(now.addingTimeInterval(-10), now: now) == "刚刚", "相对时间使用给定事实")

        let editor = NewPiComposerInnerTextView()
        var focused = false
        editor.onFocusChange = { focused = $0 }
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        editor.frame = NSRect(x: 20, y: 20, width: 500, height: 100)
        parent.addSubview(editor)
        let button = NSButton(title: "焦点测试", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 140, width: 100, height: 30)
        parent.addSubview(button)
        let window = NSWindow(contentRect: parent.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parent
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause()
        check(window.isKeyWindow, "仅测试窗口获得焦点")
        // 窗口首次显示可能已自动选中 editor；先离开，确保测到真实焦点转换。
        check(window.makeFirstResponder(button), "焦点测试先移至按钮")
        await pause()
        check(window.firstResponder !== editor && !focused, "进入前明确未聚焦输入框")
        check(window.makeFirstResponder(editor), "输入框接受焦点转换")
        await pause()
        check(window.firstResponder === editor && focused, "本地 becomeFirstResponder 回调")
        window.makeFirstResponder(button)
        await pause()
        check(!focused, "本地 resignFirstResponder 回调")
        let focusDraft = NewPiComposerDraft()
        _ = focusDraft.fillSuggestion("建议后的光标")
        let wrapper = NewPiComposerTextView(
            text: Binding(get: { focusDraft.text }, set: { focusDraft.text = $0 }),
            focusRequest: focusDraft.focusRequest)
        let coordinator = NewPiComposerTextView.Coordinator(wrapper)
        coordinator.textView = editor
        editor.delegate = coordinator
        coordinator.synchronizeText(focusDraft.text)
        coordinator.requestFocusIfNeeded()
        await pause()
        check(window.firstResponder === editor && editor.selectedRange().location == (focusDraft.text as NSString).length,
            "建议token把焦点和插入点交给真实输入框")
        editor.insertText("继续键入", replacementRange: editor.selectedRange())
        check(focusDraft.text == "建议后的光标继续键入", "建议后可直接续写且同步Binding")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.requestFocusIfNeeded()
        await pause()
        check(editor.selectedRange().location == 1, "已消费焦点token不重置用户选区")
        editor.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    static func pause() async { try? await Task.sleep(for: .milliseconds(120)) }
}