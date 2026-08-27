import AppKit
import SwiftUI

/// 保活容器：把每个缓存会话的面板视图（含彼此内部的 WKWebView）常驻挂载，
/// 切换会话时仅翻转活跃面板的显示/交互，而不销毁重建 —— 这样 DOM、测高、滚动位置
/// 全部免费保留，做到"切换即显示、原位恢复"。被淘汰的会话在 beginSession 冷重建。
struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel

    var body: some View {
        ZStack {
            ForEach(viewModel.keptAliveRuntimes, id: \.sessionID) { runtime in
                NewPiSessionPanel(runtime: runtime, viewModel: viewModel)
                    .opacity(viewModel.isActiveRuntime(runtime) ? 1 : 0)
                    .allowsHitTesting(viewModel.isActiveRuntime(runtime))
                    .zIndex(viewModel.isActiveRuntime(runtime) ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private let messageBottomGap: CGFloat = 16
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
                                                && (item.title == "NewPi" || item.title == "Summary")
                                        ) { index in
                                            Task { await viewModel.forkFromMessage(index: index) }
                                        }
                                        .id(item.id)
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
                        }
                        .coordinateSpace(name: NewPiChatScrollSupport.coordinateSpaceName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollBounceBehavior(.basedOnSize)
                        .transaction { transaction in
                            if runtime.isStreaming {
                                transaction.disablesAnimations = true
                            }
                        }

                        NewPiUserMessageRail(
                            markers: userMessageMarkers,
                            onSelect: { messageID in
                                suppressAutoPinDuringStreaming = true
                                jumpToUserMessage(messageID, using: proxy)
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
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(messageID, anchor: .top)
            }
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
