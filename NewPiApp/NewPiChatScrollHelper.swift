import AppKit
import SwiftUI

@MainActor
final class NewPiChatScrollController {
    static let shared = NewPiChatScrollController()

    private weak var anchorView: NSView?
    private var followTask: Task<Void, Never>?
    private var lastFollowTime = Date.distantPast

    private let minFollowInterval: TimeInterval = 0.15
    private let bottomTolerance: CGFloat = 16

    private init() {}

    func registerAnchor(_ view: NSView) {
        anchorView = view
    }

    func requestFollow() {
        followTask?.cancel()

        let elapsed = Date().timeIntervalSince(lastFollowTime)
        let delay = max(0, minFollowInterval - elapsed)

        followTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            scrollToBottomIfNeeded()
            lastFollowTime = Date()
        }
    }

    func scrollToBottomImmediately() {
        followTask?.cancel()
        scrollToBottomIfNeeded(force: true)
        lastFollowTime = Date()
    }

    private func scrollToBottomIfNeeded(force: Bool = false) {
        guard let view = anchorView,
              let scrollView = view.enclosingScrollView,
              let documentView = scrollView.documentView else {
            return
        }

        documentView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let documentHeight = documentView.bounds.height
        let targetY = max(0, documentHeight - visibleHeight)
        let currentY = clipView.bounds.origin.y

        if !force, targetY - currentY <= bottomTolerance {
            return
        }

        clipView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

struct NewPiChatScrollAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        NewPiChatScrollController.shared.registerAnchor(nsView)
    }
}
