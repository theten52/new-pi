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
                    Text("Persistent files are written on disk; the list below is this session's in-memory buffer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let primaryLog = store.logFileURLs.first {
                    Button("Reveal Log File") {
                        revealInFinder(primaryLog)
                    }
                }
                Button("Open Console.app") {
                    openConsoleApp()
                }
                Button("Copy All") {
                    copyLogs()
                }
                Button("Clear Buffer") {
                    store.clear()
                }
                .disabled(store.entries.isEmpty)
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if !store.logFileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.logFileURLs, id: \.path) { url in
                        Text(url.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .frame(minWidth: 720, minHeight: 480)
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.logText, forType: .string)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openConsoleApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.openApplication(at: consoleURL, configuration: configuration) { _, _ in }
    }
}
