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
}

struct NewPiRootView: View {
    @ObservedObject private var viewModel = NewPiRootViewModelStore.shared.viewModel
    @State private var showLogs = false

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
                        ForEach(viewModel.savedSessions) { summary in
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
                    }
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
            ZStack(alignment: .bottom) {
                NewPiChatView(viewModel: viewModel)

                if viewModel.pendingToolApproval != nil {
                    NewPiToolApprovalSheet(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
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

struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.transcript.isEmpty {
                            NewPiChatEmptyStateView(hasProject: viewModel.projectURL != nil)
                        }

                        ForEach(viewModel.transcript) { item in
                            NewPiTranscriptRow(
                                item: item,
                                isStreaming: viewModel.isStreaming
                            ) { index in
                                Task { await viewModel.forkFromMessage(index: index) }
                            }
                            .id(item.id)
                        }

                        if viewModel.isStreaming {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("NewPi is thinking…")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .id("streaming-indicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.transcript.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.transcript.last?.body) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.isStreaming) {
                    scrollToBottom(proxy: proxy)
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

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if viewModel.isStreaming {
                proxy.scrollTo("streaming-indicator", anchor: .bottom)
            } else if let lastID = viewModel.transcript.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

#Preview {
    NewPiRootView()
}
