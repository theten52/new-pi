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
    @State private var composerHeight: CGFloat = 120
    /// composer 输入框的实测内容高度（由 NewPiComposerTextView 回报，1～4 行）。
    @State private var composerInputHeight: CGFloat = NewPiComposerScrollView.fallbackHeight
    @State private var suppressAutoPinDuringStreaming = false
    @State private var isNearBottom = true
    /// rail 跳转 + 手动窗口化共用的高度表：可见区外的行用表内精确高度占位，
    /// SwiftUI 不再对未实例化行做任何估算（LazyVStack 估算是 rail 与滚动条问题的根）。
    @StateObject private var heightMap = TranscriptHeightMap()
    /// 精确滚动执行者（macOS 15 API）：scrollTo(point:) 按内容坐标直接滚动。
    @State private var jumpPosition = ScrollPosition()
    /// 当前滚动偏移（内容坐标），由内容的 onGeometryChange 驱动。
    /// 可见窗口是它的派生值（body 内直接计算），不再用事件链维护——
    /// 「揭示后白屏、滚动才恢复」正是事件链时序错位导致的窗口过期。
    @State private var scrollOffset: CGFloat = 0
    /// resize 防抖重预热任务。
    @State private var resizePreheatTask: Task<Void, Never>?
    /// rail 着陆后的有界跟进校正：预热仍在填充几何时，目标 y 会漂移；
    /// 缓存版本变化时重算一次（3s 窗口、用户接管滚动即放弃、数据稳定即止）。
    private struct RailTarget: Equatable {
        let id: UUID
        var lastY: CGFloat
        let deadline: Date
    }
    @State private var pendingRailTarget: RailTarget?
    /// 首次布局是否恢复了保存的滚动位置：恢复过则禁止 composer 高度变化触发的
    /// 自动钉底（它会在恢复 scrollTo 落地后把会话又拽回底部——原位恢复失效的根因）。
    @State private var restoredSavedPosition = false

    private let messageBottomGap: CGFloat = 16
    /// 判定"已接近底部"的阈值：距底部小于该值视为在底部，流式时才自动钉底；
    /// 否则用户在中间浏览时流式内容不打断。
    private let nearBottomThreshold: CGFloat = 100

    private var isActive: Bool { viewModel.isActiveRuntime(runtime) }

    private var userMessageMarkers: [UserMessageMarker] {
        runtime.transcript
            .filter { $0.title == "You" }
            .map { UserMessageMarker(id: $0.id, preview: $0.body) }
    }

    var body: some View {
        GeometryReader { geometry in
            let scrollViewportHeight = max(0, geometry.size.height - composerHeight)
            // 可见窗口：派生值。scrollOffset/视口/高度表任一变化即重算，永远与当前几何一致。
            let visibleRange = heightMap.window(scrollOffset: scrollOffset, viewportHeight: scrollViewportHeight)
            let visibleItems = visibleRange.isEmpty ? [] : Array(runtime.transcript[visibleRange])
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)

                                // 手动窗口化：可见区外的行用高度表精确占位，
                                // SwiftUI 不做任何估算（LazyVStack 内部估算是 rail 漂移
                                // 与滚动条变短的共同根因）。行进入窗口才挂 WKWebView。
                                VStack(alignment: .leading, spacing: TranscriptHeightMap.rowSpacing) {
                                    if runtime.transcript.isEmpty {
                                        if viewModel.isSwitchingSession {
                                            ProgressView("Loading session…")
                                                .frame(maxWidth: .infinity, minHeight: 120)
                                        } else {
                                            NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                                        }
                                    } else {
                                        let topPlaceholder = visibleRange.isEmpty
                                            ? 0
                                            : heightMap.placeholderHeight(before: visibleRange.lowerBound)
                                        let bottomPlaceholder = visibleRange.isEmpty
                                            ? heightMap.totalRowsHeight
                                            : heightMap.placeholderHeight(after: visibleRange.upperBound - 1)

                                        if topPlaceholder > 0 {
                                            Color.clear.frame(height: topPlaceholder)
                                        }

                                        ForEach(visibleItems) { item in
                                            NewPiTranscriptRow(
                                                item: item,
                                                isStreaming: runtime.isStreaming,
                                                isActiveStreamingItem: runtime.isStreaming
                                                    && item.id == runtime.transcript.last?.id
                                                    && (item.title == "NewPi" || item.title == "Summary"),
                                                onInitialRendered: { runtime.markInitialRowRendered(item.id) }
                                            ) { forkIndex in
                                                Task { await viewModel.forkFromMessage(index: forkIndex) }
                                            }
                                            .id(item.id)
                                            // 实例化行回报实测高度回高度表（只更新数据，不触发滚动），
                                            // 占位高度随之精确化。
                                            .onGeometryChange(for: CGFloat.self) { proxy in
                                                proxy.size.height
                                            } action: { height in
                                                heightMap.updateMeasured(id: item.id, height: height)
                                            }
                                        }

                                        if bottomPlaceholder > 0 {
                                            Color.clear.frame(height: bottomPlaceholder)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Color.clear
                                    .frame(height: messageBottomGap)

                                Color.clear
                                    .frame(height: 1)
                                    .id(NewPiChatScrollSupport.bottomAnchorID)
                                    .background(
                                        GeometryReader { anchorGeometry in
                                            Color.clear.preference(
                                                key: ChatBottomAnchorPreferenceKey.self,
                                                value: anchorGeometry
                                                    .frame(in: .named(NewPiChatScrollSupport.coordinateSpaceName))
                                                    .minY
                                            )
                                        }
                                    )
                            }
                            .padding()
                            .frame(
                                maxWidth: .infinity,
                                minHeight: scrollViewportHeight,
                                alignment: .bottom
                            )
                            // 滚动偏移跟踪：内容在滚动坐标系中的 minY 取负即当前 offset。
                            // 驱动手动窗口化（可见区外的行由高度表精确占位）。
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                -proxy.frame(in: .named(NewPiChatScrollSupport.coordinateSpaceName)).minY
                            } action: { newOffset in
                                scrollOffset = newOffset
                                // 持续记录滚动位置（锚点行 + 行内偏移，offset 兜底）：原位恢复用。
                                let anchor = heightMap.anchor(at: newOffset)
                                ScrollPositionStore.shared.set(
                                    runtime.sessionID,
                                    rowID: anchor?.id,
                                    delta: anchor?.delta ?? 0,
                                    offset: newOffset
                                )
                            }
                        }
                        .coordinateSpace(name: NewPiChatScrollSupport.coordinateSpaceName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollBounceBehavior(.basedOnSize)
                        // rail 跳转 / 会话恢复用 ScrollPosition（macOS 15）：scrollTo(point:)
                        // 按内容坐标精确滚动，不依赖目标行实例化。
                        // 不用 id 绑定形式（绑定会持续回写 anchor 落点，与精确定位打架）。
                        .scrollPosition($jumpPosition)
                        .transaction { transaction in
                            if runtime.isStreaming {
                                transaction.disablesAnimations = true
                            }
                        }

                        NewPiUserMessageRail(
                            markers: userMessageMarkers,
                            onSelect: { messageID in
                                suppressAutoPinDuringStreaming = true
                                // 高度表算术定位：点击时按最新缓存重建表，前缀和算出目标行
                                // 内容 y，scrollTo(point:) 动画滚动到位。目标 y 是固定的
                                //（布局与表同源），动画只是插值过程，不影响精度。
                                heightMap.rebuild(
                                    items: runtime.transcript,
                                    contentWidth: geometry.size.width - 32
                                )
                                if let y = heightMap.offset(of: messageID) {
                                    let target = max(0, y)
                                    pendingRailTarget = RailTarget(
                                        id: messageID, lastY: target,
                                        deadline: Date().addingTimeInterval(3)
                                    )
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        jumpPosition.scrollTo(point: CGPoint(x: 0, y: target))
                                    }
                                }
                            }
                        )
                        .padding(.trailing, 10)
                    }
                    .overlay(alignment: .bottom) {
                        if runtime.isStreaming && !isNearBottom {
                            Button {
                                suppressAutoPinDuringStreaming = false
                                pinScrollToBottom(using: proxy)
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
                    // 冷加载就绪门控：等尾部 markdown 行上报首次高度（或超时）后才揭示，
                    // 隐藏「先用户气泡、agent 气泡逐行蹦出」的中间态。opacity 与 allowsHitTesting
                    // 成对使用（项目约定），等待期禁用命中测试，避免用户滚动作用于透明内容破坏钉底。
                    .opacity(runtime.initialRenderReady ? 1 : 0)
                    .allowsHitTesting(runtime.initialRenderReady)
                    .animation(.easeIn(duration: 0.15), value: runtime.initialRenderReady)
                    .overlay {
                        if !runtime.initialRenderReady {
                            ProgressView("Loading session…")
                                .controlSize(.large)
                        }
                    }
                    .onAppear {
                        rebuildHeightMap(contentWidth: geometry.size.width - 32)
                        // 原位恢复优先：有保存的位置则恢复（锚点行重算，offset 兜底），否则钉底。
                        if let entry = ScrollPositionStore.shared.entry(for: runtime.sessionID),
                           !runtime.transcript.isEmpty {
                            restoredSavedPosition = true
                            let anchorY = entry.rowID
                                .flatMap(UUID.init(uuidString:))
                                .flatMap { heightMap.offset(of: $0) }
                                .map { $0 + CGFloat(entry.delta) }
                            let target = max(0, anchorY ?? CGFloat(entry.offset))
                            NewPiLogger.info(category: "app", message: "Scroll restore start", details: "session=\(runtime.sessionID) target=\(target) anchored=\(anchorY != nil)")
                            // 锚点恢复同样进有界跟进：恢复时几何可能未长全（预热中），
                            // 预热补齐后跟进校正会把视口锁定在同一条消息上。
                            if let rowID = entry.rowID.flatMap(UUID.init(uuidString:)) {
                                pendingRailTarget = RailTarget(
                                    id: rowID, lastY: target,
                                    deadline: Date().addingTimeInterval(3)
                                )
                            }
                            restoreScrollPosition(to: target)
                        } else {
                            NewPiLogger.info(category: "app", message: "Scroll restore skipped", details: "session=\(runtime.sessionID) transcriptEmpty=\(runtime.transcript.isEmpty)")
                            schedulePinScrollToBottom(using: proxy)
                        }
                    }
                    // 高度表重建：transcript 结构变化 / 宽度变化 / 缓存被预热或实测填充时。
                    .onChange(of: runtime.transcript.map(\.id)) { _, _ in
                        rebuildHeightMap(contentWidth: geometry.size.width - 32)
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        rebuildHeightMap(contentWidth: geometry.size.width - 32)
                        // resize 防抖重预热：宽度桶切换后，不可见区域的 md 行在新宽度下
                        // 没有实测高度（rail 会退化为估算）。resize 结束 500ms 后重跑预热补齐。
                        resizePreheatTask?.cancel()
                        resizePreheatTask = Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !Task.isCancelled else { return }
                            MarkdownHeightPreheater.shared.preheat(items: runtime.transcript)
                        }
                    }
                    .onReceive(MarkdownRenderingCache.shared.$version) { _ in
                        rebuildHeightMap(contentWidth: geometry.size.width - 32)
                        applyPendingRailCorrection()
                    }
                    .onChange(of: runtime.isStreaming) { wasStreaming, isStreaming in
                        // 只在活跃面板执行滚动逻辑：后台保话面板流式结束时不能把
                        // 隐藏面板拽到底（违背"原位恢复"）。
                        guard isActive else { return }
                        if isStreaming, !wasStreaming {
                            suppressAutoPinDuringStreaming = false
                        }
                        if !isStreaming, !suppressAutoPinDuringStreaming {
                            schedulePinScrollToBottom(using: proxy)
                        }
                    }
                    .onChange(of: runtime.transcript.last?.id) { _, _ in
                        guard isActive, runtime.isStreaming else { return }
                        schedulePinScrollToBottom(using: proxy)
                    }
                    .onChange(of: runtime.transcript.last?.body) { _, _ in
                        guard isActive, runtime.isStreaming else { return }
                        schedulePinScrollToBottom(using: proxy)
                    }
                    .onChange(of: composerHeight) { _, _ in
                        // 恢复过保存位置的会话：composer 实测落地不得拽回底部。
                        guard !restoredSavedPosition else { return }
                        schedulePinScrollToBottom(using: proxy)
                    }
                }

                chatComposer
                    .background {
                        GeometryReader { composerGeometry in
                            Color.clear.preference(
                                key: ComposerHeightPreferenceKey.self,
                                value: composerGeometry.size.height
                            )
                        }
                    }
            }
            .onPreferenceChange(ChatBottomAnchorPreferenceKey.self) { anchorY in
                let distanceFromBottom = anchorY - scrollViewportHeight
                isNearBottom = distanceFromBottom <= nearBottomThreshold
            }
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            scheduleComposerHeightUpdate(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 把"面板是否活跃"注入环境：只有活跃面板的 Markdown WebView 启用滚轮转发，
        // 否则保活多面板 frame 重叠会让滚轮命中所有层面板、滚动卡死。
        .environment(\.panelIsActive, isActive)
    }

    private func schedulePinScrollToBottom(using proxy: ScrollViewProxy) {
        guard shouldAutoPinToBottom else { return }
        // 非流式钉底是「恢复被覆盖」类问题的头号嫌疑，逐条记录（流式期间的高频钉底不记）。
        if !runtime.isStreaming {
            NewPiLogger.info(category: "app", message: "Non-streaming pin-to-bottom", details: "session=\(runtime.sessionID) restored=\(restoredSavedPosition) offset=\(scrollOffset)")
        }
        DispatchQueue.main.async {
            pinScrollToBottom(using: proxy)
        }
    }

    /// 原位恢复：应用保存的滚动位置并验证落地；未生效则有界重试（最多 8 次 × 120ms）。
    /// 冷启动时内容布局/门控/钉底都在并发进行，单次 scrollTo 可能被时序吞掉或被后续
    /// 布局覆盖——重试窗口把这些一次性扰动吸收掉。全程日志（View Logs 可见）。
    private func restoreScrollPosition(to saved: CGFloat) {
        let target = max(0, saved)
        var attempt = 0
        func tryApply() {
            attempt += 1
            jumpPosition.scrollTo(point: CGPoint(x: 0, y: target))
            NewPiLogger.info(category: "app", message: "Scroll restore attempt", details: "session=\(runtime.sessionID) target=\(target) attempt=\(attempt) offset=\(scrollOffset)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if abs(scrollOffset - target) <= 2 {
                    NewPiLogger.info(category: "app", message: "Scroll restore settled", details: "session=\(runtime.sessionID) offset=\(scrollOffset) attempts=\(attempt)")
                    return
                }
                if attempt < 8 {
                    tryApply()
                } else {
                    NewPiLogger.info(category: "app", message: "Scroll restore gave up", details: "session=\(runtime.sessionID) target=\(target) finalOffset=\(scrollOffset)")
                }
            }
        }
        DispatchQueue.main.async(execute: tryApply)
    }

    /// 按最新缓存/布局常量重建高度表（rail 定位与窗口占位的共同数据源）。
    private func rebuildHeightMap(contentWidth: CGFloat) {
        heightMap.rebuild(items: runtime.transcript, contentWidth: contentWidth)
    }

    /// rail 着陆后的有界跟进校正：预热/实测仍在改动几何时目标 y 会漂移（第一次点击不准、
    /// 第二次准的根因）。仅在用户未接管滚动（当前偏移 ≈ 上次应用值）时跟进一次；
    /// 数据稳定（Δ<2pt）或超时即停止。与旧收敛机制的区别：它追的是「数据稳定」，
    /// 而不是「目标行的异步实测」。
    private func applyPendingRailCorrection() {
        guard let pending = pendingRailTarget else { return }
        guard Date() < pending.deadline else {
            pendingRailTarget = nil
            return
        }
        guard let y = heightMap.offset(of: pending.id) else { return }
        let target = max(0, y)
        if abs(target - pending.lastY) <= 2 {
            pendingRailTarget = nil // 数据已稳定
            return
        }
        guard abs(scrollOffset - pending.lastY) < 50 else {
            pendingRailTarget = nil // 用户已接管滚动，不打断
            return
        }
        pendingRailTarget = RailTarget(id: pending.id, lastY: target, deadline: pending.deadline)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            jumpPosition.scrollTo(point: CGPoint(x: 0, y: target))
        }
    }

    private var shouldAutoPinToBottom: Bool {
        if runtime.isStreaming {
            return !suppressAutoPinDuringStreaming && isNearBottom
        }
        // 非流式也仅当用户已贴近底部时才自动钉底：流式中曾上翻阅读（suppress=true）后，
        // 若仅因在某处打字、行高变化就强制拽回底部会打断阅读。要改回"打字即回底"的产品
        // 意图则把此处改 return true 即可。
        return isNearBottom
    }

    private func scheduleComposerHeightUpdate(_ height: CGFloat) {
        DispatchQueue.main.async {
            guard abs(composerHeight - height) > 0.5 else { return }
            composerHeight = height
        }
    }

    private func pinScrollToBottom(using proxy: ScrollViewProxy) {
        let anchor = NewPiChatScrollSupport.bottomAnchorID

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private var chatComposer: some View {
        VStack(spacing: 0) {
            NewPiAgentStatusBar(presentation: viewModel.agentStatusPresentation)

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
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
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

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
            .padding()
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
