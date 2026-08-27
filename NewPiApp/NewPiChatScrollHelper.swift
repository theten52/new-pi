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
struct ChatBottomAnchorPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
