import AppKit
import NewPiCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// 待发送的图片草稿（附件按钮 / 拖拽 / 粘贴采集；发送时随文本一起落盘，BACKLOG-IMAGE-INPUT）。
    @State private var draftAttachments: [DraftImageAttachment] = []
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
            HStack(spacing: 8) {
                Text("会话")
                    .font(.caption.weight(.medium))
                Image(systemName: "folder")
                Text(viewModel.projectURL?.path ?? "未选择项目")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.projectURL?.path ?? "未选择项目")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }

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
                        transcript: runtime.transcript,
                        isStreaming: runtime.isStreaming,
                        streamingBubbleComplete: runtime.streamingBubbleComplete,
                        storeKey: runtime.sessionID,
                        controller: docController,
                        isVisible: viewModel.isActiveRuntime(runtime),
                        tintHues: NewPiViewModel.transcriptTintHues(for: runtime.transcript),
                        // 冷启动/切回恢复上次离开的位置（锚点条目 + 行内偏移，offset 兼底）；
                        // 无记录则落底。文档内同步锚定，无「高度未回」中间态。
                        restoreEntry: ScrollPositionStore.shared.entry(for: runtime.sessionID),
                        onFork: { index in
                            Task { await viewModel.forkFromMessage(index: index) }
                        }
                    )
                    .overlay(alignment: .bottom) {
                        // 常驻挂载 + 透明度开关（STREAMING-LAYOUT-ISOLATION）：条件插入/移除
                        // 会在流式中途制造结构性布局失效并向 WKWebView 子树传播；
                        // 恒定结构 + opacity 翻转零布局成本，动画观感与原 transition 等价。
                        let jumpVisible = !docController.isNearBottom
                        Button {
                            docController.scrollToBottom()
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
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
                        .opacity(jumpVisible ? 1 : 0)
                        .allowsHitTesting(jumpVisible)
                        .animation(.easeInOut(duration: 0.15), value: jumpVisible)
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
        .background(NewPiWorkbenchStyle.surface)
        .onAppear {
            // 流式直连通道（STREAMING-LAYOUT-ISOLATION）：runtime ↔ 本面板控制器结对。
            // keep-alive 常驻挂载 → 绑定全程有效；面板淘汰时 webview 同亡，弱引用自动清零。
            runtime.docController = docController
            if let latency = runtime.latencyTrace {
                docController.beginLatencyTrace(latency, firstTextItemID: runtime.latencyFirstTextItemID)
            }
        }
        .onDisappear {
            docController.setVisible(false)
            docController.endLiveApply()
            if runtime.docController === docController {
                if let live = runtime.liveTranscript {
                    runtime.transcript = live
                    runtime.liveTranscript = nil
                }
                runtime.docController = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 轮对话色调已上移为 NewPiViewModel.transcriptTintHues（流式直连路径共用）。

    private var chatComposer: some View {
        VStack(spacing: 6) {
            NewPiAgentStatusBar(
                presentation: viewModel.agentStatusPresentation,
                usageText: runtime.totalUsage.newPiCompactText,
                lastTurnUsageText: runtime.lastTurnUsage.newPiCompactText,
                cacheHitRateText: runtime.totalUsage.newPiCacheHitRateText,
                contextText: viewModel.contextUsageText(for: runtime.lastTurnUsage),
                tokenRateText: viewModel.tokenRateText
            )

            NewPiComposerSurface {
                VStack(alignment: .leading, spacing: 8) {
                    if !draftAttachments.isEmpty {
                        NewPiDraftAttachmentStrip(drafts: $draftAttachments)
                    }

                    // 只换外壳；保持 NSTextView、四行视口与 IME/草稿同步机制不变。
                    NewPiComposerTextView(
                        text: $input,
                        isDisabled: false,
                        placeholder: runtime.isStreaming ? "先写下一条消息，当前任务结束后发送…" : "继续提问，或告诉 NewPi 下一步做什么…",
                        onSubmit: sendComposerInput,
                        onImagesPicked: appendDrafts
                    )
                    .help(runtime.isStreaming ? "可以先编辑下一条消息；当前任务结束后才能发送。" : "Return 发送，Shift+Return 换行")
                    .frame(height: NewPiComposerScrollView.fixedHeight)

                    HStack(spacing: 10) {
                        Button(action: pickImages) {
                            Label("添加图片", systemImage: "plus")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("添加图片（也可直接拖拽或 ⌘V 粘贴到输入框）")

                        modelPicker
                        Spacer(minLength: 8)
                        NewPiComposerPrimaryAction(
                            isRunning: runtime.isStreaming,
                            canSend: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty,
                            onSend: sendComposerInput,
                            onStop: { viewModel.abort() }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: NewPiWorkbenchStyle.maxReadingWidth)
        .frame(maxWidth: .infinity)
        .background(NewPiWorkbenchStyle.surface)
        .animation(nil, value: runtime.isStreaming)
    }

    private var modelPicker: NewPiModelPickerMenu {
        NewPiModelPickerMenu(
            groups: viewModel.providerModelGroups,
            activeProfileID: viewModel.activeProviderID,
            activeModelID: viewModel.activeProviderModel,
            thinkingLevel: viewModel.activeThinkingLevel,
            isDisabled: runtime.isStreaming,
            onSelect: { profileID, modelID in
                Task { await viewModel.switchModel(profileID: profileID, modelID: modelID) }
            },
            onThinkingSelect: { level in
                Task { await viewModel.setThinkingLevel(level) }
            }
        )
    }

    private func sendComposerInput() {
        let text = input
        let drafts = draftAttachments
        // 空文本 + 有图片也可发送（识图场景常只发图）；拦截与体积校验在 ViewModel.send。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !drafts.isEmpty,
              !runtime.isStreaming else { return }
        // 只有消息通过模型能力、附件体积与落盘等全部校验并真正进入会话后，
        // 才清空草稿。失败时保留用户文本和图片，便于修正配置后重试。
        guard viewModel.send(text, draftAttachments: drafts) else { return }
        input = ""
        draftAttachments = []
        // 发送 = 明确要看最新内容的意图（聊天应用惯例）：显式钉底，
        // 否则用户停在中部时，流式输出按保锚纪律不跟随（看起来像没反应）。
        docController.scrollToBottom()
    }

    // MARK: - 图片附件采集（BACKLOG-IMAGE-INPUT）

    /// 附件按钮：NSOpenPanel 多选图片 → 解码/缩放/压缩成草稿（ImageAttachmentProcessor）。
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appendDrafts(panel.urls.compactMap { ImageAttachmentProcessor.makeDraft(fromFileURL: $0) })
    }

    /// 采集入口（按钮 / 拖拽 / 粘贴）统一汇入：全部不可解码时 beep 提示，不静默丢弃。
    private func appendDrafts(_ newDrafts: [DraftImageAttachment]) {
        guard !newDrafts.isEmpty else {
            NSSound.beep()
            return
        }
        draftAttachments.append(contentsOf: newDrafts)
    }
}

/// composer 上方的草稿附件条：缩略图横排 + 逐张移除。
private struct NewPiDraftAttachmentStrip: View {
    @Binding var drafts: [DraftImageAttachment]

    /// 真实像素宽高比（宽/高）。用 cgImage 取值，绕过 NSImage.size 的 DPI 偏差。
    static func pixelAspectRatio(of image: NSImage) -> CGFloat? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.height > 0 else { return nil }
        return CGFloat(cg.width) / CGFloat(cg.height)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(drafts) { draft in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = NSImage(data: draft.data) {
                                // 用真实像素宽高比，避免依赖 NSImage.size（其可能因 DPI
                                // 元数据与像素不一致，导致 scaledToFill 用了错误比例而变形）。
                                let aspect = Self.pixelAspectRatio(of: image) ?? 1
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(aspect, contentMode: .fill)
                            } else {
                                Color.gray.opacity(0.2)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .clipped()

                        Button {
                            drafts.removeAll { $0.id == draft.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help("移除该图片")
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 64)
    }
}

// MARK: - Multiline composer (NSTextView)

/// 多行输入框：基于 NSTextView，固定显示 4 行，超出后内部滚动；
/// Return 发送 / Shift+Return 换行。替代原先近似单行的 TextField(axis: .vertical)。
struct NewPiComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isDisabled: Bool = false
    var placeholder: String = "Message NewPi…"
    var onSubmit: () -> Void = {}
    /// 图片采集回调（输入框拖拽 / ⌘V 粘贴）：汇入外层草稿附件条。
    var onImagesPicked: ([DraftImageAttachment]) -> Void = { _ in }
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NewPiComposerScrollView {
        let scrollView = NewPiComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // NSTextView() 便利构造会创建完整 TextKit 链（textStorage/layoutManager/container）；
        // designated init(frame:textContainer: nil) 不会（见 NSTextView.h），别用。
        let textView = NewPiComposerInnerTextView()
        // 图片采集拖拽注册（追加注册，不影响既有文本拖拽类型；任意时机调用均合法）：
        // .fileURL 覆盖「图片文件」，.tiff/.png 覆盖「位图图片数据」（浏览器/预览直接拖图片）。
        textView.registerForDraggedTypes([.fileURL, .tiff, .png])
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onImagesPicked = onImagesPicked
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
        textView.onImagesPicked = onImagesPicked
        textView.placeholder = placeholder
        if textView.isEditable != !isDisabled {
            textView.isEditable = !isDisabled
        }
        textView.textColor = isDisabled ? .disabledControlTextColor : .textColor
        context.coordinator.synchronizeText(text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NewPiComposerTextView
        weak var textView: NewPiComposerInnerTextView?

        init(_ parent: NewPiComposerTextView) {
            self.parent = parent
        }

        func synchronizeText(_ text: String) {
            guard let textView else { return }
            // IME marked text 属于 AppKit 的未提交编辑，和 Binding 暂时不同是正常状态。
            // 流式输出会反复调用 updateNSView，不能把旧 Binding 当成清空/替换命令。
            guard !textView.hasMarkedText() else { return }
            if textView.string != text {
                textView.string = text
                textView.scrollToEndOfDocument(nil)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
        }
    }
}

/// 固定 4 行高的 ScrollView；内容超过 4 行后由 NSScrollView 内部滚动。
final class NewPiComposerScrollView: NSScrollView {
    /// 13pt 系统字体约 16pt/行，加上 NSTextView 上下各 7pt 内边距。
    static let fixedHeight: CGFloat = 78

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.fixedHeight)
    }
}

/// 支持占位提示与 Return 发送（Shift+Return 换行）的 NSTextView。
final class NewPiComposerInnerTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: (() -> Void)?
    /// 图片采集回调（拖拽文件 / ⌘V 粘贴截图）：由外层汇入草稿附件条。
    var onImagesPicked: (([DraftImageAttachment]) -> Void)?

    // ⌘V 粘贴：剪贴板有图片（截图 / 复制的位图 / 复制的图片文件）→ 采集为草稿；否则走默认文本粘贴。
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let data = PasteboardImageReader.readImageData() else {
            super.paste(sender)
            return
        }
        // 有图片数据：解码/缩放/压缩可能较耗时，放后台避免阻塞主线程，
        // 完成后回主线程回调外层汇入附件条（失败时明确提示，而非静默 beep）。
        let displayName = Self.pastedDisplayName(from: pasteboard)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let draft = ImageAttachmentProcessor.makeDraft(from: data, displayName: displayName)
            DispatchQueue.main.async {
                guard let draft else {
                    NSSound.beep()
                    return
                }
                self?.onImagesPicked?([draft])
            }
        }
    }

    /// 粘贴来源的展示名：优先用剪贴板里图片文件的真实文件名，否则用随机名。
    private static func pastedDisplayName(from pasteboard: NSPasteboard) -> String {
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.lastPathComponent
        }
        return "pasted-image-\(UUID().uuidString.prefix(8))"
    }

    // 拖拽图片（文件 URL 或位图数据）进输入框 → 采集为草稿；否则保持默认行为。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !Self.imageFileURLs(from: sender).isEmpty || Self.draggedImageData(from: sender) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.imageFileURLs(from: sender)
        if !urls.isEmpty {
            onImagesPicked?(urls.compactMap { ImageAttachmentProcessor.makeDraft(fromFileURL: $0) })
            return true
        }
        // 位图数据（非文件）拖拽。
        if let data = Self.draggedImageData(from: sender),
           let draft = ImageAttachmentProcessor.makeDraft(from: data, displayName: "dropped-image-\(UUID().uuidString.prefix(8))") {
            onImagesPicked?([draft])
            return true
        }
        return super.performDragOperation(sender)
    }

    /// 拖拽信息里的图片文件 URL（按扩展名 UTType 判定 conforms(to: .image)）。
    private static func imageFileURLs(from sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return [] }
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }

    /// 拖拽信息里的位图图片数据（非文件；如从浏览器/预览直接拖出的图片）。
    private static func draggedImageData(from sender: NSDraggingInfo) -> Data? {
        let pasteboard = sender.draggingPasteboard
        let types: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in types {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        return nil
    }

    // 始终允许粘贴图片（即使 isEditable=false）。
    // 不重写时，NSTextView 默认在 isEditable=false 或 responder chain 异常时返回 false，
    // 导致 Cmd+V 被拒绝（beep）而 paste() 永远不被调用（Snipaste 粘贴问题的根因）。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

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
