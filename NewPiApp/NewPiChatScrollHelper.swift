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
/// 高度表使内容几何跨启动确定，因此一个 offset 数值即可精确恢复。
@MainActor
final class ScrollPositionStore {
    static let shared = ScrollPositionStore()

    private var offsets: [String: Double] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let fileURL: URL

    private init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".new-pi/agent/scroll-positions.json")
        load()
    }

    func offset(for sessionID: UUID) -> CGFloat? {
        offsets[sessionID.uuidString].map { CGFloat($0) }
    }

    /// 滚动期间每帧都可能调用：只更新内存表，磁盘写入防抖 2s。
    func set(_ sessionID: UUID, offset: CGFloat) {
        offsets[sessionID.uuidString] = Double(offset)
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        offsets = decoded
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
