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

    @State private var isUsagePresented = false

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
            Spacer(minLength: 0)
            if let modelPicker {
                modelPicker
            }
            Button {
                isUsagePresented.toggle()
            } label: {
                Text("用量")
                    .font(.caption)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .accessibilityLabel("用量")
            .accessibilityHint("显示本会话用量明细")
            .help("显示本会话用量明细")
            .popover(isPresented: $isUsagePresented, arrowEdge: .bottom) {
                usageDetails
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // 保留各个控件的可访问性，不能合并后吞掉用量按钮或模型菜单。
        .accessibilityElement(children: .contain)
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用量明细")
                .font(.headline)
            usageRow("累计用量", value: usageText, detail: "本会话累计 token（↑ 输入 / ↓ 输出）")
            usageRow("最近一轮", value: lastTurnUsageText, detail: "最近一轮 token（↑ 输入 / ↓ 输出）")
            usageRow("缓存命中率", value: cacheHitRateText, detail: "命中缓存的输入 token / 总输入 token")
            usageRow("上下文占用", value: contextText, detail: "调用方提供的当前上下文占用")
            usageRow("输出速率", value: tokenRateText, detail: "流式文本估算的 token/秒")
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func usageRow(_ title: String, value: String?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(NewPiWorkbenchStyle.secondaryText)
            Text(value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "暂无数据")
                .font(.callout.monospacedDigit())
                .foregroundStyle(NewPiWorkbenchStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .help(detail)
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
