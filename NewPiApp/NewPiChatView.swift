import AppKit
import SwiftUI

struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var input = ""
    @State private var composerHeight: CGFloat = 120
    /// After the user jumps via the message rail, skip pin-to-bottom until the next agent turn.
    @State private var suppressAutoPinDuringStreaming = false

    /// Gap between the last bubble bottom and the status bar top.
    private let messageBottomGap: CGFloat = 16

    private var userMessageMarkers: [UserMessageMarker] {
        viewModel.transcript
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
                                    if viewModel.transcript.isEmpty {
                                        NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                                    }

                                    ForEach(viewModel.transcript) { item in
                                        NewPiTranscriptRow(
                                            item: item,
                                            isStreaming: viewModel.isStreaming,
                                            isActiveStreamingItem: viewModel.isStreaming
                                                && item.id == viewModel.transcript.last?.id
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
                            if viewModel.isStreaming {
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
                    .onAppear {
                        schedulePinScrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.isStreaming) { wasStreaming, isStreaming in
                        if isStreaming, !wasStreaming {
                            suppressAutoPinDuringStreaming = false
                        }
                        if !isStreaming, !suppressAutoPinDuringStreaming {
                            schedulePinScrollToBottom(using: proxy)
                        }
                    }
                    .onChange(of: viewModel.transcript.last?.id) { _, _ in
                        guard viewModel.isStreaming else { return }
                        schedulePinScrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.transcript.last?.body) { _, _ in
                        guard viewModel.isStreaming else { return }
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
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            scheduleComposerHeightUpdate(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(viewModel.chatNavigationTitle)
    }

    private func schedulePinScrollToBottom(using proxy: ScrollViewProxy) {
        guard shouldAutoPinToBottom else { return }
        DispatchQueue.main.async {
            pinScrollToBottom(using: proxy)
        }
    }

    private var shouldAutoPinToBottom: Bool {
        !(suppressAutoPinDuringStreaming && viewModel.isStreaming)
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
                    .disabled(viewModel.isStreaming)

                Button("Stop") {
                    viewModel.abort()
                }
                .opacity(viewModel.isStreaming ? 1 : 0)
                .disabled(!viewModel.isStreaming)
                .frame(minWidth: 52)

                Button("Send") {
                    let text = input
                    input = ""
                    viewModel.send(text)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(nil, value: viewModel.isStreaming)
    }
}

#Preview {
    NewPiChatView(viewModel: NewPiViewModel())
}
