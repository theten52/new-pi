import AppKit
import Foundation

/// 转录高度表：会话面板的**布局数据源**（手动窗口化）兼 rail 定位表。
///
/// 设计依据（rail 三轮未收敛的最终根因）：LazyVStack 对未实例化行用内部估算占位，
/// 任何"算好 y 再跳"的方案都不可能精确——所以把布局几何整体收归本表：
/// 可见区外的行一律用表内精确高度画 Color.clear 占位，SwiftUI 不再做任何估算。
///
/// 高度来源：
/// - Markdown 行（NewPi/Summary）：`MarkdownRenderingCache` 实测缓存（预热全量化后全覆盖）；
/// - You 气泡 / 纯文本行：字体 × 宽度纯函数估算（误差 ±2–4pt，实例化实测回报后修正）；
/// - 工具行：折叠态固定高（展开后由实测回报修正）。
///
/// 行实例化后通过 `updateMeasured` 回报实测高度：更新表 + 前缀和，占位随之精确化。
@MainActor
final class TranscriptHeightMap: ObservableObject {
    struct Row: Equatable {
        let id: UUID
        var height: CGFloat
        /// 是否已实测（实例化后回报）。实测值优先于一切估算。
        var measured: Bool
        /// 文本类行的行高缓存 key/宽度（实测后持久化，跨启动精确；md 行走 WebView 管线自带缓存，不用此通道）。
        var cacheKey: String?
        var cacheWidth: CGFloat?
    }

    @Published private(set) var rows: [Row] = []
    /// prefixSums[i] = 第 i 行之前所有行的 (height + rowSpacing) 总和，
    /// 即第 i 行顶部在行堆栈内的 y（行堆栈从 0 起，不含内容 padding）。count = rows.count + 1。
    @Published private(set) var prefixSums: [CGFloat] = [0]

    // MARK: - 布局常量（与 NewPiChatView / NewPiTranscriptRow 实际布局对齐）

    /// 行间距（行堆栈 VStack spacing）。
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
    /// You 气泡左侧 Spacer 最小宽度。
    private static let bubbleLeadingSpacer: CGFloat = 72
    /// 助手/文本行最大正文宽度（assistantContent maxWidth 760）。
    private static let plainMaxTextWidth: CGFloat = 760
    /// 工具行折叠态高度（headerRow 一行 + 垂直 padding 20 + 圆角边框）。
    private static let toolRowCollapsedHeight: CGFloat = 42
    /// 正文/字体系：SwiftUI .body ≈ NSFont 13pt。
    private static var bodyFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }

    // MARK: - 构建

    /// 按当前 transcript 全量重建（rail 点击 / transcript 变化 / 宽度变化 / 缓存版本变化时调用）。
    /// 已实测的行保留实测值（重建只刷新估算行的来源数据）。
    func rebuild(items: [NewPiTranscriptItem], contentWidth: CGFloat) {
        let plainWidth = min(Self.plainMaxTextWidth, max(80, contentWidth))
        let bubbleWidth = min(Self.bubbleMaxTextWidth, max(80, contentWidth - Self.bubbleLeadingSpacer - 24))
        let oldByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        rows = items.map { item in
            if let old = oldByID[item.id], old.measured {
                return old
            }
            return estimateRow(item: item, plainWidth: plainWidth, bubbleWidth: bubbleWidth)
        }
        recomputePrefixSums()
    }

    // MARK: - 实测回报

    /// 行实例化后回报实测高度：就地更新（已实测的行允许跟随内容变化，如流式/工具展开）；
    /// 文本类行的行高同时持久化（跨启动精确，二次 rail 点击永远命中真实值）。
    func updateMeasured(id: UUID, height: CGFloat) {
        guard height > 1, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        guard abs(rows[index].height - height) > 0.5 else { return }
        rows[index].height = height
        rows[index].measured = true
        recomputePrefixSums()
        if let key = rows[index].cacheKey, let width = rows[index].cacheWidth {
            MarkdownRenderingCache.shared.setHeight(height, width: width, for: key, updateActiveWidth: false, engineDependent: false)
        }
    }

    // MARK: - 定位与窗口

    /// 目标行顶部在滚动内容坐标系中的 y（= scrollTo(point:) 目标）。
    func offset(of id: UUID) -> CGFloat? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return Self.contentTopPadding + prefixSums[index]
    }

    /// 给定滚动偏移，返回视口顶部的锚点行（最后一个顶部 ≤ offset 的行）及其行内偏移。
    /// 供原位恢复保存「锚点 + 偏移」，几何变化后按锚点重算仍指向同一条消息。
    func anchor(at scrollOffset: CGFloat) -> (id: UUID, delta: CGFloat)? {
        guard !rows.isEmpty else { return nil }
        var index = 0
        for i in rows.indices {
            let top = Self.contentTopPadding + prefixSums[i]
            if top <= scrollOffset + 1 { index = i } else { break }
        }
        let top = Self.contentTopPadding + prefixSums[index]
        return (rows[index].id, scrollOffset - top)
    }

    /// 所有行的总占用高度（含行间距，不含内容 padding）。
    var totalRowsHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        return prefixSums[rows.count] - Self.rowSpacing
    }

    /// 第 lo 行之前的占位高度（含其间距；lo = 0 时无需占位）。
    func placeholderHeight(before lo: Int) -> CGFloat {
        lo > 0 ? max(0, prefixSums[lo] - Self.rowSpacing) : 0
    }

    /// 第 hi 行之后的占位高度（含其间距；hi 是最后一行时无需占位）。
    func placeholderHeight(after hi: Int) -> CGFloat {
        let n = rows.count
        guard hi < n - 1 else { return 0 }
        return max(0, (prefixSums[n] - prefixSums[hi + 1]) - Self.rowSpacing)
    }

    /// 可见窗口（上下各 1 屏过扫）：返回应实例化的行索引范围。
    func window(scrollOffset: CGFloat, viewportHeight: CGFloat) -> Range<Int> {
        guard !rows.isEmpty, viewportHeight > 0 else { return 0..<0 }
        // 行堆栈坐标系：滚出 16pt 内容 padding。
        let top = scrollOffset - Self.contentTopPadding - viewportHeight
        let bottom = scrollOffset - Self.contentTopPadding + viewportHeight * 2
        var lo = 0
        var hi = rows.count - 1
        // prefixSums[i+1] 是第 i 行底部；找第一个底部 > top 的行。
        while lo < rows.count - 1, prefixSums[lo + 1] <= top { lo += 1 }
        // 找最后一个顶部 < bottom 的行。
        while hi > 0, prefixSums[hi] >= bottom { hi -= 1 }
        return lo..<(hi + 1)
    }

    // MARK: - 内部

    private func recomputePrefixSums() {
        var sums = [CGFloat](repeating: 0, count: rows.count + 1)
        for (index, row) in rows.enumerated() {
            sums[index + 1] = sums[index] + row.height + Self.rowSpacing
        }
        prefixSums = sums
    }

    private func estimateRow(item: NewPiTranscriptItem, plainWidth: CGFloat, bubbleWidth: CGFloat) -> Row {
        if item.isToolTranscript {
            return Row(id: item.id, height: Self.toolRowCollapsedHeight, measured: false)
        }
        if item.isAssistantMarkdown {
            let contentHeight = MarkdownRenderingCache.shared.height(for: item.body) ?? 44
            return Row(id: item.id, height: Self.headerHeight + Self.headerBodyGap + contentHeight, measured: false)
        }
        // 文本类行：先查行高缓存（实测持久化），未命中再用字体×宽度纯函数估算。
        // 流式中的 thinking 行内容持续增长，不写行高缓存（避免中间态高度污染持久化缓存）。
        let isBubble = item.isUser
        let key = "rowh|\(item.title)|\(item.body)"
        let width = isBubble ? bubbleWidth : plainWidth
        if !item.isStreamingThinking,
           let cached = MarkdownRenderingCache.shared.height(for: key, width: width) {
            return Row(id: item.id, height: cached, measured: true, cacheKey: key, cacheWidth: width)
        }
        let textHeight = Self.measureTextHeight(item.body, maxWidth: width)
        let total = isBubble
            ? Self.bubbleVerticalPadding + Self.headerHeight + Self.headerBodyGap + textHeight
            : Self.headerHeight + Self.headerBodyGap + textHeight
        return Row(
            id: item.id,
            height: total,
            measured: false,
            cacheKey: item.isStreamingThinking ? nil : key,
            cacheWidth: item.isStreamingThinking ? nil : width
        )
    }

    /// 文本在给定宽度下的换行高度（与 SwiftUI Text(.body) 排版近似，
    /// 残差由行实例化后的实测回报吸收）。
    private static func measureTextHeight(_ text: String, maxWidth: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: bodyFont])
        let rect = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}
