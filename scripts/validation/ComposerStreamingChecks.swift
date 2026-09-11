import AppKit
import SwiftUI

@MainActor
final class ComposerProbeModel: ObservableObject {
    @Published var tick = 0
    @Published var clear = 0
    @Published var replacement = ""
    @Published var disabled = false
    @Published var running = false
    var draft = ""
    var submitted = ""
    var acceptsSend = true
}

struct ComposerProbeView: View {
    @ObservedObject var model: ComposerProbeModel
    @State private var input = ""
    var body: some View {
        VStack {
            Text("Thinking update \(model.tick)")
            NewPiComposerTextView(text: $input, isDisabled: model.disabled, onSubmit: {
                guard !model.running else { return }
                model.submitted = input
                if model.acceptsSend { input = "" }
            })
                .frame(height: NewPiComposerScrollView.fixedHeight)
        }
        .onChange(of: input) { _, value in model.draft = value }
        .onChange(of: model.clear) { _, _ in input = "" }
        .onChange(of: model.replacement) { _, value in input = value }
        .frame(width: 700, height: 200)
    }
}

@main
struct ComposerStreamingChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let model = ComposerProbeModel()
        let host = NSHostingController(rootView: ComposerProbeView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard let textView = findTextView(host.view) else { fatalError("missing composer") }
            window.makeFirstResponder(textView)
            textView.insertText("Existing draft ", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(50))
            let plain = textView.string
            for _ in 0..<20 {
                model.tick += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            precondition(textView.string == plain && model.draft == plain)
            // 光标在文本中间时，输出更新也不能移动选区。
            textView.setSelectedRange(NSRange(location: 3, length: 4))
            for _ in 0..<10 {
                model.tick += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            precondition(textView.selectedRange() == NSRange(location: 3, length: 4))
            textView.setSelectedRange(NSRange(location: (plain as NSString).length, length: 0))
            print("PASS: plain text and selection preserved")
            textView.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = textView.string
            let markedRange = textView.markedRange()
            print("before-composition-refresh text=\(marked) marked=\(textView.hasMarkedText()) model=\(model.draft)")
            for _ in 0..<20 {
                model.tick += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            let preserved = textView.string == marked && textView.hasMarkedText() && textView.markedRange() == markedRange
            print("composition-preserved=\(preserved) text=\(textView.string) model=\(model.draft)")
            if ProcessInfo.processInfo.environment["NEWPI_EXPECT_DRAFT_FIX"] == "1" { precondition(preserved) }
            textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(for: .milliseconds(50))
            print("committed=\(textView.string) model=\(model.draft)")
            precondition(textView.string == plain + "中文" && model.draft == textView.string)
            let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            textView.keyDown(with: submit)
            precondition(model.submitted == plain + "中文", "Return must submit the committed draft")
            model.clear += 1
            try? await Task.sleep(for: .milliseconds(50))
            precondition(textView.string.isEmpty && model.draft.isEmpty, "explicit clear must still work")
            if ProcessInfo.processInfo.environment["NEWPI_EXPECT_DRAFT_FIX"] == "1" {
                // 空草稿开始的多次组词，是用户看到“全部消失”的场景。
                for _ in 0..<3 {
                    textView.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
                    for _ in 0..<20 {
                        model.tick += 1
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    precondition(textView.string == "nihao" && textView.hasMarkedText())
                    textView.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
                    try? await Task.sleep(for: .milliseconds(30))
                    precondition(model.draft == "你好")
                    model.clear += 1
                    try? await Task.sleep(for: .milliseconds(30))
                    precondition(textView.string.isEmpty)
                }
                model.replacement = "restored draft"
                try? await Task.sleep(for: .milliseconds(30))
                precondition(textView.string == "restored draft")
                textView.insertText("1\n2\n3\n4\n5", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
                try? await Task.sleep(for: .milliseconds(30))
                model.tick += 1
                try? await Task.sleep(for: .milliseconds(30))
                precondition(model.draft == "1\n2\n3\n4\n5" && textView.string == model.draft)
                precondition(textView.enclosingScrollView?.frame.height == 78)
                precondition(textView.frame.height > 78, "Five lines must scroll inside the fixed viewport")
                model.disabled = true
                try? await Task.sleep(for: .milliseconds(30))
                precondition(!textView.isEditable && textView.string == model.draft)
                model.disabled = false
                try? await Task.sleep(for: .milliseconds(30))
                precondition(textView.isEditable && textView.string == model.draft)
                model.clear += 1
                try? await Task.sleep(for: .milliseconds(30))
                textView.insertText("quick send", replacementRange: NSRange(location: NSNotFound, length: 0))
                // 同一个 run-loop 内打字后立刻发送，SwiftUI 可能合并中间草稿值。
                textView.keyDown(with: submit)
                try? await Task.sleep(for: .milliseconds(50))
                precondition(model.submitted == "quick send" && textView.string.isEmpty, "Coalesced send must clear native editor")
                model.acceptsSend = false
                textView.insertText("rejected draft", replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.keyDown(with: submit)
                model.tick += 1
                try? await Task.sleep(for: .milliseconds(50))
                precondition(model.draft == "rejected draft" && textView.string == model.draft)
                // 正在运行只阻止发送，不禁用下一条草稿；Return 不得清空它。
                model.running = true
                model.acceptsSend = true
                let lastSubmission = model.submitted
                textView.insertText(" next", replacementRange: NSRange(location: NSNotFound, length: 0))
                textView.keyDown(with: submit)
                for _ in 0..<20 {
                    model.tick += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
                precondition(textView.isEditable && model.submitted == lastSubmission)
                precondition(textView.string == "rejected draft next" && model.draft == textView.string)
                model.running = false
                try? await Task.sleep(for: .milliseconds(30))
                textView.keyDown(with: submit)
                try? await Task.sleep(for: .milliseconds(50))
                precondition(model.submitted == "rejected draft next" && textView.string.isEmpty)
                print("PASS: drafting while running, rejected Return preserves draft, sending after completion")
                print("PASS: repeated empty-draft composition, commit, submit, rejection preservation, disabled state, external clear/restore and fixed-height scrolling")
            }
            window.orderOut(nil)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fatalError("composer test timeout") }
        NSApp.run()
    }

    @MainActor static func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let found = findTextView(child) { return found } }
        return nil
    }
}
