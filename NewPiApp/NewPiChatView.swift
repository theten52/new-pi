import AppKit
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

                                        ForEach(Array(visibleRange), id: \.self) { index in
                                            let item = runtime.transcript[index]
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
                                // 内容 y，scrollTo(point:) 一次到位。不实例化目标行、
                                // 不等异步实测、无收敛窗口。
                                heightMap.rebuild(
                                    items: runtime.transcript,
                                    contentWidth: geometry.size.width - 32
                                )
                                if let y = heightMap.offset(of: messageID) {
                                    jumpPosition.scrollTo(point: CGPoint(x: 0, y: max(0, y)))
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
                        schedulePinScrollToBottom(using: proxy)
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
        DispatchQueue.main.async {
            pinScrollToBottom(using: proxy)
        }
    }

    /// 按最新缓存/布局常量重建高度表（rail 定位与窗口占位的共同数据源）。
    private func rebuildHeightMap(contentWidth: CGFloat) {
        heightMap.rebuild(items: runtime.transcript, contentWidth: contentWidth)
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
                TextField("Message NewPi…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 6)
                    .disabled(runtime.isStreaming)

                Button("Stop") {
                    viewModel.abort()
                }
                .opacity(runtime.isStreaming ? 1 : 0)
                .disabled(!runtime.isStreaming)
                .frame(minWidth: 52)

                Button("Send") {
                    let text = input
                    input = ""
                    viewModel.send(text)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime.isStreaming)
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(nil, value: runtime.isStreaming)
    }
}

#Preview {
    NewPiChatView(viewModel: NewPiViewModel())
}
