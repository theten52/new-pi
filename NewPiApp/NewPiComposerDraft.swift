import Combine
import Foundation

/// 输入草稿由运行时持有、由输入面板独立观察，不随详情视图重建丢失。
/// 仅驻内存：不进入 transcript、不触发模型请求，也不转发到运行时/根列表的通知。
/// 运行时释放（Session 淘汰、切项目、聊天室删除、退出 App）时一同释放。
@MainActor
final class NewPiComposerDraft: ObservableObject {
    @Published var text = "" {
        didSet {
            if text != oldValue, !isRecallingHistory { resetHistory() }
        }
    }
    @Published var attachments: [DraftImageAttachment] = []
    /// 焦点请求随草稿存活；填建议的既有 VM 调用也能唤醒对应输入框。
    @Published private(set) var focusRequest: UUID?
    @Published var isComposing = false
    private final class AttachmentDelivery {
        weak var destination: NewPiComposerDraft?
    }
    private var attachmentDelivery = AttachmentDelivery()

    func requestFocus() { focusRequest = UUID() }

    /// 异步图片解码可能晚于空态→会话交接；只转交给已明确接收此草稿的对象。
    func appendAttachments(_ values: [DraftImageAttachment]) {
        attachments.append(contentsOf: values)
    }

    func attachmentReceiver() -> ([DraftImageAttachment]) -> Void {
        let delivery = attachmentDelivery
        return { [self] values in
            (delivery.destination ?? self).appendAttachments(values)
        }
    }

    @discardableResult
    func transfer(to destination: NewPiComposerDraft) -> Bool {
                guard destination !== self, !text.isEmpty || !attachments.isEmpty,
              destination.text.isEmpty, destination.attachments.isEmpty,
              !isComposing else { return false }
        destination.text = text
        destination.attachments = attachments
        text = ""
        attachments = []
        attachmentDelivery.destination = destination
        attachmentDelivery = AttachmentDelivery()
        destination.requestFocus()
        return true
    }

    private var history: [String] = []
    private var historyIndex: Int?
    private var savedText = ""
    private var isRecallingHistory = false

    /// 每次进入浏览时固定当前会话历史；只取文字，附件保持原样，不触发发送。
    /// 文本被编辑/发送清空后退出浏览；运行中追加消息不改变正在浏览的索引。
    func recallHistory(previous: Bool, entries: () -> [String]) -> String? {
        if historyIndex == nil {
            guard previous else { return nil }
            history = entries().filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !history.isEmpty else { return nil }
            savedText = text
            historyIndex = history.count
        }
        guard let index = historyIndex else { return nil }
        let next = previous ? max(0, index - 1) : index + 1
        let restored = next >= history.count
        let value = restored ? savedText : history[next]
        isRecallingHistory = true
        text = value
        isRecallingHistory = false
        if restored { resetHistory() } else { historyIndex = next }
        return value
    }

    private func resetHistory() {
        history = []
        historyIndex = nil
        savedText = ""
    }

    /// 建议只进入空草稿，不覆盖文本、图片或触发发送。
    @discardableResult
    func fillSuggestion(_ prompt: String) -> Bool {
        guard text.isEmpty, attachments.isEmpty, !isComposing, !prompt.isEmpty else { return false }
        text = prompt
        requestFocus()
        return true
    }
}