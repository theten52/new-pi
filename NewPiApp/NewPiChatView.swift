import AppKit
import NewPiCore
import SwiftUI

/// 保活容器：把每个缓存会话的面板视图（含彼此内部的 WKWebView）常驻挂载，
/// 切换会话时仅翻转活跃面板的显示/交互，而不销毁重建 —— 这样 DOM、测高、滚动位置
/// 全部免费保留，做到"切换即显示、原位恢复"。被淘汰的会话在 beginSession 冷重建。
struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel

    var body: some View {
        Group {
            if viewModel.keptAliveRuntimes.isEmpty {
                // 未开项目 / 无任何会话时，保留"Open a project / Start a session"引导。
                NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    ForEach(viewModel.keptAliveRuntimes, id: \.sessionID) { runtime in
                        NewPiSessionPanel(runtime: runtime, viewModel: viewModel)
                            .opacity(viewModel.isActiveRuntime(runtime) ? 1 : 0)
                            .allowsHitTesting(viewModel.isActiveRuntime(runtime))
                            .zIndex(viewModel.isActiveRuntime(runtime) ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel.chatNavigationTitle)
    }
}

/// 单个会话的聊天面板：从它自己的 runtime 观察转录/流式状态。
/// 非活跃面板保持挂载（opacity 0），WebView 不销毁；活跃面板完整交互。
struct NewPiSessionPanel: View {
    @ObservedObject var runtime: SessionRuntime
    @ObservedObject var viewModel: NewPiViewModel

    @State private var input = ""
    /// composer 输入框的实测内容高度（由 NewPiComposerTextView 回报，固定 4 行）。
    @State private var composerInputHeight: CGFloat = NewPiComposerScrollView.fallbackHeight
    /// 单文档 transcript 的控制器（jumpTo/scrollToBottom 意图 + JS 上报的 isNearBottom/minimap 位置）。
    @StateObject private var docController = TranscriptDocumentController()

    private var userMessageMarkers: [UserMessageMarker] {
        runtime.transcript
            .filter { $0.kind == .user }
            .map { UserMessageMarker(id: $0.id, preview: $0.body) }
    }

    // 单文档 transcript（BACKLOG-SINGLE-DOC 已完成迁移）：整条会话渲染进一个 WKWebView，
    // 布局/滚动/虚拟化由文档内浏览器引擎自持（原生不消费任何内容高度）；
    // rail（minimap）与 jump-to-latest 是原生浮层（不在流内，不参与布局）。
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                if runtime.transcript.isEmpty {
                    if viewModel.isSwitchingSession {
                        ProgressView("Loading session…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    NewPiTranscriptDocumentView(
                        runtime: runtime,
                        controller: docController,
                        tintHues: turnTintHues(for: runtime.transcript),
                        // 冷启动/切回恢复上次离开的位置（锚点条目 + 行内偏移，offset 兼底）；
                        // 无记录则落底。文档内同步锚定，无「高度未回」中间态。
                        restoreEntry: ScrollPositionStore.shared.entry(for: runtime.sessionID)
                    )
                    .overlay(alignment: .bottom) {
                        if runtime.isStreaming && !docController.isNearBottom {
                            Button {
                                docController.scrollToBottom()
                            } label: {
                                Label("Jump to latest", systemImage: "arrow.down")
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                        }
                    }
                }

                NewPiUserMessageRail(
                    markers: userMessageMarkers,
                    // 单文档路径：JS 上报真实布局位置，rail 升级为按比例分布的 minimap。
                    positions: docController.markerPositions,
                    onSelect: { messageID in
                        docController.jumpTo(messageID)
                    }
                )
                .padding(.trailing, 10)
            }

            chatComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 轮对话色调：只给用户气泡与助手正文卡片传色相，工具/思考卡保持中性色。
    private func turnTintHues(for transcript: [NewPiTranscriptItem]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var currentAnchor: UUID?
        for item in transcript {
            if item.kind == .user {
                currentAnchor = item.id
            }
            guard let anchor = currentAnchor else { continue }
            if item.kind == .user || item.isAssistantMarkdown {
                result[item.id] = Color.bubbleTintHueDegrees(for: anchor)
            }
        }
        return result
    }

    private var chatComposer: some View {
        VStack(spacing: 0) {
            // 分隔线移到状态栏上方：状态栏与输入框之间不再隔开，视觉上连成一体。
            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                // 状态栏 + 输入框同一列：状态栏宽度 = 输入框宽度，上下左右边缘对齐
                //（按钮在外层 HStack，不再挤占输入框宽度）。
                VStack(spacing: 8) {
                    NewPiAgentStatusBar(
                        presentation: viewModel.agentStatusPresentation,
                        usageText: runtime.totalUsage.newPiCompactText,
                        lastTurnUsageText: runtime.lastTurnUsage.newPiCompactText,
                        cacheHitRateText: runtime.totalUsage.newPiCacheHitRateText,
                        modelPicker: NewPiModelPickerMenu(
                            groups: viewModel.providerModelGroups,
                            activeProfileID: viewModel.activeProviderID,
                            activeModelID: viewModel.activeProviderModel,
                            isDisabled: runtime.isStreaming,
                            onSelect: { profileID, modelID in
                                Task { await viewModel.switchModel(profileID: profileID, modelID: modelID) }
                            }
                        )
                    )

                    // 多行输入框（NSTextView）：真实多行、自动增高，
                    // Return 发送 / Shift+Return 换行（BACKLOG-COMPOSER-MULTILINE）。
                    NewPiComposerTextView(
                        text: $input,
                        isDisabled: runtime.isStreaming,
                        placeholder: "Message NewPi…",
                        onSubmit: sendComposerInput,
                        onHeightChange: { newHeight in
                            guard abs(composerInputHeight - newHeight) > 0.5 else { return }
                            composerInputHeight = newHeight
                        }
                    )
                    .frame(height: composerInputHeight)
                    // 高亮：与状态栏一致的淡 accent 填充 + 描边。
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                }

                Button("Stop") {
                    viewModel.abort()
                }
                .opacity(runtime.isStreaming ? 1 : 0)
                .disabled(!runtime.isStreaming)
                .frame(minWidth: 52)

                // Return 发送由 composer 自身处理，按钮不再占用 Return 快捷键，
                // 避免与 NSTextView 的按键处理双重触发。
                Button("Send", action: sendComposerInput)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime.isStreaming)
            }
            .padding(.top, 8)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(nil, value: runtime.isStreaming)
    }

    private func sendComposerInput() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !runtime.isStreaming else { return }
        input = ""
        viewModel.send(text)
        // 发送 = 明确要看最新内容的意图（聊天应用惯例）：显式钉底，
        // 否则用户停在中部时，流式输出按保锚纪律不跟随（看起来像没反应）。
        docController.scrollToBottom()
    }
}

// MARK: - Multiline composer (NSTextView)

/// 多行输入框：基于 NSTextView，支持真实多行输入、随内容自动增高（达上限后滚动），
/// Return 发送 / Shift+Return 换行。替代原先近似单行的 TextField(axis: .vertical)。
struct NewPiComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isDisabled: Bool = false
    var placeholder: String = "Message NewPi…"
    var onSubmit: () -> Void = {}
    /// 内容高度变化回调：外层据此用 .frame(height:) 精确控制高度，
    /// 不依赖 intrinsicContentSize（NSScrollView hugging 优先级低，会被 VStack 拉伸）。
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NewPiComposerScrollView {
        let scrollView = NewPiComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NewPiComposerInnerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NewPiComposerScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder
        textView.isEditable = !isDisabled
        textView.textColor = isDisabled ? .disabledControlTextColor : .textColor
        // 发送后外部把 text 清空：同步回 textView（guard 防止打字途中回写打断输入）。
        if textView.string != text {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
        scrollView.invalidateIntrinsicContentSize()
        // 首次布局 / 宽度变化后重报高度。异步避免在 view update 周期内改 @State。
        let report = onHeightChange
        DispatchQueue.main.async {
            let height = scrollView.measuredContentHeight
            if height > 0 { report(height) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NewPiComposerTextView
        weak var textView: NewPiComposerInnerTextView?

        init(_ parent: NewPiComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // 内容行数变化 → 重新测量高度，驱动 composer 自动增高。
            if let scrollView = textView.enclosingScrollView as? NewPiComposerScrollView {
                scrollView.invalidateIntrinsicContentSize()
                parent.onHeightChange(scrollView.measuredContentHeight)
            }
        }
    }
}

/// 自适应高度的 ScrollView：高度由内容行数决定，夹在 [单行, 4 行] 之间。
final class NewPiComposerScrollView: NSScrollView {
    /// 最多显示 4 行，超出后内部滚动。
    var maxVisibleLines: CGFloat = 4
    /// 布局未就绪时的兜底高度（4 行：13pt 字体约 16pt/行 + 内边距 14pt）。
    static let fallbackHeight: CGFloat = 78

    /// 当前内容应有的高度（默认 4 行，超出 4 行后内部滚动）。
    var measuredContentHeight: CGFloat {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              container.size.width > 0 else {
            return Self.fallbackHeight
        }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height
        let insets = textView.textContainerInset
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let fourLines = lineHeight * maxVisibleLines + insets.height * 2
        let contentHeight = usedHeight + insets.height * 2
        // 下限=上限=4 行：空输入也保持 4 行高，内容超出后滚动。
        return ceil(min(max(contentHeight, fourLines), fourLines))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredContentHeight)
    }
}

/// 支持占位提示与 Return 发送（Shift+Return 换行）的 NSTextView。
final class NewPiComposerInnerTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / 小键盘 Enter
        // IME 组词中（如拼音选词确认）不拦截 Return；Shift+Return 换行。
        if isReturn, !hasMarkedText(), !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + 5,
            y: inset.height,
            width: bounds.width - inset.width * 2 - 10,
            height: bounds.height - inset.height * 2
        )
        (placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }
}

#Preview {
    NewPiChatView(viewModel: NewPiViewModel())
}
