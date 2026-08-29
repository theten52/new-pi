import Foundation

/// Feature flags（BACKLOG-SINGLE-DOC）。迁移期新旧实现并行，flag 可切；
/// 生命周期有硬上限——Phase 2 结束即删旧路径（见 docs/ui-architecture-decision.md §4.3）。
enum NewPiFeatureFlags {
    private static let singleDocumentKey = "ui.singleDocumentTranscript"

    /// 单文档 transcript：整条会话渲染进一个 WKWebView（浏览器持布局/滚动权）。
    /// 默认 false（遗留 per-message 路径）。菜单 Help → Single-Document Transcript 切换。
    static var singleDocumentTranscript: Bool {
        get { UserDefaults.standard.bool(forKey: singleDocumentKey) }
        set { UserDefaults.standard.set(newValue, forKey: singleDocumentKey) }
    }
}
