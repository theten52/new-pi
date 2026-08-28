import AppKit
import SwiftUI
import os

/// rail 跳转诊断日志：用 os.Logger（进 unified log），Hermes 才能用 `log stream`
/// 自己抓取，而不依赖用户回传 stdout（GUI App 从 Finder 启动时 stdout 不落地）。
private let railJumpLog = os.Logger(subsystem: "com.newpi.app", category: "railjump")

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
    /// rail 跳转的滚动定位协调器：单一写者原则——精确定位只有
    /// Coordinator（经 ScrollPosition.scrollTo(point:)），流式钉底只有 scrollTo，
    /// 互不重叠（chat-scroll-layout.md §3.3"多机制打架"教训的修订版设计）。
    @StateObject private var scrollCoordinator = ChatScrollCoordinator()
    /// rail 跳转的精确滚动执行者（macOS 15 API）：先 scrollTo(id:) 实例化目标行
    /// （scrollTo 对 LazyVStack 未实例化行失效的唯一替代），再 scrollTo(point:) 按内容
    /// 坐标一次滚到精确位置。平台单一权威写法，无 SwiftUI 绑定回写打架。
    @State private var jumpPosition = ScrollPosition()
    /// 内容 VStack 的命名坐标系：行在其中上报的 minY = 行的绝对内容 y
    /// （不随滚动变化），即精确贴顶所需滚动点。挂在内容上而非 ScrollView 上——
    /// 挂 ScrollView 上是视口相对坐标，量纲错误（2026-08-28 实测教训）。
    private let contentSpaceName = "new-pi-chat-content"

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

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)

                                LazyVStack(alignment: .leading, spacing: 12) {
                                    if runtime.transcript.isEmpty {
                                        if viewModel.isSwitchingSession {
                                            ProgressView("Loading session…")
                                                .frame(maxWidth: .infinity, minHeight: 120)
                                        } else {
                                            NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                                        }
                                    }

                                    ForEach(runtime.transcript) { item in
                                        NewPiTranscriptRow(
                                            item: item,
                                            isStreaming: runtime.isStreaming,
                                            isActiveStreamingItem: runtime.isStreaming
                                                && item.id == runtime.transcript.last?.id
                                                && (item.title == "NewPi" || item.title == "Summary"),
                                            onInitialRendered: { runtime.markInitialRowRendered(item.id) }
                                        ) { index in
                                            Task { await viewModel.forkFromMessage(index: index) }
                                        }
                                        .id(item.id)
                                        .onAppear {
                                            #if DEBUG
                                            if scrollCoordinator.isTarget(item.id) {
                                                let idString = item.id.uuidString
                                                railJumpLog.debug("rail-jump row-appeared target=\(idString, privacy: .public)")
                                            }
                                            #endif
                                        }
                                        .background(
                                            Group {
                                                // 目标行在内容坐标系上报绝对内容 y（= 精确贴顶滚动点）。
                                                // 不能用 PreferenceKey：LazyVStack 惰性容器内的 preference
                                                // 不向父级传播，改用 GeometryReader.onChange 直调 Coordinator。
                                                if scrollCoordinator.isTarget(item.id) {
                                                    GeometryReader { rowGeometry in
                                                        Color.clear
                                                            .onChange(
                                                                of: rowGeometry.frame(
                                                                    in: .named(contentSpaceName)
                                                                ).minY,
                                                                initial: true
                                                            ) { _, minY in
                                                                guard isActive else { return }
                                                                scrollCoordinator.reportRowTop(minY, for: item.id)
                                                            }
                                                    }
                                                }
                                            }
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // 标记该 LazyVStack 的行为 scrollPosition 的可定位目标。
                                .scrollTargetLayout()

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
                            .coordinateSpace(name: contentSpaceName)
                            .padding()
                            .frame(
                                maxWidth: .infinity,
                                minHeight: scrollViewportHeight,
                                alignment: .bottom
                            )
                        }
                        .coordinateSpace(name: NewPiChatScrollSupport.coordinateSpaceName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollBounceBehavior(.basedOnSize)
                        // rail 跳转 / 会话恢复用 ScrollPosition（macOS 15）：先 scrollTo(id:)
                        // 实例化 LazyVStack 未加载行，再 scrollTo(point:) 按内容坐标精确贴顶。
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
                                // 定位三步：①beginJump 记目标开窗；②scrollTo(id:) 实例化目标行
                                //（SwiftUI 滚到附近）；③行在内容坐标系上报绝对 y 后，
                                // Coordinator 经 onApplyExact → scrollTo(point:) 一次精确贴顶。
                                // 上方惰性行陆续实例化/测高使 y 漂移时 onChange 会再上报再校正。
                                scrollCoordinator.beginJump(to: messageID)
                                jumpPosition.scrollTo(id: messageID)
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
                        bindScrollCoordinator()
                        schedulePinScrollToBottom(using: proxy)
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

    /// Coordinator 接线：精确滚动经 ScrollPosition.scrollTo(point:) 执行
    /// （平台单一权威写法；实测 NSScrollView/绑定清空都会与 SwiftUI 回写打架）。
    private func bindScrollCoordinator() {
        scrollCoordinator.onApplyExact = { [self] y in
            jumpPosition.scrollTo(point: CGPoint(x: 0, y: y))
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
