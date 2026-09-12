import AppKit
import NewPiCore
import SwiftUI
import UniformTypeIdentifiers

/// 保活容器：把每个缓存会话的面板视图（含彼此内部的 WKWebView）常驻挂载，
/// 切换会话时仅翻转活跃面板的显示/交互，而不销毁重建 —— 这样 DOM、测高、滚动位置
/// 全部免费保留，做到"切换即显示、原位恢复"。被淘汰的会话在 beginSession 冷重建。
struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @StateObject private var emptyDraft: NewPiComposerDraft
    @State private var isCreating = false
    @State private var creationTask: Task<Void, Never>?
    @State private var creationID = UUID()
    @State private var claimedRuntime: SessionRuntime?
    @State private var claimedProject: URL?
    @State private var creationError: String?
    @State private var composerFocused = false

    init(viewModel: NewPiViewModel, emptyDraft: NewPiComposerDraft? = nil) {
        self.viewModel = viewModel
        _emptyDraft = StateObject(wrappedValue: emptyDraft ?? NewPiComposerDraft())
    }

    var body: some View {
        Group {
            if isCreating || holdsClaimedDraft || !viewModel.keptAliveRuntimes.contains(where: viewModel.isActiveRuntime) {
                VStack(spacing: 0) {
                    NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil,
                        onSuggestion: { emptyDraft.fillSuggestion($0) },
                        suggestionsEnabled: emptyDraft.text.isEmpty && emptyDraft.attachments.isEmpty && !emptyDraft.isComposing,
                        projectName: viewModel.projectURL?.lastPathComponent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    emptyComposer
                }
            } else {
                VStack(spacing: 0) {
                    if !emptyDraft.text.isEmpty || !emptyDraft.attachments.isEmpty {
                        HStack {
                            Text("有保留的未发送草稿（\(emptyDraft.attachments.count) 张图片）")
                            Spacer(minLength: 0)
                            Button("取回草稿") {
                                guard !viewModel.isSwitchingSession,
                                      let runtime = viewModel.keptAliveRuntimes.first(where: viewModel.isActiveRuntime) else { return }
                                if !emptyDraft.transfer(to: runtime.composerDraft) {
                                    creationError = "请先处理当前会话的草稿，再取回保留的输入。"
                                }
                            }
                            .disabled(viewModel.isSwitchingSession)
                        }
                        .font(.caption).padding(10)
                        if let creationError { Text(creationError).font(.caption).foregroundStyle(.orange) }
                    }
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
        }
        .background(NewPiWorkbenchStyle.surface)
        .onDisappear {
            creationID = UUID()
            creationTask?.cancel()
            isCreating = false
        }
    }

    private var holdsClaimedDraft: Bool {
        guard let claimedRuntime else { return false }
        return viewModel.projectURL == claimedProject && viewModel.isActiveRuntime(claimedRuntime)
            && (!emptyDraft.text.isEmpty || !emptyDraft.attachments.isEmpty || emptyDraft.isComposing)
    }

    private var emptyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let creationError { Text(creationError).font(.caption).foregroundStyle(.orange) }
            if isCreating { Text("正在创建会话；可继续编辑草稿").font(.caption).foregroundStyle(.secondary) }
            NewPiComposerSurface(isFocused: composerFocused) {
                VStack(alignment: .leading, spacing: 8) {
                    if !emptyDraft.attachments.isEmpty { NewPiDraftAttachmentStrip(drafts: $emptyDraft.attachments) }
                    NewPiComposerTextView(text: $emptyDraft.text,
                        placeholder: "描述一个问题，点击发送后创建会话…",
                        onSubmit: sendEmptyDraft,
                        onImagesPicked: emptyDraft.attachmentReceiver(),
                        focusRequest: emptyDraft.focusRequest,
                        onFocusChange: { composerFocused = $0 },
                        onCompositionChange: { emptyDraft.isComposing = $0 })
                        .frame(height: NewPiComposerScrollView.fixedHeight)
                    HStack(spacing: 10) {
                        Button {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            panel.allowsMultipleSelection = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK {
                                emptyDraft.appendAttachments(panel.urls.compactMap { ImageAttachmentProcessor.makeDraft(fromFileURL: $0) })
                            }
                        } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                        .buttonStyle(.borderless).help("添加图片")
                        NewPiModelPickerMenu(groups: viewModel.providerModelGroups,
                            activeProfileID: viewModel.activeProviderID, activeModelID: viewModel.activeProviderModel,
                            thinkingLevel: viewModel.activeThinkingLevel,
                            isDisabled: isCreating || viewModel.isSwitchingSession,
                            onSelect: { profile, model in Task { await viewModel.switchModel(profileID: profile, modelID: model) } },
                            onThinkingSelect: { level in Task { await viewModel.setThinkingLevel(level) } })
                        Spacer(minLength: 0)
                        NewPiComposerHint(isRunning: isCreating)
                        NewPiComposerPrimaryAction(isRunning: false,
                            canSend: viewModel.projectURL != nil && !isCreating && !viewModel.isSwitchingSession
                                && (!emptyDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !emptyDraft.attachments.isEmpty),
                            onSend: sendEmptyDraft, onStop: {})
                    }
                }
            }
        }
        .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset).padding(.vertical, 16)
        .frame(maxWidth: NewPiWorkbenchStyle.maxReadingWidth).frame(maxWidth: .infinity)
    }

    private func sendEmptyDraft() {
        guard let project = viewModel.projectURL, !isCreating, !viewModel.isSwitchingSession,
              !emptyDraft.isComposing,
              !emptyDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !emptyDraft.attachments.isEmpty else { return }
        let text = emptyDraft.text
        let attachments = emptyDraft.attachments.map(\.id)
        let request = UUID()
        creationID = request
        isCreating = true
        creationError = nil
        creationTask = Task { @MainActor in
            let runtime: SessionRuntime?
            if let claimedRuntime, claimedProject == project, viewModel.isActiveRuntime(claimedRuntime) {
                runtime = claimedRuntime
            } else {
                runtime = await viewModel.createSessionForComposer(project: project)
            }
            guard creationID == request else { return }
            defer { isCreating = false; creationTask = nil }
            guard !Task.isCancelled, viewModel.projectURL == project,
                  let runtime, viewModel.isActiveRuntime(runtime), !viewModel.isSwitchingSession else {
                creationError = "未发送：创建失败或导航已改变，文字与图片仍保留。"
                return
            }
            claimedRuntime = runtime
            claimedProject = project
            let unchanged = emptyDraft.text == text && emptyDraft.attachments.map(\.id) == attachments
            guard emptyDraft.transfer(to: runtime.composerDraft) else {
                creationError = "草稿仍保留；请完成输入法组合后再次发送。"
                return
            }
            // 交接和 send 同属一个 MainActor 同步段；期间没有第二个输入框可编辑或发送。
            if unchanged, viewModel.send(runtime.composerDraft.text, draftAttachments: runtime.composerDraft.attachments) {
                runtime.composerDraft.text = ""
                runtime.composerDraft.attachments = []
            }
            // 失败草稿已归 runtime；能力/附件错误由 send 的真实错误条目呈现。
            claimedRuntime = nil
            claimedProject = nil
        }
    }
}

extension NewPiViewModel {
    /// VM 集成契约：只读 composerSessionGeneration 返回私有 sessionSwitchGeneration。
    /// 不能用 isSwitchingSession 代替：切项目的 shutdown await 期间它可能已是 false。
    @MainActor
    func createSessionForComposer(project: URL) async -> SessionRuntime? {
        guard !Task.isCancelled, projectURL == project, !isSwitchingSession,
              !keptAliveRuntimes.contains(where: isActiveRuntime) else { return nil }
        let existingIDs = Set(keptAliveRuntimes.map(\.sessionID))
                let expectedGeneration = composerSessionGeneration + 1
        await startNewSession()
                guard !Task.isCancelled, composerSessionGeneration == expectedGeneration,
              projectURL == project, !isSwitchingSession,
              let runtime = keptAliveRuntimes.first(where: isActiveRuntime),
              !existingIDs.contains(runtime.sessionID), runtime.transcript.isEmpty else { return nil }
        return runtime
    }
}

/// 单个会话的聊天面板：从它自己的 runtime 观察转录/流式状态。
/// 非活跃面板保持挂载（opacity 0），WebView 不销毁；活跃面板完整交互。
struct NewPiSessionPanel: View {
    @ObservedObject var runtime: SessionRuntime
    @ObservedObject var viewModel: NewPiViewModel

    /// 草稿归 runtime 所有；只观察此对象，不让逐键输入通知根列表。
    @ObservedObject private var draft: NewPiComposerDraft
    @State private var composerFocused = false

    init(runtime: SessionRuntime, viewModel: NewPiViewModel) {
        self.runtime = runtime
        self.viewModel = viewModel
        _draft = ObservedObject(wrappedValue: runtime.composerDraft)
    }
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
                if runtime.transcript.isEmpty && runtime.pendingToolApproval == nil {
                    if viewModel.isSwitchingSession {
                        ProgressView("正在加载会话…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil,
                            onSuggestion: { prompt in draft.fillSuggestion(prompt) },
                            suggestionsEnabled: draft.text.isEmpty && draft.attachments.isEmpty && !draft.isComposing,
                            projectName: viewModel.projectURL?.lastPathComponent)
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
                        projectName: viewModel.projectURL?.lastPathComponent,
                        onFork: { index in
                            Task { await viewModel.forkFromMessage(index: index) }
                        },
                        onRetry: { id in
                            viewModel.retryError(id: id, on: runtime)
                        },
                        approval: transcriptApproval,
                        onApprovalAccepted: { requestID, decision in
                            viewModel.respondToTranscriptApproval(requestID: requestID, decision: decision, on: runtime)
                        },
                        approvalIsCurrent: { [request = runtime.pendingToolApproval] in
                            viewModel.isActiveRuntime(runtime) && request != nil && runtime.pendingToolApproval == request
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

    private var transcriptApproval: NewPiTranscriptApproval? {
        guard let request = runtime.pendingToolApproval, let directory = viewModel.projectURL else { return nil }
        return NewPiTranscriptApproval(runtimeIdentity: runtime.approvalRuntimeID.uuidString,
            request: request, workingDirectory: directory)
    }

    private var chatComposer: some View {
        VStack(spacing: 6) {
            if let warning = contextWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            NewPiAgentStatusBar(
                presentation: NewPiAgentStatusPresentation(
                    systemImage: runtime.pendingToolApproval != nil ? "hand.raised.circle"
                        : NewPiSidebarFacts.statusIcon(isRunning: runtime.isStreaming, outcome: runtime.turnOutcome),
                    label: runtime.turnStatusText, isActive: runtime.isStreaming),
                detailText: runtime.turnSummaryText,
                usageText: runtime.totalUsage.newPiCompactText,
                lastTurnUsageText: runtime.lastTurnUsage.newPiCompactText,
                cacheHitRateText: runtime.totalUsage.newPiCacheHitRateText,
                contextText: viewModel.contextUsageText(for: runtime.lastTurnUsage),
                tokenRateText: viewModel.tokenRateText,
                lastTurnInputTokens: runtime.lastTurnUsage.totalInputTokens > 0 ? runtime.lastTurnUsage.totalInputTokens : nil,
                lastTurnOutputTokens: runtime.lastTurnUsage.outputTokens > 0 ? runtime.lastTurnUsage.outputTokens : nil
            )

            NewPiComposerSurface(isFocused: composerFocused) {
                VStack(alignment: .leading, spacing: 8) {
                    if !draft.attachments.isEmpty {
                        NewPiDraftAttachmentStrip(drafts: $draft.attachments)
                    }

                    // 只换外壳；保持 NSTextView、四行视口与 IME/草稿同步机制不变。
                    NewPiComposerTextView(
                        text: $draft.text,
                        isDisabled: false,
                        placeholder: runtime.isStreaming ? "先写下一条消息，当前任务结束后发送…" : "继续提问，或告诉 NewPi 下一步做什么…",
                        onSubmit: sendComposerInput,
                        onImagesPicked: draft.attachmentReceiver(),
                        onRecallHistory: { previous, currentText in
                            draft.text = currentText
                            return draft.recallHistory(previous: previous) {
                                runtime.transcript.filter { $0.kind == .user }.map(\.body)
                            }
                        },
                        focusRequest: draft.focusRequest,
                        isFocusEligible: viewModel.isActiveRuntime(runtime) && !viewModel.isSwitchingSession,
                        onFocusChange: { composerFocused = $0 },
                        onCompositionChange: { draft.isComposing = $0 }
                    )
                    .help("Return 发送，Shift+Return 换行；首行 ↑ / 末行 ↓ 取回历史输入。" + (runtime.isStreaming ? "当前任务结束后才能发送。" : ""))
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
                        NewPiComposerHint(isRunning: runtime.isStreaming)
                        NewPiComposerPrimaryAction(
                            isRunning: runtime.isStreaming,
                            canSend: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty,
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

    private var contextWarning: String? {
        guard viewModel.isActiveRuntime(runtime), let profile = viewModel.activeProfile else { return nil }
        return NewPiContextWarning.text(input: runtime.lastTurnUsage.totalInputTokens,
            window: profile.contextWindow(for: viewModel.activeProviderModel))
    }

    private func sendComposerInput() {
        let text = draft.text
        let drafts = draft.attachments
        // 空文本 + 有图片也可发送（识图场景常只发图）；拦截与体积校验在 ViewModel.send。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !drafts.isEmpty,
              !runtime.isStreaming, !viewModel.isSwitchingSession, viewModel.isActiveRuntime(runtime) else { return }
        // 只有消息通过模型能力、附件体积与落盘等全部校验并真正进入会话后，
        // 才清空草稿。失败时保留用户文本和图片，便于修正配置后重试。
        guard viewModel.send(text, draftAttachments: drafts) else { return }
        draft.text = ""
        draft.attachments = []
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
        draft.appendAttachments(newDrafts)
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
                    VStack(spacing: 5) {
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
                        .help("移除 \(draft.displayName)")
                        .accessibilityLabel("移除 \(draft.displayName)")
                        .offset(x: 5, y: -5)
                    }
                    Text(draft.displayName)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(width: 100)
                        .help(draft.displayName)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 86)
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
    /// 返回 nil 表示不消费方向键；历史仅在首/末显示行的裸方向键触发。
    var onRecallHistory: (_ previous: Bool, _ currentText: String) -> String? = { _, _ in nil }
    var focusRequest: UUID? = nil
    var isFocusEligible = true
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCompositionChange: (Bool) -> Void = { _ in }
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
        textView.onRecallHistory = onRecallHistory
        textView.onFocusChange = onFocusChange
        textView.onCompositionChange = onCompositionChange
        textView.string = text
        textView.isEditable = !isDisabled
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
        textView.onAttachToWindow = { [weak coordinator = context.coordinator] in coordinator?.requestFocusIfNeeded() }
        return scrollView
    }

    func updateNSView(_ scrollView: NewPiComposerScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onImagesPicked = onImagesPicked
        textView.onRecallHistory = onRecallHistory
        textView.onFocusChange = onFocusChange
        textView.onCompositionChange = onCompositionChange
        textView.placeholder = placeholder
        if textView.isEditable != !isDisabled {
            textView.isEditable = !isDisabled
        }
        textView.textColor = isDisabled ? .disabledControlTextColor : .textColor
        context.coordinator.synchronizeText(text)
        context.coordinator.requestFocusIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NewPiComposerTextView
        weak var textView: NewPiComposerInnerTextView?
        private var consumedFocusRequest: UUID?

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
            parent.onCompositionChange(textView.hasMarkedText())
            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
        }

        func requestFocusIfNeeded() {
            guard let request = parent.focusRequest, request != consumedFocusRequest,
                  parent.isFocusEligible, !parent.isDisabled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.focusRequest == request, self.consumedFocusRequest != request,
                      self.parent.isFocusEligible, !self.parent.isDisabled,
                      let view = self.textView, !view.hasMarkedText(),
                      !view.isHiddenOrHasHiddenAncestor, let window = view.window,
                      window.isKeyWindow, !view.visibleRect.isEmpty else { return }
                guard window.makeFirstResponder(view) else { return }
                self.consumedFocusRequest = request
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
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
    var onFocusChange: (Bool) -> Void = { _ in }
    var onCompositionChange: (Bool) -> Void = { _ in }
    var onAttachToWindow: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttachToWindow() }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange(hasMarkedText())
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { reportFocus() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { reportFocus() }
        return accepted
    }

    private func reportFocus() {
        // AppKit 可在 SwiftUI 更新期间转焦，延后通知避免发布发生在 body 更新内。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFocusChange(self.window?.firstResponder === self)
        }
    }
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: (() -> Void)?
    /// 图片采集回调（拖拽文件 / ⌘V 粘贴截图）：由外层汇入草稿附件条。
    var onImagesPicked: (([DraftImageAttachment]) -> Void)?
    var onRecallHistory: ((_ previous: Bool, _ currentText: String) -> String?)?

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
        let acceptImages = onImagesPicked
        Task { @MainActor in
            let draft = await Task.detached(priority: .userInitiated) {
                ImageAttachmentProcessor.makeDraft(from: data, displayName: displayName)
            }.value
                guard let draft else {
                    NSSound.beep()
                    return
                }
                acceptImages?([draft])
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
        let previous = event.keyCode == 126
        if (previous || event.keyCode == 125), isEditable, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           isAtHistoryBoundary(previous: previous),
           let recalled = onRecallHistory?(previous, string) {
            // 走文本编辑通道同步 Binding 与撤销栈，连续按键不依赖 SwiftUI 下一帧更新。
            insertText(recalled, replacementRange: NSRange(location: 0, length: (string as NSString).length))
            setSelectedRange(NSRange(location: previous ? 0 : (string as NSString).length, length: 0))
            scrollRangeToVisible(selectedRange())
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / 小键盘 Enter
        // IME 组词中（如拼音选词确认）不拦截 Return；Shift+Return 换行。
        if isReturn, !hasMarkedText(), !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// 用 TextKit 的实际显示行判断边界，长文本自动换行时也保留正常光标移动。
    func isAtHistoryBoundary(previous: Bool) -> Bool {
        let selection = selectedRange()
        let length = (string as NSString).length
        guard selectedRanges.count == 1, selection.length == 0, selection.location <= length else { return false }
        if length == 0 { return true }
        guard let layoutManager, let textContainer else { return false }
        layoutManager.ensureLayout(for: textContainer)
        if selection.location == length, layoutManager.extraLineFragmentTextContainer != nil {
            return !previous
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(selection.location, length - 1))
        var line = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return previous ? line.location == 0
            : NSMaxRange(line) == layoutManager.numberOfGlyphs && layoutManager.extraLineFragmentTextContainer == nil
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
