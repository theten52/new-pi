import AppKit
import SwiftUI

enum NewPiToolTranscriptKind: Equatable {
    case running(toolName: String)
    case result(toolName: String, isError: Bool)
}

extension NewPiTranscriptItem {
    var toolTranscriptKind: NewPiToolTranscriptKind? {
        if title == "Tool" {
            if body.hasPrefix("Running "), body.hasSuffix("…") {
                let name = String(body.dropFirst("Running ".count).dropLast())
                return .running(toolName: name)
            }
            return .running(toolName: "tool")
        }
        if title.hasPrefix("Tool ") {
            let name = String(title.dropFirst("Tool ".count))
            return .result(toolName: name, isError: body.hasPrefix("Error:"))
        }
        return nil
    }

    var isToolTranscript: Bool { toolTranscriptKind != nil }
}

struct NewPiToolTranscriptView: View {
    let item: NewPiTranscriptItem

    @State private var isExpanded = false

    private var kind: NewPiToolTranscriptKind? { item.toolTranscriptKind }

    var body: some View {
        Group {
            if let kind {
                switch kind {
                case let .running(toolName):
                    runningView(toolName: toolName)
                case let .result(toolName, isError):
                    resultView(toolName: toolName, isError: isError)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    @ViewBuilder
    private func runningView(toolName: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Image(systemName: iconName(for: toolName))
                .foregroundStyle(.secondary)
            Text("Running")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(toolName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func resultView(toolName: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(toolName: toolName, isError: isError)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                outputBody(isError: isError)
            }
        }
        .background(backgroundColor(isError: isError), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor(isError: isError), lineWidth: 1)
        }
    }

    private func headerRow(toolName: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    Image(systemName: iconName(for: toolName))
                        .foregroundStyle(isError ? .red : .secondary)

                    Text(toolName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (isError ? Color.red : Color.accentColor).opacity(0.12),
                            in: Capsule()
                        )

                    statusBadge(isError: isError)

                    Text(collapsedSummary(isError: isError))
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                copyBody(isError: isError)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(isError: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isError ? Color.red : Color.green)
                .frame(width: 6, height: 6)
            Text(isError ? "Failed" : "Done")
                .font(.caption2.weight(.medium))
                .foregroundStyle(isError ? .red : .secondary)
        }
    }

    @ViewBuilder
    private func outputBody(isError: Bool) -> some View {
        let lines = parsedLines(isError: isError)
        let hasLineNumbers = lines.contains { $0.lineNumber != nil }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        if hasLineNumbers {
                            Text(line.lineNumber.map(String.init) ?? " ")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)
                        }

                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(isError ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 280)
    }

    private func backgroundColor(isError: Bool) -> Color {
        isError ? Color.red.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }

    private func borderColor(isError: Bool) -> Color {
        isError ? Color.red.opacity(0.2) : Color.primary.opacity(0.08)
    }

    private func iconName(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read":
            return "doc.text"
        case "write", "edit":
            return "pencil"
        case "bash":
            return "terminal"
        default:
            return "wrench.and.screwdriver"
        }
    }

    private func displayText(isError: Bool) -> String {
        if isError, item.body.hasPrefix("Error:") {
            return String(item.body.dropFirst("Error:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return item.body
    }

    private func collapsedSummary(isError: Bool) -> String {
        let text = displayText(isError: isError)
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return text }

        let preview = stripLineNumberPrefix(first).trimmingCharacters(in: .whitespaces)
        guard !preview.isEmpty else {
            return lines.count > 1 ? "\(lines.count) lines" : text
        }

        if lines.count <= 1 {
            return String(preview.prefix(100))
        }

        return "\(String(preview.prefix(72))) · \(lines.count) lines"
    }

    private func stripLineNumberPrefix(_ line: String) -> String {
        guard let match = line.wholeMatch(of: /^(\d+)\|(.*)$/) else {
            return line
        }
        return String(match.2)
    }

    private struct ParsedLine: Identifiable {
        let id: Int
        let lineNumber: Int?
        let text: String
    }

    private func parsedLines(isError: Bool) -> [ParsedLine] {
        let text = displayText(isError: isError)
        let rawLines = text.components(separatedBy: "\n")

        return rawLines.enumerated().map { index, line in
            if let match = line.wholeMatch(of: /^(\d+)\|(.*)$/) {
                return ParsedLine(
                    id: index,
                    lineNumber: Int(match.1),
                    text: String(match.2)
                )
            }
            return ParsedLine(id: index, lineNumber: nil, text: line)
        }
    }

    private func copyBody(isError: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayText(isError: isError), forType: .string)
    }
}

#Preview("Tool results") {
    VStack(alignment: .leading, spacing: 12) {
        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            title: "Tool",
            body: "Running read…"
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            title: "Tool read",
            body: """
            1|# new-pi
            2|
            3|## Status
            4|
            5|- Core library: NewPiCore
            """
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            title: "Tool bash",
            body: """
            total 24
            drwxr-xr-x  8 user  staff  256 Aug 26 10:00 .
            drwxr-xr-x  5 user  staff  160 Aug 26 09:00 ..
            [exit 0]
            """
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            title: "Tool write",
            body: "Error: Permission denied: /etc/hosts"
        ))
    }
    .padding()
    .frame(width: 560)
}
