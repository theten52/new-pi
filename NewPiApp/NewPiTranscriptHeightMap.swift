import AppKit
import Foundation

/// rail 跳转定位的高度表：每行高度都有**确定性来源**，点击 rail = 前缀和算出目标行
/// 内容 y → `scrollTo(point:)` 一次到位。
///
/// 替代已删除的 ChatScrollCoordinator 收敛机制（依赖目标行异步实例化 + 异步实测，
/// 三轮未收敛；见 docs/dev-notes/rail-jump-fix-status.md 与 chat-scroll-layout.md §3.11）。
///
/// 高度来源（按行类型）：
/// - Markdown 行（NewPi/Summary）：`MarkdownRenderingCache`（预热全量化后基本全覆盖）；
///   缓存高度是 WebView 内容高，行总高 = 行头 + 间距 + 内容高。
/// - You 气泡 / 纯文本行：字体 × 宽度纯函数计算（布局常量与 NewPiTranscriptRow 对齐）。
/// - 工具行：折叠态固定高（展开态由行实例化后实测回报修正）。
/// - 未知：fallback 估算。
///
/// 行实例化后通过 `updateMeasured` 回报实测高度，**只更新表**（数据自校正），
/// 不再触发二次滚动——下一次点击自然用更准的数据。
@MainActor
final class TranscriptHeightMap {
    struct Row {
        let id: UUID
        var height: CGFloat
        /// 是否已实测（实例化后回报）。实测值优先于一切估算。
        var measured: Bool
    }

    private(set) var rows: [Row] = []

    // MARK: - 布局常量（与 NewPiChatView / NewPiTranscriptRow 实际布局对齐）

    /// LazyVStack 行间距。
    static let rowSpacing: CGFloat = 12
    /// 内容 VStack 顶部 padding（.padding() 全边 16）。
    static let contentTopPadding: CGFloat = 16
    /// 行头（标题 + hover 按钮行）高度估值。
    private static let headerHeight: CGFloat = 17
    /// 行头与正文的间距（VStack spacing: 6）。
    private static let headerBodyGap: CGFloat = 6
    /// You 气泡内边距（padding(12) 上下各 12）。
    private static let bubbleVerticalPadding: CGFloat = 24
    /// You 气泡正文最大宽度：气泡 maxWidth 640 - 水平 padding 24。
    private static let bubbleMaxTextWidth: CGFloat = 616
    /// 助手/文本行最大正文宽度（assistantContent maxWidth 760）。
    private static let plainMaxTextWidth: CGFloat = 760
    /// 工具行折叠态高度（headerRow 一行 + 垂直 padding 20 + 圆角边框）。
    private static let toolRowCollapsedHeight: CGFloat = 42
    /// 正文/字体系：SwiftUI .body ≈ NSFont 13pt。
    private static var bodyFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }

    // MARK: - 构建

    /// 按当前 transcript 全量重建（点击 rail 时调用，永远用最新缓存数据）。
    /// md 行高度直接读缓存——预热全量化后基本全部命中。
    func rebuild(items: [NewPiTranscriptItem], contentWidth: CGFloat) {
        let plainWidth = min(Self.plainMaxTextWidth, max(80, contentWidth))
        let bubbleWidth = min(Self.bubbleMaxTextWidth, max(80, contentWidth - 72))
        rows = items.map { item in
            Row(id: item.id, height: estimate(item: item, plainWidth: plainWidth, bubbleWidth: bubbleWidth), measured: false)
        }
    }

    // MARK: - 实测回报

    /// 行实例化后回报实测高度，就地更新（不触发任何滚动）。
    func updateMeasured(id: UUID, height: CGFloat) {
        guard height > 1, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].height = height
        rows[index].measured = true
    }

    // MARK: - 定位

    /// 目标行顶部在内容坐标系中的 y（= scrollTo(point:) 目标）。
    func offset(of id: UUID) -> CGFloat? {
        var y = Self.contentTopPadding
        for row in rows {
            if row.id == id { return y }
            y += row.height + Self.rowSpacing
        }
        return nil
    }

    // MARK: - 行高估算

    private func estimate(item: NewPiTranscriptItem, plainWidth: CGFloat, bubbleWidth: CGFloat) -> CGFloat {
        if item.isToolTranscript {
            return Self.toolRowCollapsedHeight
        }
        if item.title == "NewPi" || item.title == "Summary" {
            let contentHeight = MarkdownRenderingCache.shared.height(for: item.body) ?? 44
            return Self.headerHeight + Self.headerBodyGap + contentHeight
        }
        if item.title == "You" {
            let textHeight = Self.measureTextHeight(item.body, maxWidth: bubbleWidth)
            return Self.bubbleVerticalPadding + Self.headerHeight + Self.headerBodyGap + textHeight
        }
        // Error / 其他纯文本行
        let textHeight = Self.measureTextHeight(item.body, maxWidth: plainWidth)
        return Self.headerHeight + Self.headerBodyGap + textHeight
    }

    /// 文本在给定宽度下的换行高度（与 SwiftUI Text(.body) 的排版的近似，
    /// 误差由行实例化后的实测回报吸收）。
    private static func measureTextHeight(_ text: String, maxWidth: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: bodyFont])
        let rect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}
