import SwiftUI

private enum NewPiChatScrollAnchor {
    static let bottom = "chat-scroll-bottom"
}

enum NewPiChatScrollSupport {
    static let bottomAnchorID = NewPiChatScrollAnchor.bottom
    static let coordinateSpaceName = "new-pi-chat-scroll"
}

struct ComposerHeightPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 底部锚点在聊天滚动坐标系中的 minY，用于判断视口是否贴近底部。
/// （rail 跳转目标行的 minY 不再用 PreferenceKey 上报：LazyVStack 惰性容器内的
/// preference 不向父级传播，改为行内 GeometryReader 的 onChange 直接写回面板状态，
/// 见 NewPiSessionPanel。）
struct ChatBottomAnchorPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 会话滚动位置持久化：切回被淘汰会话 / App 重启后恢复到上次离开的位置。
/// 主键是「锚点行 + 行内偏移」而非绝对 offset——恢复时几何可能尚未长全
///（预热未完成、cache-miss 行还是估算高度），绝对 offset 会被钳制丢失；
/// 锚点行在几何变化后重算，始终定位到同一条消息。绝对 offset 仅作兜底。
@MainActor
final class ScrollPositionStore {
    static let shared = ScrollPositionStore()

    struct Entry: Codable {
        /// 离开时视口顶部的消息行 ID（nil = 旧格式，只有绝对 offset）。
        var rowID: String?
        /// 行内偏移：offset 与该行顶部的差值。
        var delta: Double
        /// 兜底：绝对滚动 offset。
        var offset: Double
    }

    private var entries: [String: Entry] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let fileURL: URL

    private init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".new-pi/agent/scroll-positions.json")
        load()
        // 退出前强制落盘：滚动写入是 2s 防抖的，退出前最后一段滚动不刷盘，
        // 冷启动恢复会拿到旧位置。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveWorkItem?.cancel()
                self?.saveNow()
            }
        }
    }

    func entry(for sessionID: UUID) -> Entry? {
        entries[sessionID.uuidString]
    }

    /// 滚动期间每帧都可能调用：只更新内存表，磁盘写入防抖 2s。
    func set(_ sessionID: UUID, rowID: UUID?, delta: CGFloat, offset: CGFloat) {
        entries[sessionID.uuidString] = Entry(
            rowID: rowID?.uuidString,
            delta: Double(delta),
            offset: Double(offset)
        )
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
            return
        }
        // 兼容旧格式 [sessionID: offset]（一次迁移）。
        if let legacy = try? JSONDecoder().decode([String: Double].self, from: data) {
            entries = legacy.mapValues { Entry(rowID: nil, delta: 0, offset: $0) }
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
