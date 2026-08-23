import NewPiCore
import SwiftUI

@main
struct NewPiApp: App {
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
}

struct NewPiRootView: View {
    @ObservedObject private var viewModel = NewPiRootViewModelStore.shared.viewModel

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

                Section("Provider") {
                    if viewModel.hasAnthropicAPIKey {
                        Label("Anthropic ready", systemImage: "key.fill")
                    } else {
                        Label("Anthropic key missing", systemImage: "exclamationmark.key.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Settings → NewPi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiNewSession)) { _ in
            Task {
                await viewModel.resetSession()
            }
        }
    }
}

struct NewPiChatView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.transcript) { item in
                        NewPiTranscriptRow(item: item)
                    }
                }
                .padding()
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
        .navigationTitle("Chat")
    }
}

struct NewPiTranscriptRow: View {
    let item: NewPiTranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    NewPiRootView()
}
