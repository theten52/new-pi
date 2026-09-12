import AppKit
import NewPiCore
import SwiftUI

/// 文档工作台共享样式；高对比模式优先使用系统语义色。
enum NewPiWorkbenchStyle {
    static let maxReadingWidth: CGFloat = 800
    static let horizontalInset: CGFloat = 24

    static let surface = adaptiveColor(
        "surface", light: 0xFDFDFB, dark: 0x252B28, highContrast: .windowBackgroundColor
    )
    static let surfaceRaised = adaptiveColor(
        "surfaceRaised", light: 0xFFFFFF, dark: 0x2B322E, highContrast: .controlBackgroundColor
    )
    static let sidebar = adaptiveColor(
        "sidebar", light: 0xF1F2EE, dark: 0x202623, highContrast: .windowBackgroundColor
    )
    static let surfaceSoft = adaptiveColor(
        "surfaceSoft", light: 0xF4F5F1, dark: 0x2C332F, highContrast: .controlBackgroundColor
    )
    static let accentSoft = adaptiveColor(
        "accentSoft", light: 0xE6EEE7, dark: 0x34463A, highContrast: .selectedControlColor
    )
    static let line = adaptiveColor(
        "line", light: 0xE1E5DF, dark: 0x3B443D, highContrast: .separatorColor
    )
    static let accent = adaptiveColor(
        "accent", light: 0x32654D, dark: 0xA1C3A3, highContrast: .labelColor
    )
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)

    private static func adaptiveColor(
        _ name: String, light: UInt32, dark: UInt32, highContrast: NSColor
    ) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("NewPiWorkbench.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            if match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua {
                return highContrast
            }
            let rgb = match == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// 唯一的原生分栏外壳；不持有运行时，也不修改窗口 frame 或系统保存的窗口配置。
/// 侧栏按钮及收展过渡由系统提供，不用手动切换状态的按钮替代；生产页和独立探针共用。
struct NewPiWorkbenchShell<Sidebar: View, Content: View>: View {
    private let sidebar: Sidebar
    private let content: Content
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) {
        self.sidebar = sidebar()
        self.content = content()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: 226, maxWidth: 250, maxHeight: .infinity)
                .background(NewPiWorkbenchStyle.sidebar)
                .navigationSplitViewColumnWidth(min: 226, ideal: 226, max: 250)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NewPiWorkbenchStyle.surface)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .toolbarBackground(NewPiWorkbenchStyle.surface, for: .windowToolbar)
        .tint(NewPiWorkbenchStyle.accent)
    }
}

/// 内容区唯一的身份标题；目录必须由当前对象提供，操作不注册输入快捷键。
struct NewPiWorkbenchHeader<Actions: View>: View {
    let mode: String
    let title: String
    let directory: String
    private let actions: Actions

    init(mode: String, title: String, directory: String, @ViewBuilder actions: () -> Actions) {
        self.mode = mode
        self.title = title
        self.directory = directory
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mode)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(NewPiWorkbenchStyle.line, lineWidth: 1)
                            }
                            .fixedSize()
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .help(title)
                    }
                    Label(directory.isEmpty ? "未选择项目" : directory, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory.isEmpty ? "未选择项目" : directory)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) { actions }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, NewPiWorkbenchStyle.horizontalInset)
            .frame(height: 72)
            Divider()
        }
        .background(NewPiWorkbenchStyle.surface)
    }
}

/// 纯标签，不嵌套 Button；尾部阶段或警告由调用方的 HStack 提供。
struct NewPiWorkbenchSidebarEntry: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? NewPiWorkbenchStyle.accent : NewPiWorkbenchStyle.secondaryText)
                .frame(width: 16, height: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(NewPiWorkbenchStyle.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(title)
    }
}

/// 整张卡片均可选择项目；只调用传入动作，不读取或创建运行时。
struct NewPiWorkbenchProjectCard: View {
    let name: String
    let path: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 16))
                    .foregroundStyle(NewPiWorkbenchStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(NewPiWorkbenchStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(NewPiWorkbenchStyle.line, lineWidth: 1)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NewPiWorkbenchStyle.primaryText)
                        .lineLimit(1)
                    Text(path.isEmpty ? "点击选择工作目录" : "本地项目 · \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.system(size: 10))
                        .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
            }
            .padding(10)
            .background(isHovering ? NewPiWorkbenchStyle.line.opacity(0.5) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(path.isEmpty ? "打开项目…" : "打开项目…\n\(path)")
        .accessibilityLabel("打开项目：\(name)")
        .accessibilityValue(path.isEmpty ? "未选择项目" : path)
    }
}

/// 展示数据不依赖 Core，独立完整窗口探针可直接构造。
struct NewPiWorkbenchRole: Identifiable {
    let id: String
    let name: String
    let systemImage: String
    let isSpeaking: Bool
}

/// 角色多时只横向滚动头像区域，不挤占阶段文字或调用方尾部菜单。
struct NewPiWorkbenchRoleStrip: View {
    let phaseTitle: String
    var roundText: String? = nil
    let roles: [NewPiWorkbenchRole]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("当前阶段")
                    .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                Text(phaseTitle)
                    .fontWeight(.medium)
                    .foregroundStyle(NewPiWorkbenchStyle.accent)
                if let roundText {
                    Text(roundText)
                        .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
                }
            }
            .fixedSize()
            Divider().frame(height: 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(roles) { role in
                        HStack(spacing: 5) {
                            Image(systemName: role.systemImage.isEmpty ? "person.fill" : role.systemImage)
                                .font(.system(size: 11))
                                .frame(width: 26, height: 26)
                                .background(role.isSpeaking ? NewPiWorkbenchStyle.accentSoft : NewPiWorkbenchStyle.surfaceSoft,
                                            in: Circle())
                            Text(role.name)
                            if role.isSpeaking {
                                Text("发言中").font(.system(size: 9, weight: .medium))
                            }
                        }
                        .foregroundStyle(role.isSpeaking ? NewPiWorkbenchStyle.accent : NewPiWorkbenchStyle.secondaryText)
                        .fixedSize()
                        .help(role.name + (role.isSpeaking ? " · 正在发言" : ""))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(role.name)
                        .accessibilityValue(role.isSpeaking ? "正在发言" : "未发言")
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .font(.system(size: 11))
        .frame(height: 30)
    }
}

/// 输入区与底部工具栏共用的外壳；焦点、输入行为及高度由调用方管理。
struct NewPiComposerSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(NewPiWorkbenchStyle.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(NewPiWorkbenchStyle.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// 普通会话与聊天室共用的主操作；不注册 Return 快捷键，避免输入时误停止。
struct NewPiComposerPrimaryAction: View {
    let isRunning: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        Button {
            if isRunning {
                onStop()
            } else if canSend {
                onSend()
            }
        } label: {
            Label(actionLabel, systemImage: isRunning ? "square.fill" : "arrow.up")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(NewPiWorkbenchStyle.surfaceRaised)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isRunning ? NewPiWorkbenchStyle.primaryText : NewPiWorkbenchStyle.accent)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isRunning && !canSend)
        .opacity(!isRunning && !canSend ? 0.45 : 1)
        .accessibilityLabel(actionLabel)
        .help(actionLabel)
    }

    private var actionLabel: String {
        isRunning ? "停止生成" : "发送消息"
    }
}

struct NewPiAgentStatusPresentation: Equatable {
    let systemImage: String
    let label: String
    let isActive: Bool

    /// 审批与错误优先于活跃态；运行只使用低饱和强调色，不表示成功。
    var foregroundColor: Color {
        switch systemImage {
           case "hand.raised", "hand.raised.fill", "hand.raised.circle", "hand.raised.circle.fill",
               "exclamationmark.triangle", "exclamationmark.triangle.fill":
            .orange
           case "exclamationmark.circle", "exclamationmark.circle.fill",
               "exclamationmark.octagon", "exclamationmark.octagon.fill",
               "xmark.circle", "xmark.circle.fill", "xmark.octagon", "xmark.octagon.fill":
            .red
        default:
            isActive ? NewPiWorkbenchStyle.accent : NewPiWorkbenchStyle.secondaryText
        }
    }

    static func toolIcon(for toolName: String) -> String {
        switch toolName {
        case "bash":
            "terminal"
        case "read":
            "doc.text.magnifyingglass"
        case "write":
            "square.and.pencil"
        case "edit":
            "pencil.line"
        case "subagent":
            "person.2.circle"
        default:
            "wrench.and.screwdriver"
        }
    }
}

enum NewPiAgentStatusIconSize {
    case toolbar
    case bar
    /// 与状态栏文本高度一致的紧凑尺寸。
    case compact

    var frame: CGFloat {
        switch self {
        case .toolbar: 36
        case .bar: 30
        case .compact: 18
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .toolbar: 18
        case .bar: 16
        case .compact: 11
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .toolbar, .bar: 8
        case .compact: 5
        }
    }
}

struct NewPiAgentStatusIcon: View {
    let presentation: NewPiAgentStatusPresentation
    var size: NewPiAgentStatusIconSize = .toolbar

    var body: some View {
        // 保持静态，避免持续 symbolEffect 阻塞正文流式消费。
        Image(systemName: presentation.systemImage)
            .font(.system(size: size.symbolSize, weight: .semibold))
            .foregroundStyle(presentation.foregroundColor)
            .frame(width: size.frame, height: size.frame)
            .accessibilityHidden(true)
    }
}

/// 状态栏模型菜单的分组数据（选择粒度是模型，provider 只做分组展示）。
struct NewPiProviderModelGroup: Identifiable, Equatable {
    let profileID: String
    let profileName: String
    let systemImage: String
    let hasAPIKey: Bool
    let models: [String]

    var id: String { profileID }
}

/// 模型选择菜单（BACKLOG-STATUSBAR-MODEL-PICKER）：按 provider 分组列出可选模型，
/// 当前使用中的模型打勾。点击即切换当前会话的模型（无会话时切换默认 provider 的模型）。
/// 菜单底部附「思考级别」档位（会话级临时覆盖，见 ViewModel.setThinkingLevel）。
struct NewPiModelPickerMenu: View {
    let groups: [NewPiProviderModelGroup]
    let activeProfileID: String?
    let activeModelID: String
    /// 当前生效的思考档位（覆盖 ?? provider 默认）。
    var thinkingLevel: ThinkingLevel = .off
    var isDisabled: Bool = false
    let onSelect: (_ profileID: String, _ modelID: String) -> Void
    var onThinkingSelect: ((ThinkingLevel) -> Void)? = nil

    var body: some View {
        Menu {
            ForEach(groups) { group in
                Section {
                    ForEach(group.models, id: \.self) { model in
                        Button {
                            onSelect(group.profileID, model)
                        } label: {
                            if group.profileID == activeProfileID, model == activeModelID {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                } header: {
                    Label {
                        Text(group.hasAPIKey ? group.profileName : "\(group.profileName)（未配置 Key）")
                    } icon: {
                        Image(systemName: group.systemImage)
                    }
                }
            }
            if let onThinkingSelect {
                Section {
                    ForEach(ThinkingLevel.allCases) { level in
                        Button {
                            onThinkingSelect(level)
                        } label: {
                            if level == thinkingLevel {
                                Label(level.displayName, systemImage: "checkmark")
                            } else {
                                Label(level.displayName, systemImage: level == .off ? "brain.slash" : "brain")
                            }
                        }
                    }
                } header: {
                    Text("思考级别（当前：\(thinkingLevel.displayName)）")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption)
                Text(activeModelID.isEmpty ? "选择模型" : activeModelID)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 思考开启时给个小图标，让当前档位一眼可见（off 不显示）。
                if thinkingLevel != .off {
                    Image(systemName: "brain")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 220, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 220, alignment: .leading)
        .disabled(isDisabled || groups.isEmpty)
        .accessibilityLabel("模型与思考级别")
        .accessibilityValue("\(activeModelID.isEmpty ? "未选择模型" : activeModelID)，思考：\(thinkingLevel.displayName)")
        .help("切换当前会话使用的模型与思考档位（当前思考：\(thinkingLevel.displayName)）")
    }
}

/// 输入区的静态任务状态；用量明细按需展开，模型菜单保留给旧调用方。
struct NewPiAgentStatusBar: View {
    let presentation: NewPiAgentStatusPresentation
    /// 主状态后的辅助信息；窄栏优先压缩，不挤占状态与用量。
    var detailText: String? = nil
    /// 累计用量文本（如 "↑12.3k ↓4.5k"）；nil 时显示暂无数据。
    var usageText: String? = nil
    /// 最近一轮用量文本。
    var lastTurnUsageText: String? = nil
    /// 缓存命中率文本（如 "85%"）。
    var cacheHitRateText: String? = nil
    /// 上下文占用文本（如 "上下文 9.2% / 1.0M"）。
    var contextText: String? = nil
    /// 流式输出 token 速率文本（如 "24 tok/s"）。
    var tokenRateText: String? = nil
    /// 模型选择菜单；nil 时隐藏（如 spike 窗口）。
    var modelPicker: NewPiModelPickerMenu? = nil
    /// 最近一轮的输入/输出 token；不能传会话累计值，不解析 usageText 猜测。
    var lastTurnInputTokens: Int? = nil
    var lastTurnOutputTokens: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            NewPiAgentStatusIcon(presentation: presentation, size: .compact)
            Text(presentation.label)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(presentation.foregroundColor)
                .help(presentation.label)
                .layoutPriority(1)
            if let detailText {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detailText)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if let modelPicker {
                modelPicker
            }
            NewPiUsageButton(data: NewPiUsageDialogData(
                usageText: usageText, lastTurnUsageText: lastTurnUsageText,
                cacheHitRateText: cacheHitRateText, contextText: contextText,
                tokenRateText: tokenRateText, lastTurnInputTokens: lastTurnInputTokens,
                lastTurnOutputTokens: lastTurnOutputTokens))
            .frame(width: 44, height: 24)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // 保留各个控件的可访问性，不能合并后吞掉用量按钮或模型菜单。
        .accessibilityElement(children: .contain)
    }

}

/// 只接收展示快照，不持有会话、运行时或发送/停止回调。
struct NewPiUsageDialogData: Equatable {
    var usageText: String? = nil
    var lastTurnUsageText: String? = nil
    var cacheHitRateText: String? = nil
    var contextText: String? = nil
    var tokenRateText: String? = nil
    var lastTurnInputTokens: Int? = nil
    var lastTurnOutputTokens: Int? = nil

    static func display(_ text: String?) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "暂无数据" }
        return text
    }

    private func tokens(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "暂无数据" }
        return value.formatted(.number.grouping(.automatic))
    }

    var metrics: [(String, String)] {
        [("输入 tokens · 最近一轮", tokens(lastTurnInputTokens)),
         ("输出 tokens · 最近一轮", tokens(lastTurnOutputTokens)),
         ("缓存命中率", Self.display(cacheHitRateText)),
         ("上下文占用", Self.display(contextText))]
    }

    var summaries: [(String, String)] {
        [("累计用量", Self.display(usageText)), ("最近一轮", Self.display(lastTurnUsageText)),
         ("输出速率", Self.display(tokenRateText))]
    }
}

/// 原生按钮直接提供所属 window；独立状态栏也可用，不需要 root/environment 接线。
private struct NewPiUsageButton: NSViewRepresentable {
    let data: NewPiUsageDialogData

    func makeNSView(context: Context) -> NewPiUsageOpener {
        NewPiUsageOpener(frame: .zero)
    }

    func updateNSView(_ view: NewPiUsageOpener, context: Context) {
        view.data = data
        view.presentation.update(data)
    }

    static func dismantleNSView(_ view: NewPiUsageOpener, coordinator: ()) {
        view.presentation.dismiss(restoreFocus: false)
    }
}

final class NewPiUsageOpener: NSButton {
    var data = NewPiUsageDialogData()
    let presentation = NewPiUsagePresentation()
    private weak var mouseResponder: NSResponder?
    private var trackingMouse = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "用量"
        isBordered = false
        font = .systemFont(ofSize: 11)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(openUsage)
        toolTip = "显示本会话用量明细"
        setAccessibilityLabel("用量")
        setAccessibilityIdentifier("newpi.usage.open")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { !trackingMouse }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 在 NSButton tracking 可能改变焦点前保存。绝不 endEditing/unmarkText。
        mouseResponder = window?.firstResponder
        trackingMouse = true
        defer { trackingMouse = false; mouseResponder = nil }
        super.mouseDown(with: event)
    }

    @objc private func openUsage() {
        presentation.present(from: self, data: data, restoring: mouseResponder ?? window?.firstResponder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if presentation.parent != nil, window !== presentation.parent {
            presentation.dismiss(restoreFocus: false)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        presentation.dismiss(restoreFocus: false)
    }
}

/// 每个打开按钮拥有自己的短生命周期控制器；同一个实际 window 最多一个用量面板。
/// 非激活子面板让父 NSTextView 保持 firstResponder/marked text；没有 runModal，后台生成继续。
@MainActor
final class NewPiUsagePresentation: NSObject {
    private(set) weak var parent: NSWindow?
    private weak var opener: NSButton?
    private weak var previousResponder: NSResponder?
    private weak var hiddenContent: NSView?
    private var contentWasHidden = false
    private var previousAXChildren: [Any]?
    private var eventMonitor: Any?
    private var blur: NSVisualEffectView?
    private var dimTint: NewPiUsageDimView?
    private var contentPostedFrameChanges = false
    private var contentPostedBoundsChanges = false
    private(set) var panel: NewPiUsagePanel?

    func present(from button: NSButton, data: NewPiUsageDialogData, restoring responder: NSResponder?) {
        guard panel == nil, let window = button.window, window.isVisible, window.alphaValue > 0,
              !button.isHiddenOrHasHiddenAncestor, !button.visibleRect.isEmpty,
              let content = window.contentView else { return }
        // 保活容器不显示也不能被一次 AX 操作意外打开；不枚举 NSApp/keyWindow。
        guard !window.isMiniaturized, !(window is NSPanel) else { return }
        if let existing = window.childWindows?.first(where: { $0 is NewPiUsagePanel }) {
            existing.makeKey()
            return
        }
        parent = window
        opener = button
        previousResponder = responder
        hiddenContent = content
        contentWasHidden = content.isAccessibilityHidden()
        previousAXChildren = window.accessibilityChildren()
        // 在父窗口内部取样正文；透明子面板只负责卡片、键盘焦点和输入隔离。
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.setAccessibilityHidden(true)
        let dimTint = NewPiUsageDimView()
        dimTint.setAccessibilityHidden(true)
        content.addSubview(blur, positioned: .above, relativeTo: nil)
        content.addSubview(dimTint, positioned: .above, relativeTo: blur)
        self.blur = blur
        self.dimTint = dimTint
        contentPostedFrameChanges = content.postsFrameChangedNotifications
        contentPostedBoundsChanges = content.postsBoundsChangedNotifications
        content.postsFrameChangedNotifications = true
        content.postsBoundsChangedNotifications = true
        let dialog = NewPiUsagePanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dialog.owner = self
        dialog.isReleasedWhenClosed = false
        dialog.isOpaque = false
        dialog.backgroundColor = .clear
        dialog.hasShadow = false
        dialog.hidesOnDeactivate = false
        dialog.isFloatingPanel = false
        dialog.animationBehavior = .none
        dialog.appearanceSource = window
        dialog.tabbingMode = .disallowed
        dialog.collectionBehavior = [.fullScreenAuxiliary]
        dialog.setAccessibilityLabel("用量明细")
        dialog.setAccessibilitySubrole(.dialog)
        dialog.setAccessibilityModal(true)
        let backdrop = NewPiUsageBackdrop(data: data)
        backdrop.owner = self
        dialog.contentView = backdrop
        dialog.setAccessibilityChildren([backdrop.dialog])
        dialog.setAccessibilityCloseButton(backdrop.closeButton)
        panel = dialog
        synchronize()
        content.setAccessibilityHidden(true)
        window.setAccessibilityChildren([dialog])
        window.addChildWindow(dialog, ordered: .above)
        dialog.makeKeyAndOrderFront(nil)
        dialog.makeFirstResponder(backdrop.closeButton)
        NSAccessibility.post(element: dialog, notification: .created)
        NSAccessibility.post(element: backdrop.closeButton, notification: .focusedUIElementChanged)

        let center = NotificationCenter.default
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            center.addObserver(self, selector: #selector(parentChanged), name: name, object: content)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(parentChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didEndLiveResizeNotification] {
            center.addObserver(self, selector: #selector(parentChanged), name: name, object: window)
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            center.addObserver(self, selector: #selector(parentClosed), name: name, object: window)
        }
        // 仅过滤本 window/panel 的事件；没有静态回调、强捕获或全局 modal session。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
            .otherMouseUp, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            let discard = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.filter(event) == nil
            }
            return discard ? nil : event
        }
    }

    func update(_ data: NewPiUsageDialogData) {
        guard let backdrop = panel?.contentView as? NewPiUsageBackdrop else { return }
        backdrop.update(data)
        synchronize()
    }

    @objc private func parentChanged() { synchronize() }
    @objc private func parentClosed() { dismiss(restoreFocus: false) }

    private func synchronize() {
        guard let parent, let panel, let content = parent.contentView else { return }
        guard parent.isVisible, !parent.isMiniaturized, opener?.window === parent,
              opener?.isHiddenOrHasHiddenAncestor == false else {
            dismiss(restoreFocus: false)
            return
        }
        // fullSizeContentView 的 bounds 包含标题栏时使用 contentLayoutRect，避免覆盖系统窗口边缘。
        let rect = content.convert(content.bounds, to: nil).intersection(parent.contentLayoutRect)
        let overlayRect = content.convert(rect, from: nil)
        blur?.frame = overlayRect
        blur?.isHidden = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        dimTint?.frame = overlayRect
        dimTint?.needsDisplay = true
        let screenRect = parent.convertToScreen(rect)
        if panel.frame != screenRect { panel.setFrame(screenRect, display: true) }
        panel.contentView?.needsLayout = true
    }

    private func filter(_ event: NSEvent) -> NSEvent? {
        guard let parent, let panel else { return event }
        let belongs = event.window === parent || event.window === panel
            || (event.window == nil && panel.isKeyWindow)
        guard belongs else { return event }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { dismiss(); return nil }
            if event.keyCode == 48 {
                panel.makeFirstResponder((panel.contentView as? NewPiUsageBackdrop)?.closeButton)
            } else if event.keyCode == 49 || event.keyCode == 36 {
                // 唯一可操作焦点是关闭；Return 绝不到达底层发送/停止。
                dismiss()
            } else {
                (panel.contentView as? NewPiUsageBackdrop)?.scroll(keyCode: event.keyCode)
            }
            return nil
        case .keyUp, .flagsChanged: return nil
        default:
            // 子窗口覆盖内容区；额外阻挡发往父 toolbar/旧输入框的事件。
            return event.window === parent ? nil : event
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard let dialog = panel else { return }
        let window = parent
        let restore = previousResponder
        let button = opener
        let wasKey = dialog.isKeyWindow
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // 只移除本控制器持有的两层，不枚举删除业务方或其他控制器的 subviews。
        blur?.removeFromSuperview()
        dimTint?.removeFromSuperview()
        blur = nil
        dimTint = nil
        hiddenContent?.postsFrameChangedNotifications = contentPostedFrameChanges
        hiddenContent?.postsBoundsChangedNotifications = contentPostedBoundsChanges
        hiddenContent?.setAccessibilityHidden(contentWasHidden)
        window?.setAccessibilityChildren(previousAXChildren)
        previousAXChildren = nil
        panel = nil
        dialog.owner = nil
        (dialog.contentView as? NewPiUsageBackdrop)?.owner = nil
        window?.removeChildWindow(dialog)
        dialog.orderOut(nil)
        dialog.close()
        parent = nil
        opener = nil
        previousResponder = nil
        hiddenContent = nil
        if restoreFocus, wasKey, let window, window.isVisible {
            window.makeKey()
            if let view = restore as? NSView, view.window === window {
                // 未变的 responder 不重复 resign/become，保留输入法组合态与选区。
                if window.firstResponder !== view { window.makeFirstResponder(view) }
                NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
            } else if let button, button.window === window {
                window.makeFirstResponder(button)
                NSAccessibility.post(element: button, notification: .focusedUIElementChanged)
            }
        }
    }
}

final class NewPiUsagePanel: NSPanel {
    weak var owner: NewPiUsagePresentation?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { owner?.dismiss() }
    override func accessibilityPerformCancel() -> Bool { owner?.dismiss(); return true }
}

/// draw 使用真实原生像素；不依赖会影响布局的 SwiftUI overlay 或隐式动画。
class NewPiUsageRoundedSurface: NSView {
    var radius: CGFloat = 8
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        NSColor(NewPiWorkbenchStyle.surface).setFill()
        path.fill()
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua]) == .accessibilityHighContrastAqua
            || effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua]) == .accessibilityHighContrastDarkAqua
        (highContrast ? NSColor.labelColor : NSColor(NewPiWorkbenchStyle.line)).setStroke()
        path.lineWidth = highContrast ? 2 : 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class NewPiUsageMetricCard: NewPiUsageRoundedSurface {
    let titleField = NSTextField(wrappingLabelWithString: "")
    let valueField = NSTextField(wrappingLabelWithString: "")

    init(title: String, value: String) {
        super.init(frame: .zero)
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 11)
        titleField.textColor = .secondaryLabelColor
        valueField.stringValue = value
        valueField.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        valueField.lineBreakMode = .byCharWrapping
        addSubview(titleField)
        addSubview(valueField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func height(for width: CGFloat) -> CGFloat {
        32 + NewPiUsageBackdrop.height(titleField, width: width - 28)
            + NewPiUsageBackdrop.height(valueField, width: width - 28)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width - 28)
        let titleHeight = NewPiUsageBackdrop.height(titleField, width: width)
        titleField.frame = NSRect(x: 14, y: 13, width: width, height: titleHeight)
        valueField.frame = NSRect(x: 14, y: titleField.frame.maxY + 5, width: width,
            height: NewPiUsageBackdrop.height(valueField, width: width))
    }
}

final class NewPiUsageBackdrop: NSView {
    weak var owner: NewPiUsagePresentation?
    let dialog = NewPiUsageRoundedSurface()
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭用量明细")!,
        target: nil, action: nil)
    let scrollView = NSScrollView()
    private let titleField = NSTextField(labelWithString: "用量明细")
    private let separator = NSBox()
    private let document = NewPiUsageFlippedView()
    private let note = NSTextField(wrappingLabelWithString: "当前会话的真实用量。输入、输出卡片仅表示最近一轮；未返回的指标显示暂无数据。")
    private var cards: [NewPiUsageMetricCard] = []
    private var summaries: [(NSTextField, NSTextField)] = []
    private var data: NewPiUsageDialogData
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(data: NewPiUsageDialogData) {
        self.data = data
        super.init(frame: .zero)
        addSubview(dialog)
        dialog.radius = 14
        dialog.setAccessibilityElement(true)
        dialog.setAccessibilityRole(.group)
        dialog.setAccessibilityLabel("用量明细")
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        dialog.addSubview(titleField)
        separator.boxType = .separator
        dialog.addSubview(separator)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeUsage)
        closeButton.setAccessibilityLabel("关闭用量明细")
        closeButton.setAccessibilityIdentifier("newpi.usage.close")
        closeButton.toolTip = "关闭用量明细（Escape）"
        dialog.addSubview(closeButton)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        dialog.addSubview(scrollView)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        document.addSubview(note)
        for (title, value) in data.metrics {
            let card = NewPiUsageMetricCard(title: title, value: value)
            cards.append(card)
            document.addSubview(card)
        }
        for (title, value) in data.summaries {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            summaries.append((label, field))
            document.addSubview(label)
            document.addSubview(field)
        }
        dialog.setAccessibilityChildren([titleField, closeButton, scrollView])
        // 无过渡/位移动画，reduced motion 不需要额外分支；低透明度偏好也有不透明兜底。
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func closeUsage() { owner?.dismiss() }
    @objc private func accessibilityChanged() { needsLayout = true; dialog.needsDisplay = true }

    func update(_ data: NewPiUsageDialogData) {
        guard self.data != data else { return }
        self.data = data
        for (card, metric) in zip(cards, data.metrics) { card.valueField.stringValue = metric.1 }
        for (fields, summary) in zip(summaries, data.summaries) { fields.1.stringValue = summary.1 }
        needsLayout = true
        NSAccessibility.post(element: dialog, notification: .layoutChanged)
    }

    static func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: 100_000)).height ?? 20)
    }

    override func layout() {
        super.layout()
        let width = max(1, min(600, bounds.width - 40))
        let inner = max(1, width - 48)
        let cardWidth = max(1, (inner - 12) / 2)
        note.frame = NSRect(x: 24, y: 16, width: inner, height: Self.height(note, width: inner))
        var y = note.frame.maxY + 20
        for row in 0..<2 {
            let height = max(cards[row * 2].height(for: cardWidth), cards[row * 2 + 1].height(for: cardWidth))
            for column in 0..<2 {
                cards[row * 2 + column].frame = NSRect(x: 24 + CGFloat(column) * (cardWidth + 12),
                    y: y, width: cardWidth, height: height)
            }
            y += height + 12
        }
        y += 4
        for (label, field) in summaries {
            label.frame = NSRect(x: 24, y: y, width: inner, height: Self.height(label, width: inner))
            field.frame = NSRect(x: 24, y: label.frame.maxY + 4, width: inner, height: Self.height(field, width: inner))
            y = field.frame.maxY + 14
        }
        let bodyHeight = y + 10
        let height = max(64, min(bodyHeight + 62, bounds.height * 0.8))
        dialog.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
            width: width, height: height)
        titleField.frame = NSRect(x: 22, y: 21, width: max(1, width - 90), height: 22)
        closeButton.frame = NSRect(x: width - 52, y: 16, width: 30, height: 30)
        separator.frame = NSRect(x: 1, y: 61, width: max(1, width - 2), height: 1)
        scrollView.frame = NSRect(x: 0, y: 62, width: width, height: max(1, height - 62))
        document.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        cards.forEach { $0.needsLayout = true; $0.needsDisplay = true }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return dialog.frame.contains(local) ? super.hitTest(point) : self
    }
    override func mouseDown(with event: NSEvent) {
        if !dialog.frame.contains(convert(event.locationInWindow, from: nil)) { owner?.dismiss() }
    }

    func scroll(keyCode: UInt16) {
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let delta: CGFloat
        switch keyCode {
        case 125: delta = 40
        case 126: delta = -40
        case 121: delta = clip.bounds.height * 0.8
        case 116: delta = -clip.bounds.height * 0.8
        case 119: delta = maximum
        case 115: delta = -maximum
        default: return
        }
        clip.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, clip.bounds.minY + delta))))
        scrollView.reflectScrolledClipView(clip)
    }
}

private final class NewPiUsageFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class NewPiUsageDimView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor(srgbRed: 0.09, green: 0.13, blue: 0.11, alpha: opaque ? 1 : 0.4).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// 保留旧名称与初始化参数以兼容外部调用；标签现为静态，不再启动定时器。
struct NewPiStatusBreathingLabel: View {
    let text: String
    let isActive: Bool

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isActive ? NewPiWorkbenchStyle.accent : NewPiWorkbenchStyle.secondaryText)
    }
}

extension UsageStats {
    /// 紧凑用量文本（如 "↑12.3k ↓456"）；为零时返回 nil（不显示）。
    var newPiCompactText: String? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return "↑\(Self.newPiCompact(inputTokens)) ↓\(Self.newPiCompact(outputTokens))"
    }

    private static func newPiCompact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    /// 缓存命中率文本（如 "85%"）；无缓存命中时返回 nil（不显示）。
    var newPiCacheHitRateText: String? {
        guard cacheReadTokens > 0, let rate = cacheHitRate else { return nil }
        return String(format: "%.0f%%", rate * 100)
    }
}

#Preview("Ready") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "checkmark.circle",
            label: "NewPi is ready",
            isActive: false
        )
    )
    .frame(width: 480)
}

#Preview("Thinking") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "brain.head.profile",
            label: "NewPi is thinking…",
            isActive: true
        )
    )
    .frame(width: 480)
}

#Preview("窄栏 · 审批与旧模型菜单") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "hand.raised.circle",
            label: "等待工具审批…",
            isActive: true
        ),
        modelPicker: NewPiModelPickerMenu(
            groups: [NewPiProviderModelGroup(
                profileID: "preview",
                profileName: "预览 Provider",
                systemImage: "cpu",
                hasAPIKey: false,
                models: ["preview-model-with-a-long-name"]
            )],
            activeProfileID: "preview",
            activeModelID: "preview-model-with-a-long-name",
            onSelect: { _, _ in }
        )
    )
    .frame(width: 320)
    .padding()
    .background(NewPiWorkbenchStyle.surface)
}

#Preview("深色 · 错误") {
    NewPiAgentStatusBar(
        presentation: NewPiAgentStatusPresentation(
            systemImage: "exclamationmark.circle.fill",
            label: "请求失败，请重试",
            isActive: false
        )
    )
    .frame(width: 320)
    .padding()
    .background(NewPiWorkbenchStyle.surface)
    .preferredColorScheme(.dark)
}

#Preview("输入外壳 · 主按钮状态") {
    NewPiComposerSurface {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入区由调用方提供")
                .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
            HStack {
                Text("底部工具栏")
                    .font(.caption)
                Spacer()
                NewPiComposerPrimaryAction(isRunning: false, canSend: false, onSend: {}, onStop: {})
                NewPiComposerPrimaryAction(isRunning: false, canSend: true, onSend: {}, onStop: {})
                NewPiComposerPrimaryAction(isRunning: true, canSend: false, onSend: {}, onStop: {})
            }
        }
    }
    .frame(width: 480)
    .padding(NewPiWorkbenchStyle.horizontalInset)
    .background(NewPiWorkbenchStyle.surface)
}
