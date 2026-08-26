import AppKit
import SwiftUI

struct NewPiLogsView: View {
    @ObservedObject var store: NewPiLogStore
    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = ""

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

            // Use an NSTextView-backed viewer so large in-memory logs render
            // efficiently instead of choking the main thread with a giant SwiftUI Text.
            LogTextView(text: logText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            reloadLogText()
        }
        // Trigger on the lightweight entry count instead of comparing the full
        // (potentially huge) log string on every render.
        .onChange(of: store.entries.count) { _, _ in
            reloadLogText()
        }
    }

    /// Snapshot the log into a local state value so the text view does not
    /// re-read / re-assemble the store every time SwiftUI re-renders.
    private func reloadLogText() {
        logText = store.logText
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

/// A lightweight NSTextView wrapper that handles large text efficiently.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)

        update(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView: textView)
    }

    private func update(textView: NSTextView) {
        let current = textView.string ?? ""
        if current != text {
            textView.string = text
        }
    }
}
