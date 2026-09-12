import Combine
import Foundation

/// 输入草稿由运行时持有、由输入面板独立观察，不随详情视图重建丢失。
/// 仅驻内存：不进入 transcript、不触发模型请求，也不转发到运行时/根列表的通知。
/// 运行时释放（Session 淘汰、切项目、聊天室删除、退出 App）时一同释放。
@MainActor
final class NewPiComposerDraft: ObservableObject {
    @Published var text = ""
    @Published var attachments: [DraftImageAttachment] = []

    /// 建议只进入空草稿，不覆盖文本、图片或触发发送。
    @discardableResult
    func fillSuggestion(_ prompt: String) -> Bool {
        guard text.isEmpty, attachments.isEmpty, !prompt.isEmpty else { return false }
        text = prompt
        return true
    }
}