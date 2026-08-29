import AppKit
import SwiftUI

enum NewPiToolTranscriptKind: Equatable {
    case running(toolName: String)
    case result(toolName: String, isError: Bool)
}

extension NewPiTranscriptItem {
    /// 工具条目的展示形态：直接从 typed kind 读取（BACKLOG-TYPED-TRANSCRIPT），
    /// 不再从 title/body 文案反向解析。
    var toolTranscriptKind: NewPiToolTranscriptKind? {
        guard case let .tool(name, state) = kind else { return nil }
        switch state {
        case .running:
            return .running(toolName: name)
        case .completed(let isError):
            return .result(toolName: name, isError: isError)
        }
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
        // 兼容历史数据：typed 模型之前，错误输出的 body 带 "Error:" 前缀。
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
            kind: .tool(name: "read", state: .running),
            body: ""
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            kind: .tool(name: "read", state: .completed(isError: false)),
            body: """
            1|# new-pi
            2|
            3|## Status
            4|
            5|- Core library: NewPiCore
            """
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            kind: .tool(name: "bash", state: .completed(isError: false)),
            body: """
            total 24
            drwxr-xr-x  8 user  staff  256 Aug 26 10:00 .
            drwxr-xr-x  5 user  staff  160 Aug 26 09:00 ..
            [exit 0]
            """
        ))

        NewPiToolTranscriptView(item: NewPiTranscriptItem(
            kind: .tool(name: "write", state: .completed(isError: true)),
            body: "Permission denied: /etc/hosts"
        ))
    }
    .padding()
    .frame(width: 560)
}

/// 思考过程条目（BACKLOG-TYPED-TRANSCRIPT）：默认折叠的过程卡片，与工具卡同族视觉。
/// 流式中头部显示进行中指示；展开显示完整推理文本（等宽、可选中）。
/// 数据来自 typed kind（.thinking），不再依赖「思考不进转录」的旧边界。
struct NewPiThinkingTranscriptView: View {
    let item: NewPiTranscriptItem

    @State private var isExpanded = false

    private var isStreaming: Bool { item.isStreamingThinking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.secondary)

                    Text(isStreaming ? "Thinking…" : "Thinking")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12), in: Capsule())

                    if isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !isExpanded, let preview = collapsedPreview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    Text(item.body.isEmpty ? " " : item.body)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    /// 折叠态预览：最后一个非空行（思考是流式追加的，尾部最新）。
    private var collapsedPreview: String? {
        let lastLine = item.body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let lastLine else { return nil }
        return String(lastLine.prefix(100))
    }
}

#Preview("Thinking") {
    VStack(alignment: .leading, spacing: 12) {
        NewPiThinkingTranscriptView(item: NewPiTranscriptItem(
            kind: .thinking(isStreaming: true),
            body: "用户要求把 cherry-pick 到主分支…\n先看冲突范围…"
        ))
        NewPiThinkingTranscriptView(item: NewPiTranscriptItem(
            kind: .thinking(isStreaming: false),
            body: "第一步：确认分支差异。\n第二步：检查冲突文件。\n结论：冲突集中在 ChatView。"
        ))
    }
    .padding()
    .frame(width: 560)
}
