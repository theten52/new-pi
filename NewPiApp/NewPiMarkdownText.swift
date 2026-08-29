import AppKit
import SwiftUI

extension Color {
    /// 由"轮对话"锚点 id 确定性派生柔和浅色气泡背景色（BACKLOG-BUBBLE-BG）。
    /// 同轮对话内输入/输出气泡同色、跨轮异色、重启后稳定。
    /// 低饱和 + 高亮 + 低不透明 = 浅色柔和。
    static func bubbleTint(for anchorID: UUID) -> Color {
        Color(hue: deterministicHue(for: anchorID), saturation: 0.20, brightness: 0.98, opacity: 0.20)
    }

    /// FNV-1a 哈希把 UUID 字符串映射到 [0,1) 的色相，确定性（不依赖 Swift 随机 hashValue，
    /// 后者每次启动都会变）。
    private static func deterministicHue(for anchorID: UUID) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in anchorID.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 360) / 360.0
    }
}

/// 流式与完成态统一使用 WKWebView（markdown-it + highlight.js）渲染，
/// 流式期间由 JS 侧做块级增量更新，避免完成后切换引擎造成的视觉跳动。
/// bundle 或 WebView 不可用时退回原生 AttributedString（完整解析，无高亮）。
struct NewPiMarkdownText: View {
    let content: String
    var flushRendering: Bool
    /// 初始渲染完成后回调一次（透传给 Web 渲染器的 onInitialRendered）。
    var onInitialRendered: (() -> Void)? = nil

    @State private var webRendererFailed = false
    @State private var webHeight: CGFloat

    init(content: String, flushRendering: Bool, onInitialRendered: (() -> Void)? = nil) {
        self.content = content
        self.flushRendering = flushRendering
        self.onInitialRendered = onInitialRendered
        // 冷重建时首帧直接用缓存高度（内容哈希 + 当前宽度命中），避免 0→真实高度的渐进闪烁。
        // 流式内容每次都在变、必 miss 缓存，跳过 SHA256 避免热路径（~40ms 一次）全量哈希；
        // 流式结束翻转 flushRendering 后重新走缓存命中。
        _webHeight = State(initialValue: flushRendering
            ? (MarkdownRenderingCache.shared.height(for: content) ?? 44)
            : 44)
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
                    },
                    onInitialRendered: onInitialRendered
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
            // 空行不单独产一个 .newline：下方统一 append 一个换行即可，
            // 否则 "a\n\nb"（两段之间一个空行）会被输出成三个换行。
            if !line.isEmpty {
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
            // searchStart 指向行首（"```" 开头），匹配 3 字符围栏后 offsetBy 3，
            // 再吞掉其后的换行，返回闭合行之后的索引（含闭合行及其换行的块）。
            if source[searchStart...].hasPrefix("```") {
                var closeEnd = source.index(searchStart, offsetBy: 3)
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
    /// 轮对话级气泡背景色（BACKLOG-BUBBLE-BG）：同轮输入/输出气泡同色、跨轮异色。
    /// 由面板层按"最近 user 消息"派生后传入；默认保持旧 accent 观感。
    var bubbleTint: Color = Color.accentColor.opacity(0.16)
    var isStreaming = false
    var isActiveStreamingItem = false
    /// 初始渲染完成后回调一次（透传给 NewPiMarkdownText）。
    var onInitialRendered: (() -> Void)? = nil
    var onFork: ((Int) -> Void)?

    @State private var isHovering = false
    /// hover 退出延迟任务：滞回去抖，根治 Copy/Fork 按钮悬停消失抖动。
    @State private var hoverExitTask: Task<Void, Never>?

    private var showsActionButtons: Bool {
        isHovering || isActiveStreamingItem
    }

    /// hover 滞回：指针从行内容移向右侧 action 按钮的瞬间会产生 exit→enter 抖动
    ///（按钮 opacity 归 0 → allowsHitTesting(false) → 再触发 exit 的循环）。
    /// 退出时延迟 180ms 隐藏，期间重新进入（含进入按钮本身）则取消。
    private func updateHover(_ hovering: Bool) {
        if hovering {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            isHovering = true
        } else {
            hoverExitTask?.cancel()
            hoverExitTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                isHovering = false
            }
        }
    }

    private var isUser: Bool { item.isUser }

    private var usesMarkdown: Bool {
        item.isAssistantMarkdown
    }

    var body: some View {
        HStack {
            if item.isToolTranscript {
                NewPiToolTranscriptView(item: item)
                Spacer(minLength: 72)
            } else if case .thinking = item.kind {
                NewPiThinkingTranscriptView(item: item)
                Spacer(minLength: 72)
            } else if isUser {
                Spacer(minLength: 72)
                userBubble
            } else {
                assistantContent
            }
        }
        .onHover(perform: updateHover)
    }

    /// 用户消息：右对齐气泡（颜色用会话级 bubbleTint）
    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            messageBody
        }
        .padding(12)
        .background(bubbleTint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 640, alignment: .trailing)
    }

    /// 助手消息：左对齐气泡卡片（BACKLOG-BUBBLE-BG 加背景，颜色同会话用户气泡）
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            messageBody
        }
        .padding(12)
        .background(bubbleTint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        // 按钮自身也参与 hover 判定：移上按钮即保持显示，不依赖整行的 hover 回调时序。
        .onHover(perform: updateHover)
        .opacity(showsActionButtons ? 1 : 0)
        // opacity(0) 的按钮仍需禁用命中测试与无障碍读取，否则隐藏按钮可被点击/被 VoiceOver 聚焦
        //（与 NewPiChatView 中 opacity+allowsHitTesting 成对使用的约定对齐）。
        .allowsHitTesting(showsActionButtons)
        .accessibilityHidden(!showsActionButtons)
    }

    @ViewBuilder
    private var messageBody: some View {
        if usesMarkdown {
            NewPiMarkdownText(
                content: item.body,
                flushRendering: !isActiveStreamingItem,
                onInitialRendered: onInitialRendered
            )
        } else if item.kind == .error {
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
            kind: .assistant,
            body: "**Bold** and `code`\n\n```swift\nprint(\"hi\")\n```"
        ))
        NewPiTranscriptRow(item: NewPiTranscriptItem(kind: .user, body: "Plain user text"))
    }
    .padding()
    .frame(width: 520)
}
