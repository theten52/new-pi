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
