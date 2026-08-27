import AppKit
import SwiftUI

/// 流式与完成态统一使用 WKWebView（markdown-it + highlight.js）渲染，
/// 流式期间由 JS 侧做块级增量更新，避免完成后切换引擎造成的视觉跳动。
/// bundle 或 WebView 不可用时退回原生 AttributedString（完整解析，无高亮）。
struct NewPiMarkdownText: View {
    let content: String
    var flushRendering: Bool

    @State private var webRendererFailed = false
    @State private var webHeight: CGFloat

    init(content: String, flushRendering: Bool) {
        self.content = content
        self.flushRendering = flushRendering
        // 冷重建时首帧直接用缓存高度（内容哈希 + 当前宽度命中），避免 0→真实高度的渐进闪烁。
        _webHeight = State(initialValue: MarkdownRenderingCache.shared.height(for: content) ?? 44)
    }

    var body: some View {
        Group {
            if let rendererScriptURL = NewPiMarkdownWebDocument.rendererScriptURL(),
               !webRendererFailed {
                NewPiMarkdownWebRendererView(
                    markdown: content,
                    rendererScriptURL: rendererScriptURL,
                    height: $webHeight,
                    flushRendering: flushRendering,
                    onRenderingFailed: {
                        webRendererFailed = true
                    }
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: webHeight, alignment: .topLeading)
                .clipped()
                .animation(nil, value: webHeight)
                .accessibilityLabel(content)
            } else {
                nativeFallback
            }
        }
    }

    private var nativeFallback: some View {
        Group {
            if let attributed = Self.parsedMarkdown(from: content) {
                Text(attributed)
            } else {
                Text(content)
            }
        }
        .textSelection(.enabled)
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Native fallback: line-by-line full Markdown so single `\n` are preserved.
    private static func parsedMarkdown(from content: String) -> AttributedString? {
        let segments = markdownLineSegments(from: content)
        guard !segments.isEmpty else { return nil }

        var result = AttributedString()
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        for segment in segments {
            switch segment {
            case .newline:
                result.append(AttributedString("\n"))
            case let .block(text):
                if let parsed = try? AttributedString(markdown: text, options: options) {
                    result.append(parsed)
                } else {
                    result.append(AttributedString(text))
                }
            }
        }

        return result.characters.isEmpty ? nil : result
    }

    private enum MarkdownLineSegment {
        case newline
        case block(String)
    }

    private static func markdownLineSegments(from source: String) -> [MarkdownLineSegment] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var segments: [MarkdownLineSegment] = []
        var index = normalized.startIndex

        while index < normalized.endIndex {
            if normalized[index...].hasPrefix("```") {
                if let fenceEnd = endOfFencedBlock(in: normalized, startingAt: index) {
                    segments.append(.block(String(normalized[index..<fenceEnd])))
                    index = fenceEnd
                } else {
                    segments.append(.block(String(normalized[index...])))
                    break
                }
                continue
            }

            let lineEnd = normalized[index...].firstIndex(of: "\n") ?? normalized.endIndex
            let line = String(normalized[index..<lineEnd])
            if line.isEmpty {
                segments.append(.newline)
            } else {
                segments.append(.block(line))
            }

            if lineEnd == normalized.endIndex {
                break
            }

            segments.append(.newline)
            index = normalized.index(after: lineEnd)
        }

        return segments
    }

    private static func endOfFencedBlock(in source: String, startingAt start: String.Index) -> String.Index? {
        guard source[start...].hasPrefix("```") else { return nil }

        var searchStart = source.index(start, offsetBy: 3)
        if let firstNewline = source[searchStart...].firstIndex(of: "\n") {
            searchStart = source.index(after: firstNewline)
        } else {
            return nil
        }

        while searchStart < source.endIndex {
            if source[searchStart...].hasPrefix("\n```") {
                var closeEnd = source.index(searchStart, offsetBy: 4)
                if closeEnd < source.endIndex, source[closeEnd] == "\n" {
                    closeEnd = source.index(after: closeEnd)
                }
                return closeEnd
            }

            guard let nextNewline = source[searchStart...].firstIndex(of: "\n") else {
                return nil
            }
            searchStart = source.index(after: nextNewline)
        }

        return nil
    }
}

struct NewPiTranscriptRow: View {
    let item: NewPiTranscriptItem
    var isStreaming = false
    var isActiveStreamingItem = false
    var onFork: ((Int) -> Void)?

    @State private var isHovering = false

    private var isUser: Bool { item.title == "You" }

    private var usesMarkdown: Bool {
        item.title == "NewPi" || item.title == "Summary"
    }

    var body: some View {
        HStack {
            if item.isToolTranscript {
                NewPiToolTranscriptView(item: item)
                Spacer(minLength: 72)
            } else if isUser {
                Spacer(minLength: 72)
                userBubble
            } else {
                assistantContent
            }
        }
        .onHover { isHovering = $0 }
    }

    /// 用户消息：右对齐 accent 气泡
    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            messageBody
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 640, alignment: .trailing)
    }

    /// 助手消息：全宽、无气泡卡片
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            messageBody
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            actionButtons
        }
    }

    /// 复制 / fork 按钮：hover 显示（流式中的行保持可见）
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyBody()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy message")

            if item.canFork, let index = item.messageIndex, let onFork {
                Button {
                    onFork(index)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .help("Fork from here")
                .disabled(isStreaming)
            }
        }
        .opacity(isHovering || isActiveStreamingItem ? 1 : 0)
    }

    @ViewBuilder
    private var messageBody: some View {
        if usesMarkdown {
            NewPiMarkdownText(
                content: item.body,
                flushRendering: !isActiveStreamingItem
            )
        } else if item.title == "Error" {
            Text(item.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else {
            Text(item.body)
                .textSelection(.enabled)
        }
    }

    private func copyBody() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.body, forType: .string)
    }
}

struct NewPiChatEmptyStateView: View {
    var hasProject: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(hasProject ? "Start a session" : "Open a project")
                .font(.title3.weight(.semibold))
            Text(hasProject
                ? "Ask NewPi to read, edit, or run commands in your project. Sessions are saved automatically."
                : "Choose a project folder to load AGENTS.md, skills, and saved sessions.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        NewPiTranscriptRow(item: NewPiTranscriptItem(
            title: "NewPi",
            body: "**Bold** and `code`\n\n```swift\nprint(\"hi\")\n```"
        ))
        NewPiTranscriptRow(item: NewPiTranscriptItem(title: "You", body: "Plain user text"))
    }
    .padding()
    .frame(width: 520)
}
