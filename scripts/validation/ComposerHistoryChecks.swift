import AppKit
import SwiftUI

/// 只向隔离的 NSTextView 分发事件，不使用 AX / CGEvent 或正式 App 数据。
@main
struct ComposerHistoryChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
        }
        let draft = NewPiComposerDraft()
        draft.text = "未发送 👋"
        let entries = ["第一条", "", " \n", "第二条"]
        check(draft.recallHistory(previous: false, entries: { entries }) == nil, "未浏览时向下不取历史")
        check(draft.recallHistory(previous: true, entries: { entries }) == "第二条", "取最新文本")
        check(draft.recallHistory(previous: true, entries: { [] }) == "第一条", "浏览期间固定来源并跳过空消息")
        check(draft.recallHistory(previous: true, entries: { [] }) == "第一条", "最旧位置不循环")
        check(draft.recallHistory(previous: false, entries: { [] }) == "第二条", "向下取较新文本")
        check(draft.recallHistory(previous: false, entries: { [] }) == "未发送 👋", "还原草稿")
        check(draft.recallHistory(previous: false, entries: { [] }) == nil, "还原后退出浏览")
        _ = draft.recallHistory(previous: true, entries: { entries })
        draft.text += " 编辑"
        check(draft.recallHistory(previous: false, entries: { entries }) == nil, "编辑退出浏览")
        _ = draft.recallHistory(previous: true, entries: { entries })
        check(draft.recallHistory(previous: false, entries: { entries }) == "第二条 编辑", "编辑后的文字成为新草稿")
        _ = draft.recallHistory(previous: true, entries: { entries })
        draft.text = ""
        check(draft.recallHistory(previous: false, entries: { entries }) == nil, "发送清稿退出浏览")
        let other = NewPiComposerDraft()
        check(other.recallHistory(previous: true, entries: { ["聊天室"] }) == "聊天室", "会话独立")
        check(draft.text.isEmpty, "另一个会话不影响草稿")
        check(draft.recallHistory(previous: true, entries: { ["", "\n"] }) == nil, "空历史不消费")
        let attachment = DraftImageAttachment(data: Data([1, 2, 3]), displayName: "test.png", mediaType: "image/png")
        draft.attachments = [attachment]
        _ = draft.recallHistory(previous: true, entries: { entries })
        _ = draft.recallHistory(previous: false, entries: { entries })
        check(draft.attachments.map(\.id) == [attachment.id], "历史不改当前附件")

        var calls = 0
        var submissions = 0
        var source = ["旧输入", "新输入"]
        let binding = Binding<String>(get: { draft.text }, set: { draft.text = $0 })
        let wrapper = NewPiComposerTextView(text: binding, onSubmit: { submissions += 1 })
        let coordinator = NewPiComposerTextView.Coordinator(wrapper)
        let view = NewPiComposerInnerTextView()
        view.isRichText = false
        view.font = .systemFont(ofSize: 13)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        view.textContainer?.containerSize = NSSize(width: 190, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.delegate = coordinator
        coordinator.textView = view
        view.onSubmit = { submissions += 1 }
        view.onRecallHistory = { previous, current in
            calls += 1
            draft.text = current
            return draft.recallHistory(previous: previous, entries: { source })
        }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)

        func setText(_ text: String, caret: Int? = nil) {
            draft.text = text
            coordinator.synchronizeText(text)
            view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
            let character = code == 126 ? "\u{F700}" : "\u{F701}"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        setText("正在写")
        key(126)
        check(view.string == "新输入" && draft.text == view.string, "真实上键同步文本与 Binding")
        key(126)
        check(view.string == "旧输入", "同帧连续上键")
        key(125)
        check(view.string == "新输入", "真实下键")
        key(125)
        check(view.string == "正在写", "真实键盘恢复草稿")
        check(submissions == 0, "方向键不发送")
        key(126)
        view.insertText("改", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        key(125)
        check(view.string == "新输入改", "用户编辑停止浏览")
        key(126)
        key(125)
        check(view.string == "新输入改", "编辑草稿可恢复")
        setText("第一行\n第二行", caret: 5)
        let beforeMiddle = calls
        key(126)
        check(calls == beforeMiddle && view.string == "第一行\n第二行", "第二行上键不取历史")
        setText("第一行\n第二行", caret: 1)
        check(view.isAtHistoryBoundary(previous: true) && !view.isAtHistoryBoundary(previous: false), "首行边界")
        setText("第一行\n第二行")
        check(!view.isAtHistoryBoundary(previous: true) && view.isAtHistoryBoundary(previous: false), "末行边界")
        setText("末尾换行\n")
        check(!view.isAtHistoryBoundary(previous: true) && view.isAtHistoryBoundary(previous: false), "末尾空显示行")
        setText(String(repeating: "自动换行测试", count: 30))
        check(!view.isAtHistoryBoundary(previous: true), "软换行末尾不是首显示行")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        check(view.isAtHistoryBoundary(previous: true) && !view.isAtHistoryBoundary(previous: false), "软换行首显示行")
        setText("选择文字")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        let beforeSelection = calls
        key(126)
        check(calls == beforeSelection, "选区不取历史")
        for flags: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            setText("修饰键")
            let before = calls
            key(126, flags: flags)
            check(calls == before, "修饰键保留系统行为")
        }
        setText("禁用")
        view.isEditable = false
        let beforeDisabled = calls
        key(126)
        check(calls == beforeDisabled, "禁用不取历史")
        view.isEditable = true
        setText("")
        view.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.hasMarkedText(), "组合输入前置条件")
        let beforeMarked = calls
        key(126)
        check(calls == beforeMarked, "组合输入方向键不取历史")
        view.unmarkText()
        setText("保留")
        source = ["多行历史\n下一行"]
        key(126)
        check(view.string == source[0] && view.selectedRange().location == 0, "取回多行后可继续向上浏览")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        key(125)
        check(view.string == "保留", "多行历史末行可恢复草稿")
        check(submissions == 0, "全部历史操作均未发送")
        print("PASS: composer history \(count) checks; no AX/global events or user data")
    }
}