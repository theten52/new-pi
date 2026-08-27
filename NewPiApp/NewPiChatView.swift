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
    /// rail 跳转的收敛目标与校正窗口：首次 scrollPosition 定位时，目标上方未实例化行
    /// （LazyVStack）和未测高的 WebView 都是估算高度，落点会偏；定位后这些行陆续实测
    /// 到位、目标行位置继续漂移。窗口期内按目标行的实测 minY 反复无动画校正，
    /// 直到稳定贴到视口顶部。
    @State private var jumpTargetID: UUID?
    @State private var jumpCorrectionStart = Date.distantPast
    @State private var jumpCorrectionDeadline = Date.distantPast
    /// 目标行最近一次上报的 minY（聊天滚动坐标系）。LazyVStack（惰性容器）内的
    /// PreferenceKey 不向父级传播（onPreferenceChange 收不到），改由目标行
    /// GeometryReader 的 onChange 直接写回面板状态；收敛判定与校正都以最新值为准。
    @State private var jumpTargetMinY: CGFloat?
    /// 收敛稳定判定：连续达标次数。目标贴顶后因异步测高可能瞬时"对齐"又漂移，
    /// 需连续 N 次不再偏离才判定收敛完成，避免被单次达标骗过。
    @State private var jumpStableCount = 0
    /// 窗口内已执行的重滚次数上限，防"校正→布局抖动→再校正"式振荡死循环。
    @State private var jumpCorrectionCount = 0
    /// scrollPosition 跳转定位：scrollTo 对 LazyVStack 未实例化的远距离行在 macOS 上
    /// 不生效（找不到 .id 视图），须改用 scrollPosition(id:) 才能定位并实例化目标行。
    @State private var jumpScrollPosition: UUID?

    /// 消息列表底部保留的留白（锚点到底部的距离）。
    private let messageBottomGap: CGFloat = 16
    /// 判定"已接近底部"的阈值：距底部小于该值视为在底部，流式时才自动钉底；
    /// 否则用户在中间浏览时流式内容不打断。
    private let nearBottomThreshold: CGFloat = 100
    /// 收敛校正的贴顶容差：目标行 minY 偏离视口顶部不超过该值视为已贴顶。
    private let jumpTopTolerance: CGFloat = 2
    /// 收敛窗口内允许的无动画重滚次数上限（防振荡死循环的硬保险，正常 1~2 次收敛）。
    private let jumpCorrectionCountLimit = 6
    /// 首次定位到校正开始的延时：跳过 scrollPosition 定位动画与目标行实例化本身。
    private let jumpCorrectionStartDelay: TimeInterval = 0.3
    /// 收敛窗口总时长：超时强制结束，避免与用户后续手动滚动长期拉扯。
    private let jumpCorrectionWindow: TimeInterval = 1.8

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
                                                && (item.title == "NewPi" || item.title == "Summary")
                                        ) { index in
                                            Task { await viewModel.forkFromMessage(index: index) }
                                        }
                                        .id(item.id)
                                        .onAppear {
                                            #if DEBUG
                                            if item.id == jumpTargetID {
                                                railJumpLog.debug("rail-jump row-appeared target=\(item.id, privacy: .public)")
                                            }
                                            #endif
                                        }
                                        .background(
                                            Group {
                                                // 只有 rail 跳转的目标行上报位置，驱动跳转后的收敛校正。
                                                // 注意不能用 PreferenceKey 上报：LazyVStack（惰性容器）内
                                                // 的 preference 不向父级传播，onPreferenceChange 收不到；
                                                // 改用 GeometryReader + onChange 把 minY 作为局部副作用
                                                // 直接写回面板状态（不依赖向父级传播）。
                                                if item.id == jumpTargetID {
                                                    GeometryReader { rowGeometry in
                                                        Color.clear
                                                            .onChange(
                                                                of: rowGeometry.frame(
                                                                    in: .named(NewPiChatScrollSupport.coordinateSpaceName)
                                                                ).minY,
                                                                initial: true
                                                            ) { _, minY in
                                                                handleJumpTargetGeometryUpdate(minY, using: proxy)
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
                        // 用 scrollPosition 做横线跳转定位：能定位并实例化 LazyVStack 未加载行
                        //（scrollTo 对未实例化行失效）。anchor = .top 使目标行顶部贴视口顶。
                        .scrollPosition(id: $jumpScrollPosition, anchor: .top)
                        .transaction { transaction in
                            if runtime.isStreaming {
                                transaction.disablesAnimations = true
                            }
                        }

                        NewPiUserMessageRail(
                            markers: userMessageMarkers,
                            onSelect: { messageID in
                                suppressAutoPinDuringStreaming = true
                                // 用 scrollPosition 定位（能实例化并滚到 LazyVStack 未加载行），
                                // 再启动收敛校正。绑定已等于目标时（重复点同一横线）直接赋值是
                                // no-op 不会重滚：先清空提交、下一 runloop 再设回，保证每次点击都滚动。
                                if jumpScrollPosition == messageID {
                                    jumpScrollPosition = nil
                                    DispatchQueue.main.async {
                                        self.jumpScrollPosition = messageID
                                        self.jumpToUserMessage(messageID, using: proxy)
                                    }
                                } else {
                                    jumpScrollPosition = messageID
                                    jumpToUserMessage(messageID, using: proxy)
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
                    .onAppear {
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
        return true
    }

    private func scheduleComposerHeightUpdate(_ height: CGFloat) {
        DispatchQueue.main.async {
            guard abs(composerHeight - height) > 0.5 else { return }
            composerHeight = height
        }
    }

    private func jumpToUserMessage(_ messageID: UUID, using proxy: ScrollViewProxy) {
        jumpTargetID = messageID
        jumpTargetMinY = nil
        jumpStableCount = 0
        jumpCorrectionCount = 0
        // 首次定位由 scrollPosition(id:) 完成（能实例化 LazyVStack 未加载行），
        // 这里启动收敛窗口：定位落点偏差与后续测高抖动由目标行 onChange 持续上报校正。
        jumpCorrectionStart = Date().addingTimeInterval(jumpCorrectionStartDelay)
        jumpCorrectionDeadline = Date().addingTimeInterval(jumpCorrectionWindow)
        #if DEBUG
        railJumpLog.debug("rail-jump → target=\(messageID, privacy: .public) 启动收敛")
        #endif
        // 兜底 pass：onChange 只在值变化时触发，若落点偏差恰好静止（之后无布局/测高
        // 变化），永远等不到事件 —— 到窗口起点时用最新已上报值校正一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + jumpCorrectionStartDelay) {
            self.correctJumpTargetIfNeeded(using: proxy)
        }
    }

    /// 目标行几何上报入口（行内 GeometryReader 的 onChange 回调）。
    /// 只在活跃面板收敛：后台保活面板的布局变化不能驱动隐藏面板滚动。
    private func handleJumpTargetGeometryUpdate(_ minY: CGFloat, using proxy: ScrollViewProxy) {
        guard isActive else { return }
        jumpTargetMinY = minY
        correctJumpTargetIfNeeded(using: proxy)
    }

    /// 跳转后校正：目标行 minY 偏离视口顶部超过容差时无动画重滚到位；连续 2 次
    /// 达标视为收敛完成，提前结束窗口（否则等窗口超时兜底结束）。目标行上方内容
    /// 停止变化后 minY 不再变化、onChange 不再触发，循环自然停。
    private func correctJumpTargetIfNeeded(using proxy: ScrollViewProxy) {
        guard isActive, let targetID = jumpTargetID, let minY = jumpTargetMinY else { return }
        #if DEBUG
        railJumpLog.debug("rail-jump minY=\(String(format: "%.1f", minY), privacy: .public)")
        #endif

        let now = Date()
        guard now < jumpCorrectionDeadline else {
            endJumpCorrection()
            return
        }
        guard now >= jumpCorrectionStart else { return }

        if abs(minY) <= jumpTopTolerance {
            jumpStableCount += 1
            if jumpStableCount >= 2 {
                endJumpCorrection()
            }
            return
        }
        jumpStableCount = 0

        guard jumpCorrectionCount < jumpCorrectionCountLimit else {
            // 反复重滚仍不贴顶（如目标在末尾、内容不足以顶到视口顶）：放弃校正，
            // 防止"校正→布局抖动→再校正"振荡。
            endJumpCorrection()
            return
        }
        jumpCorrectionCount += 1

        // 未贴顶：无动画重滚（此时目标行已实例化，scrollTo 可用），把顶部对齐视口顶。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(targetID, anchor: .top)
        }
    }

    private func endJumpCorrection() {
        jumpTargetID = nil
        jumpTargetMinY = nil
        jumpStableCount = 0
        jumpCorrectionCount = 0
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
