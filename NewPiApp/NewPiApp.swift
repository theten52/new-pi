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

private struct SessionRow: View {
    let summary: SessionSummary
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isActive {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label ?? summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if summary.label != nil {
                        Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                    }
                    Text("\(summary.messageCount) messages")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }
}

struct NewPiRootView: View {
    @ObservedObject private var viewModel = NewPiRootViewModelStore.shared.viewModel
    @State private var showLogs = false
    /// Session 列表当前展示的条数（增量展开：每次点 Show all 多显示 5 条）。
    @State private var sessionDisplayLimit = 5

    private let recentSessionLimit = 5
    private let sessionDisplayIncrement = 5

    private var displayedSessions: [SessionSummary] {
        Array(viewModel.savedSessions.prefix(max(sessionDisplayLimit, recentSessionLimit)))
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
                                SessionRow(
                                    summary: summary,
                                    isActive: summary.id == viewModel.activeSessionID
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Archive Session") {
                                    Task { await viewModel.archiveSession(summary) }
                                }
                            }
                        }

                        if viewModel.savedSessions.count > sessionDisplayLimit
                            || sessionDisplayLimit > recentSessionLimit {
                            HStack(spacing: 12) {
                                // 增量展开：每次点击多显示 5 条，直至全部显示。
                                if viewModel.savedSessions.count > sessionDisplayLimit {
                                    Button("Show all (\(viewModel.savedSessions.count))") {
                                        sessionDisplayLimit = min(
                                            sessionDisplayLimit + sessionDisplayIncrement,
                                            viewModel.savedSessions.count
                                        )
                                    }
                                }
                                if sessionDisplayLimit > recentSessionLimit {
                                    Button("Show less") {
                                        sessionDisplayLimit = recentSessionLimit
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: viewModel.projectURL) { _, _ in
                    sessionDisplayLimit = recentSessionLimit
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

                    // 快捷入口：把当前会话的 provider 设为全局默认（影响之后新建的会话）。
                    if let activeID = viewModel.activeProviderID,
                       !activeID.isEmpty,
                       activeID != viewModel.providerConfig.defaultProfileID {
                        Button("Set as Default") {
                            Task { await viewModel.setDefaultProvider(profileID: activeID) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview {
    NewPiRootView()
}
