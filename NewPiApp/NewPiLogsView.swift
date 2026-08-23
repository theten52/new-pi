import AppKit
import SwiftUI

struct NewPiLogsView: View {
    @ObservedObject var store: NewPiLogStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Logs")
                        .font(.title2.weight(.semibold))
                    Text("In-memory entries from this app session. Unified logs are also written to macOS Console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Console.app") {
                    openConsoleApp()
                }
                Button("Copy All") {
                    copyLogs()
                }
                .disabled(store.entries.isEmpty)
                Button("Clear") {
                    store.clear()
                }
                .disabled(store.entries.isEmpty)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(store.logText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.logText, forType: .string)
    }

    private func openConsoleApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.openApplication(at: consoleURL, configuration: configuration) { _, _ in }
    }
}
