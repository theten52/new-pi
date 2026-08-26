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
