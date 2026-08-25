import AppKit
import NewPiCore
import SwiftUI

final class NewPiAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await MCPPluginManager.shared.shutdownAll()
        }
    }
}

@main
struct NewPiApp: App {
    @NSApplicationDelegateAdaptor(NewPiAppDelegate.self) private var appDelegate

    init() {
        _ = NewPiLogStore.shared
    }

    var body: some Scene {
        WindowGroup {
            NewPiRootView()
        }
        Settings {
            NewPiSettingsView(viewModel: sharedViewModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    NotificationCenter.default.post(name: .newPiNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Debug Logs") {
                    NotificationCenter.default.post(name: .newPiShowLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }

    @MainActor
    private var sharedViewModel: NewPiViewModel {
        NewPiRootViewModelStore.shared.viewModel
    }
}

@MainActor
final class NewPiRootViewModelStore {
    static let shared = NewPiRootViewModelStore()
    let viewModel = NewPiViewModel()

    private init() {}
}

extension Notification.Name {
    static let newPiNewSession = Notification.Name("com.new-pi.newSession")
    static let newPiShowLogs = Notification.Name("com.new-pi.showLogs")
    static let newPiStreamingLayoutDidChange = Notification.Name("com.new-pi.streamingLayoutDidChange")
}

struct NewPiRootView: View {
    @ObservedObject private var viewModel = NewPiRootViewModelStore.shared.viewModel
    @State private var showLogs = false
    @State private var showsAllSessions = false

    private let recentSessionLimit = 5

    private var displayedSessions: [SessionSummary] {
        if showsAllSessions || viewModel.savedSessions.count <= recentSessionLimit {
            return viewModel.savedSessions
        }
        return Array(viewModel.savedSessions.prefix(recentSessionLimit))
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Project") {
                    if let project = viewModel.projectURL {
                        Text(project.lastPathComponent)
                            .font(.headline)
                    } else {
                        Text("No project selected")
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Project…") {
                        viewModel.pickProject()
                    }
                }

                Section("Sessions") {
                    Button("New Session") {
                        Task { await viewModel.startNewSession() }
                    }
                    .disabled(viewModel.projectURL == nil)

                    if viewModel.savedSessions.isEmpty {
                        Text("No saved sessions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(displayedSessions) { summary in
                            Button {
                                Task { await viewModel.resumeSession(summary) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.label ?? summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline)
                                    Text("\(summary.messageCount) messages")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if viewModel.savedSessions.count > recentSessionLimit {
                            Button(showsAllSessions ? "Show less" : "Show all (\(viewModel.savedSessions.count))") {
                                showsAllSessions.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: viewModel.projectURL) { _, _ in
                    showsAllSessions = false
                }

                Section("Provider") {
                    Picker("Provider", selection: Binding(
                        get: { viewModel.activeProviderID ?? "" },
                        set: { profileID in
                            Task { await viewModel.switchProvider(profileID: profileID) }
                        }
                    )) {
                        ForEach(viewModel.providerListItems) { item in
                            Text(item.profile.name).tag(item.profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.isStreaming || viewModel.providerListItems.isEmpty)

                    if !viewModel.activeProviderModel.isEmpty {
                        Text(viewModel.activeProviderModel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.activeProviderReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Key missing", systemImage: "key.slash")
                            .foregroundStyle(.orange)
                    }
                    Text("Settings → NewPi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Debug") {
                    Button("View Logs") {
                        showLogs = true
                    }
                }
            }
            .navigationTitle("NewPi")
        } detail: {
            NewPiChatView(viewModel: viewModel)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Export Markdown…") {
                            Task { await viewModel.exportSessionToFile(format: .markdown) }
                        }
                        Button("Export Text…") {
                            Task { await viewModel.exportSessionToFile(format: .text) }
                        }
                        Button("Export JSON…") {
                            Task { await viewModel.exportSessionToFile(format: .json) }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.transcript.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showLogs = true
                    } label: {
                        Label("Logs", systemImage: "list.bullet.rectangle")
                    }
                    .help("Debug Logs")
                }
            }
        }
        .sheet(isPresented: $showLogs) {
            NewPiLogsView(store: NewPiLogStore.shared)
        }
        .sheet(item: $viewModel.pendingToolApproval) { request in
            NewPiToolApprovalSheet(viewModel: viewModel, request: request)
                .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiNewSession)) { _ in
            Task {
                await viewModel.startNewSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiShowLogs)) { _ in
            showLogs = true
        }
    }
}

struct NewPiStreamingStatusView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("NewPi is thinking…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityLabel("NewPi is thinking")
    }
}

private enum NewPiChatScrollAnchor {
    static let bottom = "chat-bottom"
}

struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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

                        if viewModel.isStreaming {
                            NewPiStreamingStatusView()
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(NewPiChatScrollAnchor.bottom)

                        NewPiChatScrollAnchorView()
                            .frame(width: 0, height: 0)
                    }
                    .padding()
                }
                .transaction { transaction in
                    if viewModel.isStreaming {
                        transaction.disablesAnimations = true
                    }
                }
                .onAppear {
                    syncScroll(using: proxy, animated: false)
                }
                .onChange(of: viewModel.transcript.count) {
                    syncScroll(using: proxy, animated: !viewModel.isStreaming)
                }
                .onChange(of: viewModel.isStreaming) { _, isStreaming in
                    syncScroll(using: proxy, animated: !isStreaming)
                }
                .onReceive(NotificationCenter.default.publisher(for: .newPiStreamingLayoutDidChange)) { _ in
                    guard viewModel.isStreaming else { return }
                    NewPiChatScrollController.shared.requestFollow()
                }
            }

            Divider()

            HStack(alignment: .bottom) {
                TextField("Message NewPi…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 6)
                    .disabled(viewModel.isStreaming)

                if viewModel.isStreaming {
                    Button("Stop") {
                        viewModel.abort()
                    }
                }

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
        .navigationTitle(viewModel.isForkedBranch ? "Chat (branch)" : "Chat")
    }

    private func syncScroll(using proxy: ScrollViewProxy, animated: Bool) {
        if viewModel.isStreaming {
            NewPiChatScrollController.shared.scrollToBottomImmediately()
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(NewPiChatScrollAnchor.bottom, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(NewPiChatScrollAnchor.bottom, anchor: .bottom)
        }
    }
}

#Preview {
    NewPiRootView()
}
