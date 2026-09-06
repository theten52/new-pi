import AppKit
import NewPiCore
import SwiftUI

final class NewPiAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await MCPPluginManager.shared.shutdownAll()
        }
    }
}

@main
struct NewPiApp: App {
    @NSApplicationDelegateAdaptor(NewPiAppDelegate.self) private var appDelegate

    init() {
        _ = NewPiLogStore.shared
    }

    var body: some Scene {
        WindowGroup {
            NewPiRootView()
        }
        // UI 架构 spike（一次性验证工具，不接入生产路径）：独立窗口。
        // 用 Window（单实例）而非 WindowGroup——后者对同一 id 重复 openWindow 会开多个窗口，
        // 导致 autorun 序列被多个模型实例并发执行。
        Window("UI Architecture Spike", id: "ui-arch-spike") {
            NewPiSpikeTranscriptView()
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
            CommandGroup(after: .help) {
                Button("Debug Logs") {
                    NotificationCenter.default.post(name: .newPiShowLogs, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("UI Architecture Spike") {
                    NotificationCenter.default.post(name: .newPiShowSpike, object: nil)
                }
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
    static let newPiShowLogs = Notification.Name("com.new-pi.showLogs")
    static let newPiShowSpike = Notification.Name("com.new-pi.showSpike")
}

private struct SessionRow: View {
    let summary: SessionSummary
    let isActive: Bool

    @State private var isHovering = false

    /// 有效显示名：label 为空串时视为未命名（回落显示创建时间）。
    private var displayLabel: String? {
        guard let label = summary.label,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return label
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isActive {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayLabel ?? summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if displayLabel != nil {
                        Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                    }
                    Text("\(summary.messageCount) messages")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 高亮优先级：活跃会话 accent 色 > 悬浮毛玻璃（BACKLOG-SESSION-HOVER-GLASS）
            if isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    )
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct NewPiRootView: View {
    @ObservedObject private var viewModel = NewPiRootViewModelStore.shared.viewModel
    /// 聊天室运行时缓存（CHATROOM-FLAT-MD Phase 1）：列表数据源 + 长命 FlowController。
    @ObservedObject private var chatroomStore = ChatRoomRuntimeStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showLogs = false
    /// 当前在 detail 区平铺展示的聊天室 id（nil = 显示 session 对话）。
    @State private var selectedChatroomID: String?
    @State private var showingCreateChatroom = false
    @State private var chatroomToEdit: ChatRoom?
    @State private var chatroomToDelete: ChatRoom?
    /// Session 列表当前展示的条数（增量展开：每次点 Show all 多显示 5 条）。
    @State private var sessionDisplayLimit = 5
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""

    private let recentSessionLimit = 5
    private let sessionDisplayIncrement = 5

    /// Sessions sidebar section（原内联在 body；CHATROOM-FLAT-MD 加入聊天室 section 后
    /// List 内容超出 SwiftUI 类型检查复杂度上限，抽出为独立计算属性）。
    private var sessionsSection: some View {
        Section("Sessions") {
            Button("New Session") {
                selectedChatroomID = nil
                Task { await viewModel.startNewSession() }
            }
            .disabled(viewModel.projectURL == nil)

            if viewModel.savedSessions.isEmpty {
                Text("No saved sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayedSessions) { summary in
                    Button {
                        selectedChatroomID = nil
                        Task { await viewModel.resumeSession(summary) }
                    } label: {
                        SessionRow(
                            summary: summary,
                            isActive: summary.id == viewModel.activeSessionID
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename Session") {
                            renameTarget = summary
                            renameText = summary.label ?? ""
                        }
                        Button("Archive Session") {
                            Task { await viewModel.archiveSession(summary) }
                        }
                    }
                }

                if viewModel.savedSessions.count > sessionDisplayLimit
                    || sessionDisplayLimit > recentSessionLimit {
                    HStack(spacing: 12) {
                        // 增量展开：每次点击多显示 5 条，直至全部显示。
                        if viewModel.savedSessions.count > sessionDisplayLimit {
                            Button("Show all (\(viewModel.savedSessions.count))") {
                                sessionDisplayLimit = min(
                                    sessionDisplayLimit + sessionDisplayIncrement,
                                    viewModel.savedSessions.count
                                )
                            }
                        }
                        if sessionDisplayLimit > recentSessionLimit {
                            Button("Show less") {
                                sessionDisplayLimit = recentSessionLimit
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: viewModel.projectURL) { _, _ in
            sessionDisplayLimit = recentSessionLimit
        }
    }

    /// 聊天室 sidebar section（CHATROOM-FLAT-MD Phase 1）：平铺模式，聊天室直接列在
    /// sidebar，点击在 detail 区全尺寸展示，不再是嵌套 sheet。抽出为独立计算属性，
    /// 避免 List 内容超出 SwiftUI 类型检查复杂度上限。
    private var chatroomSection: some View {
        Section("聊天室") {
            Button("新建聊天室") {
                showingCreateChatroom = true
            }
            .disabled(viewModel.projectURL == nil)

            ForEach(chatroomStore.chatrooms) { chatroom in
                Button {
                    selectedChatroomID = chatroom.id
                } label: {
                    ChatRoomSidebarRow(
                        chatroom: chatroom,
                        isActive: chatroom.id == selectedChatroomID
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        chatroomToEdit = chatroom
                    } label: {
                        Label("编辑聊天室", systemImage: "pencil")
                    }
                    // 运行中禁编辑（对齐 DetailView 编辑菜单的守卫；review #2）
                    .disabled(chatroomStore.isRunning(chatroomID: chatroom.id))
                    Button(role: .destructive) {
                        chatroomToDelete = chatroom
                    } label: {
                        Label("删除聊天室", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var displayedSessions: [SessionSummary] {
        Array(viewModel.savedSessions.prefix(max(sessionDisplayLimit, recentSessionLimit)))
    }

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

                sessionsSection
                
                chatroomSection
            }
            .navigationTitle("NewPi")
        } detail: {
            Group {
                if let id = selectedChatroomID,
                   let chatroom = chatroomStore.chatrooms.first(where: { $0.id == id }) {
                    ChatRoomDetailView(
                        viewModel: viewModel,
                        controller: chatroomStore.controller(for: chatroom)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A→B 直切时强制重建（对齐 session 按 sessionID 分视图身份的机制）：
                    // 否则 @StateObject docController 与内部 WKWebView 复用，coordinator.sessionID
                    // 仍是上一个聊天室的 key——滚动锚点串号且不恢复（review #1）。
                    .id(chatroom.id)
                } else {
                    NewPiChatView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Export Markdown…") {
                            Task { await viewModel.exportSessionToFile(format: .markdown) }
                        }
                        Button("Export Text…") {
                            Task { await viewModel.exportSessionToFile(format: .text) }
                        }
                        Button("Export JSON…") {
                            Task { await viewModel.exportSessionToFile(format: .json) }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.transcript.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showLogs = true
                    } label: {
                        Label("Logs", systemImage: "list.bullet.rectangle")
                    }
                    .help("Debug Logs")
                }
            }
        }
        .sheet(isPresented: $showLogs) {
            NewPiLogsView(store: NewPiLogStore.shared)
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    let newLabel = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await viewModel.renameSession(target, to: newLabel) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for this session. Leave empty to reset to the default name.")
        }
        .sheet(item: $viewModel.pendingToolApproval) { request in
            NewPiToolApprovalSheet(viewModel: viewModel, request: request)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingCreateChatroom) {
            CreateChatRoomView(viewModel: viewModel) { chatroom in
                chatroomStore.reload()
                selectedChatroomID = chatroom.id
            }
        }
        .sheet(item: $chatroomToEdit) { chatroom in
            EditChatRoomView(
                viewModel: viewModel,
                chatroom: chatroom,
                conversationStarted: ChatRoomStore.shared.hasMessages(for: chatroom.id)
            ) { updated in
                chatroomStore.applyEdit(updated)
            }
        }
        .confirmationDialog(
            "删除聊天室",
            isPresented: Binding(
                get: { chatroomToDelete != nil },
                set: { if !$0 { chatroomToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(chatroomToDelete?.name ?? "")」", role: .destructive) {
                if let chatroom = chatroomToDelete {
                    try? chatroomStore.delete(chatroom)
                    if selectedChatroomID == chatroom.id { selectedChatroomID = nil }
                }
                chatroomToDelete = nil
            }
            Button("取消", role: .cancel) {
                chatroomToDelete = nil
            }
        } message: {
            Text("将删除聊天室配置与全部对话记录，不可恢复。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiNewSession)) { _ in
            Task {
                await viewModel.startNewSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiShowLogs)) { _ in
            showLogs = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPiShowSpike)) { _ in
            openWindow(id: "ui-arch-spike")
        }
        .onAppear {
            // 无人值守 spike：NEWPI_SPIKE_AUTORUN=1 启动时自动打开 spike 窗口。
            if ProcessInfo.processInfo.environment["NEWPI_SPIKE_AUTORUN"] == "1" {
                openWindow(id: "ui-arch-spike")
            }
        }
    }
}

#Preview {
    NewPiRootView()
}


// MARK: - ChatRoom Views (完整实现)

import NewPiCore
import SwiftUI

/// 聊天室 sidebar 行（CHATROOM-FLAT-MD Phase 1）：紧凑展示，替代原卡片式 ChatRoomRow。
struct ChatRoomSidebarRow: View {
    let chatroom: ChatRoom
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isActive {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chatroom.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(chatroom.configuredRoles) { role in
                        Image(systemName: role.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(role.name)
                    }
                    Text(chatroom.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            PhaseBadge(phase: chatroom.currentPhase)
        }
        .padding(.vertical, 2)
    }
}

/// 阶段徽章
struct PhaseBadge: View {
    let phase: ChatRoomPhase
    
    var body: some View {
        Text(phaseName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(phaseColor.opacity(0.2))
            .foregroundStyle(phaseColor)
            .clipShape(Capsule())
    }
    
    private var phaseName: String {
        switch phase {
        case .discussion: "讨论"
        case .voting: "投票"
        case .execution: "执行"
        case .review: "Review"
        case .completed: "完成"
        }
    }
    
    private var phaseColor: Color {
        switch phase {
        case .discussion: .blue
        case .voting: .orange
        case .execution: .green
        case .review: .purple
        case .completed: .gray
        }
    }
}

#Preview {
    ChatRoomSidebarRow(
        chatroom: ChatRoom(name: "测试聊天室", projectPath: "/tmp"),
        isActive: true
    )
}


import NewPiCore
import SwiftUI

/// 创建聊天室视图
struct CreateChatRoomView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    let onCreate: (ChatRoom) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var projectPath = ""
    @State private var roles: [ChatRoomRole] = PresetRoleType.allCases.map { ChatRoomRole.from(preset: $0) }
    @State private var templates: [ChatRoomTemplate] = []
    @State private var selectedTemplateID: String?
    @State private var invalidatedRoleIDs: [String] = []
    @State private var showingTemplateManager = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("模板") {
                    Picker("选择模板", selection: $selectedTemplateID) {
                        Text("自定义").tag(nil as String?)
                        ForEach(templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                    .onChange(of: selectedTemplateID) { _, newValue in
                        applyTemplate(id: newValue)
                    }

                    if !invalidatedRoleNames.isEmpty {
                        Label(
                            "以下角色的模型绑定已失效，已重置为未配置：\(invalidatedRoleNames.joined(separator: "、"))",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Button("管理模板…") {
                        showingTemplateManager = true
                    }
                }

                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("描述", text: $description)
                    HStack {
                        TextField("项目文件夹", text: $projectPath)
                        Button("选择…") {
                            selectFolder()
                        }
                    }
                }

                Section("角色配置") {
                    ForEach($roles) { $role in
                        RoleEditorRow(
                            role: $role,
                            providerProfiles: viewModel.providerConfig.profiles,
                            canDelete: roles.count > 1,
                            onDelete: {
                                roles.removeAll { $0.id == role.id }
                            }
                        )
                    }

                    // 允许 0 配置角色创建（文档：未配置角色暂不参与发言），但提示后果
                    if !roles.contains(where: { $0.isConfigured }) {
                        Label(
                            "当前没有已配置模型的角色，创建后需先绑定 provider 和 model 才能推进发言",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Button("添加角色") {
                        roles.append(ChatRoomRole(name: "新角色", description: "", systemPrompt: ""))
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 500, minHeight: 400)
            .navigationTitle("创建聊天室")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createChatroom()
                    }
                    .disabled(name.isEmpty || projectPath.isEmpty)
                }
            }
            .onAppear {
                reloadTemplates(selectDefault: true)
            }
            .sheet(isPresented: $showingTemplateManager, onDismiss: {
                reloadTemplates(selectDefault: false)
            }) {
                TemplateManagerView(viewModel: viewModel)
            }
            .onChange(of: roles) { _, newRoles in
                // 用户为降级角色重新完成绑定后，移除对应的失效提示
                invalidatedRoleIDs.removeAll { id in
                    newRoles.first(where: { $0.id == id })?.isConfigured == true
                }
            }
        }
    }

    // MARK: - 模板

    private func reloadTemplates(selectDefault: Bool) {
        templates = (try? ChatRoomTemplateStore.shared.listAll()) ?? []
        guard selectDefault else {
            // 管理器关闭后仅刷新列表；选中的模板被删除则清空选择（保留当前角色编辑）
            if let id = selectedTemplateID, !templates.contains(where: { $0.id == id }) {
                selectedTemplateID = nil
                applyTemplate(id: nil)
            }
            return
        }
        guard selectedTemplateID == nil else { return }
        selectedTemplateID = templates.first(where: { $0.name == "默认四人组" })?.id ?? templates.first?.id
        // 显式套用一次，不依赖 onChange 对 onAppear 期间赋值的触发时机
        applyTemplate(id: selectedTemplateID)
    }

    /// 失效角色展示名（按 roleID 解析、去重）
    private var invalidatedRoleNames: [String] {
        var seen = Set<String>()
        return invalidatedRoleIDs.compactMap { id in
            roles.first(where: { $0.id == id })?.name
        }.filter { seen.insert($0).inserted }
    }

    /// 套用模板（决策 #22：模板是起点，套用后仍可修改）。
    /// provider 或 model 绑定失效的角色在此降级，避免保存后到发言时才报错（决策 #20）。
    private func applyTemplate(id: String?) {
        guard let id,
              let template = templates.first(where: { $0.id == id }) else {
            invalidatedRoleIDs = []
            return
        }
        let profileModels = Dictionary(
            uniqueKeysWithValues: viewModel.providerConfig.profiles.map { ($0.id, $0.models) }
        )
        let result = template.resolvedRoles(profileModels: profileModels)
        roles = result.roles
        invalidatedRoleIDs = result.invalidatedRoleIDs
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择项目文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }

    private func createChatroom() {
        guard !name.isEmpty else {
            errorMessage = "请输入名称"
            return
        }
        guard !projectPath.isEmpty else {
            errorMessage = "请选择项目文件夹"
            return
        }

        let chatroom = ChatRoom(
            name: name,
            description: description,
            roles: roles,
            projectPath: projectPath
        )

        do {
            try ChatRoomStore.shared.save(chatroom)
            onCreate(chatroom)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 角色编辑行（创建页 / 聊天室编辑 / 模板编辑共用）。
/// 收起时显示名称与模型绑定；展开后可编辑名称、职责、systemPrompt 与图标。
struct RoleEditorRow: View {
    @Binding var role: ChatRoomRole
    let providerProfiles: [ProviderProfile]
    var canDelete: Bool = false
    var onDelete: () -> Void = {}

    @State private var isExpanded = false

    static let availableIcons = [
        "person.fill", "person.2", "building.2", "desktopcomputer",
        "checkmark.shield", "person.crop.rectangle.stack", "wand.and.stars",
        "wrench.and.screwdriver", "eye", "brain.head.profile",
        "doc.text.magnifyingglass", "lightbulb",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                iconMenu

                if isExpanded {
                    TextField("角色名称", text: $role.name)
                        .textFieldStyle(.roundedBorder)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.name.isEmpty ? "未命名角色" : role.name)
                            .font(.headline)
                        if !role.description.isEmpty {
                            Text(role.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起" : "展开编辑")

                if canDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除角色")
                }
            }

            HStack {
                // Provider 选择
                Picker("Provider", selection: $role.providerProfileID) {
                    Text("未选择").tag(nil as String?)
                    ForEach(providerProfiles) { profile in
                        Text(profile.name).tag(profile.id as String?)
                    }
                }
                .frame(width: 170)

                // Model 选择
                if let providerID = role.providerProfileID,
                   let profile = providerProfiles.first(where: { $0.id == providerID }) {
                    Picker("Model", selection: $role.modelID) {
                        Text("未选择").tag(nil as String?)
                        ForEach(profile.models, id: \.self) { model in
                            Text(model).tag(model as String?)
                        }
                    }
                    .frame(width: 170)
                }
            }

            if isExpanded {
                TextField("职责描述", text: $role.description)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $role.systemPrompt)
                        .font(.callout)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary)
                        )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconMenu: some View {
        Menu {
            ForEach(Self.availableIcons, id: \.self) { icon in
                Button {
                    role.icon = icon
                } label: {
                    Image(systemName: icon)
                }
            }
        } label: {
            Image(systemName: role.icon.isEmpty ? "person.fill" : role.icon)
                .frame(width: 24)
        }
        .help("选择图标")
    }
}

// MARK: - 模板管理

/// 模板管理器（决策 #23：创建页内「管理模板…」单一入口）
struct TemplateManagerView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [ChatRoomTemplate] = []
    @State private var templateBeingEdited: ChatRoomTemplate?
    @State private var templateToDelete: ChatRoomTemplate?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .padding()
            .frame(minWidth: 460, minHeight: 380)
            .navigationTitle("管理模板")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        templateBeingEdited = ChatRoomTemplate(name: "")
                    } label: {
                        Label("新建模板", systemImage: "plus")
                    }
                    .help("新建模板")
                }
            }
            .onAppear { reload() }
            .sheet(item: $templateBeingEdited) { template in
                TemplateEditView(viewModel: viewModel, template: template) { _ in
                    reload()
                }
            }
            .confirmationDialog(
                "删除模板",
                isPresented: Binding(
                    get: { templateToDelete != nil },
                    set: { if !$0 { templateToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除「\(templateToDelete?.name ?? "")」", role: .destructive) {
                    deleteTemplate(templateToDelete)
                    templateToDelete = nil
                }
                Button("取消", role: .cancel) {
                    templateToDelete = nil
                }
            } message: {
                Text("删除模板不影响已创建的聊天室。")
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(templates) { template in
                    templateRow(template)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("暂无模板")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("点击右上角 + 新建一个模板")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func templateRow(_ template: ChatRoomTemplate) -> some View {
        Button {
            templateBeingEdited = template
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.headline)
                    if !template.description.isEmpty {
                        Text(template.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(template.roles.count) 个角色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                templateBeingEdited = template
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                templateToDelete = template
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func reload() {
        templates = (try? ChatRoomTemplateStore.shared.listAll()) ?? []
    }

    private func deleteTemplate(_ template: ChatRoomTemplate?) {
        guard let template else { return }
        do {
            try ChatRoomTemplateStore.shared.delete(id: template.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 模板编辑器（新建与编辑共用：template.name 为空即新建）
struct TemplateEditView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    let template: ChatRoomTemplate
    let onSave: (ChatRoomTemplate) -> Void

    @State private var name: String
    @State private var description: String
    @State private var roles: [ChatRoomRole]
    @State private var errorMessage: String?

    init(
        viewModel: NewPiViewModel,
        template: ChatRoomTemplate,
        onSave: @escaping (ChatRoomTemplate) -> Void
    ) {
        self.viewModel = viewModel
        self.template = template
        self.onSave = onSave
        _name = State(initialValue: template.name)
        _description = State(initialValue: template.description)
        _roles = State(initialValue: template.roles)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("模板名称", text: $name)
                    TextField("描述", text: $description)
                }

                Section("角色配置") {
                    ForEach($roles) { $role in
                        RoleEditorRow(
                            role: $role,
                            providerProfiles: viewModel.providerConfig.profiles,
                            canDelete: roles.count > 1,
                            onDelete: {
                                roles.removeAll { $0.id == role.id }
                            }
                        )
                    }
                    Button("添加角色") {
                        roles.append(ChatRoomRole(name: "新角色", description: "", systemPrompt: ""))
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 500, minHeight: 400)
            .navigationTitle(template.name.isEmpty ? "新建模板" : "编辑模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(name.isEmpty || roles.isEmpty)
                }
            }
        }
    }

    private func save() {
        var updated = template
        updated.name = name
        updated.description = description
        updated.roles = roles
        updated.updatedAt = Date()

        do {
            try ChatRoomTemplateStore.shared.save(updated)
            onSave(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    CreateChatRoomView(viewModel: NewPiViewModel()) { _ in }
}

/// 编辑聊天室（名称、描述、角色配置；对话开始后仍可修改，对后续发言生效）
struct EditChatRoomView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    let chatroom: ChatRoom
    let conversationStarted: Bool
    let onSave: (ChatRoom) -> Void

    @State private var name: String
    @State private var description: String
    @State private var roles: [ChatRoomRole]
    @State private var errorMessage: String?

    init(
        viewModel: NewPiViewModel,
        chatroom: ChatRoom,
        conversationStarted: Bool,
        onSave: @escaping (ChatRoom) -> Void
    ) {
        self.viewModel = viewModel
        self.chatroom = chatroom
        self.conversationStarted = conversationStarted
        self.onSave = onSave
        _name = State(initialValue: chatroom.name)
        _description = State(initialValue: chatroom.description)
        _roles = State(initialValue: chatroom.roles)
    }

    var body: some View {
        NavigationStack {
            Form {
                if conversationStarted {
                    Section {
                        Label("对话已开始：修改的角色模型将对后续发言生效，历史消息不受影响", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("描述", text: $description)
                    HStack {
                        Text("项目文件夹")
                        Spacer()
                        Text(chatroom.projectPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section("角色配置") {
                    ForEach($roles) { $role in
                        RoleEditorRow(
                            role: $role,
                            providerProfiles: viewModel.providerConfig.profiles
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 500, minHeight: 400)
            .navigationTitle("编辑聊天室")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func save() {
        var updated = chatroom
        updated.name = name
        updated.description = description
        updated.roles = roles
        updated.updatedAt = Date()

        do {
            try ChatRoomStore.shared.save(updated)
            onSave(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


import NewPiCore
import SwiftUI

/// 聊天室详情视图
struct ChatRoomDetailView: View {
    @ObservedObject var viewModel: NewPiViewModel
    /// 流程控制器（CHATROOM-FLAT-MD Phase 1）：runtime/loop/审批/任务均由它持有，
    /// 平铺模式下视图显隐不再影响讨论流程。
    @ObservedObject var controller: ChatRoomFlowController

    @State private var inputText = ""
    /// Composer 实测内容高度（NewPiComposerTextView 回报，自动增高、超限滚动）。
    @State private var composerInputHeight: CGFloat = NewPiComposerScrollView.fallbackHeight
    @State private var showingVoteSheet = false
    @State private var showingRolePicker = false
    @State private var showingEndDiscussionDialog = false
    @State private var showingEditConfig = false

    private var runtime: ChatRoomRuntime { controller.runtime }
    private var approvalManager: ChatRoomApprovalManager { controller.approvalManager }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerBar

            // 轮数上限暂停提示
            if runtime.chatroom.pausedAtRoundLimit == true {
                roundLimitBanner
            }

            // 上下文预算提示（决策 #7）
            if let budget = contextBudgetWarning {
                budgetBanner(budget)
            }

            // 消息列表
            messageList

            // 输入栏
            inputBar
        }
        // 历史消息在控制器创建时加载；runningTask 不随视图显隐取消——审批 continuation
        // 由控制器持有的 approvalManager 承载，切走时挂起、切回时审批 sheet 自动重弹。
        .alert(
            "聊天室提示",
            isPresented: Binding(
                get: { controller.flowError != nil },
                set: { if !$0 { controller.flowError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(controller.flowError ?? "")
        }
        .sheet(item: pendingApprovalItem) { approval in
            ChatRoomApprovalSheet(
                approval: approval,
                onApprove: { approvalManager.approve(id: approval.id) },
                onReject: { approvalManager.reject(id: approval.id) }
            )
        }
        .sheet(isPresented: $showingEditConfig) {
            EditChatRoomView(
                viewModel: viewModel,
                chatroom: runtime.chatroom,
                conversationStarted: !runtime.messages.isEmpty
            ) { updated in
                // 同步 runtime 副本：后续 persistRuntimeState 保存的是 runtime.chatroom，
                // 不同步会覆盖掉刚保存的修改
                runtime.chatroom = updated
            }
        }
    }

    /// 待审批项（取队首；审批完成后自动弹出下一个）
    private var pendingApprovalItem: Binding<ChatRoomApprovalManager.PendingApproval?> {
        Binding(
            get: { approvalManager.pendingApprovals.first },
            set: { _ in }
        )
    }
    
    // MARK: - 标题栏
    
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(runtime.chatroom.name)
                    .font(.headline)
                HStack {
                    PhaseBadge(phase: runtime.chatroom.currentPhase)
                    if runtime.chatroom.currentPhase == .execution || runtime.chatroom.currentPhase == .review {
                        Text("第 \(runtime.chatroom.reviewRoundCount) 轮")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 角色指示器
            HStack(spacing: 8) {
                ForEach(runtime.chatroom.configuredRoles) { role in
                    Image(systemName: role.icon)
                        .font(.caption)
                        .padding(4)
                        .background(
                            runtime.currentSpeaker?.id == role.id
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .clipShape(Circle())
                        .help(role.name)
                }
            }
            
            // 操作按钮
            Menu {
                Button("编辑配置…") {
                    showingEditConfig = true
                }
                .disabled(runtime.isRunning)
                Divider()
                Button("停止当前运行") {
                    controller.cancelRunning()
                }
                .disabled(!runtime.isRunning)
                Divider()
                Button("结束流程", role: .destructive) {
                    controller.stopFlow()
                }
                .disabled(runtime.chatroom.currentPhase == .completed)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding()
        .background(.bar)
    }
    
    // MARK: - 消息列表

    /// 单文档控制器（CHATROOM-FLAT-MD Phase 2）：与 session 同一条渲染管线。
    /// 注意：切换选择时 DetailView 被销毁，WebView 冷渲染 + restoreAnchor 恢复位置
    /// （与 session 切换的 reset 重建同级体验；消息数据由长命 FlowController 保暖）。
    @StateObject private var docController = TranscriptDocumentController()

    private var messageList: some View {
        // 消息 → transcript items（实时发言走增量渲染管线：isRunning 期间临时消息
        // 为活跃流式条目（renderStreaming + ✦ 光标），结束翻 false 定型一次。
        // 无 fork/折叠组：条目 messageIndex/detailTurnID 均为 nil，JS 不渲染 Fork 按钮）。
        let snapshot = controller.transcriptSnapshot()
        let chatroomUUID = UUID(uuidString: runtime.chatroom.id)
        return ZStack(alignment: .bottom) {
            NewPiTranscriptDocumentView(
                transcript: snapshot.items,
                isStreaming: runtime.isRunning,
                streamingBubbleComplete: !runtime.isRunning,
                storeKey: chatroomUUID,
                controller: docController,
                tintHues: snapshot.tintHues,
                restoreEntry: chatroomUUID.flatMap { ScrollPositionStore.shared.entry(for: $0) },
                onFork: nil
            )
            .overlay(alignment: .bottom) {
                if !docController.isNearBottom {
                    Button {
                        docController.scrollToBottom()
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }

            // 当前发言者指示：保留原生浮层，不进文档。
            if runtime.isRunning, let speaker = runtime.currentSpeaker {
                HStack(spacing: 6) {
                    Image(systemName: speaker.icon)
                        .font(.caption)
                    Text("\(speaker.name) 正在思考...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    // MARK: - 输入栏

    private var inputBar: some View {
        VStack(spacing: 8) {
            // 操作按钮
            HStack {
                // 推进发言按钮
                Button {
                    controller.triggerNextSpeaker()
                } label: {
                    Label("推进下一发言", systemImage: "play.fill")
                }
                .disabled(runtime.isRunning || runtime.chatroom.currentPhase == .completed)

                // 指定发言人
                Button {
                    showingRolePicker = true
                } label: {
                    Label("@指定", systemImage: "at")
                }
                .disabled(runtime.isRunning || runtime.chatroom.currentPhase == .completed)

                Spacer()

                // 阶段流转按钮
                switch runtime.chatroom.currentPhase {
                case .discussion:
                    Button("结束讨论") {
                        // 决策 #4：由用户选择走向——多方案时询问发起投票还是直接执行
                        if extractCandidates().count >= 2 {
                            showingEndDiscussionDialog = true
                        } else {
                            endDiscussion(.proceedDirect)
                        }
                    }
                    .disabled(runtime.isRunning)
                case .voting:
                    Button("投票") {
                        showingVoteSheet = true
                    }
                    // 决策 #19：投票后由用户手动点击「进入执行」
                    Button("进入执行") {
                        advancePhase()
                    }
                    .disabled(runtime.chatroom.selectedOptionID == nil)
                case .execution:
                    Button("进入 Review") {
                        advancePhase()
                    }
                    .disabled(runtime.isRunning)
                case .review:
                    if runtime.chatroom.pausedAtRoundLimit == true {
                        Text("流程已暂停，请在上方选择处理方式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("通过") {
                                review(approved: true)
                            }
                            // 轮数上限时不再禁用：handleReviewResult 会暂停并等待用户解锁
                            Button("需修改") {
                                review(approved: false)
                            }
                        }
                        .disabled(runtime.isRunning)
                    }
                case .completed:
                    Text("已完成")
                        .foregroundStyle(.secondary)
                }
            }

            // 状态行（Phase A 用量显示）：空闲时展示累计 token 用量
            if !runtime.isRunning, let usageText = runtime.usage.newPiCompactText {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("累计 Token：\(usageText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // 输入框（Phase A：复用 Session 的多行 Composer）——真实多行、自动增高、
            // Return 发送 / Shift+Return 换行；发言进行中保持可输入（插话走 steering）。
            NewPiComposerTextView(
                text: $inputText,
                placeholder: "输入消息…（Return 发送，Shift+Return 换行；发言中发送 = 插话）",
                onSubmit: {
                    sendUserMessage()
                },
                onHeightChange: { newHeight in
                    guard abs(composerInputHeight - newHeight) > 0.5 else { return }
                    composerInputHeight = newHeight
                }
            )
            .frame(height: composerInputHeight)

            HStack {
                Spacer()

                Button("发送") {
                    sendUserMessage()
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.bar)
        .confirmationDialog("讨论有多个候选方案", isPresented: $showingEndDiscussionDialog, titleVisibility: .visible) {
            Button("发起投票") { endDiscussion(.startVoting) }
            Button("直接进入执行（跳过投票）") { endDiscussion(.proceedDirect) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请选择讨论的结束方式")
        }
        .sheet(isPresented: $showingVoteSheet) {
            VoteSheet(
                candidates: extractCandidates(),
                selectedOptionID: runtime.chatroom.selectedOptionID
            ) { optionID in
                controller.userVote(optionID: optionID)
            }
        }
        .sheet(isPresented: $showingRolePicker) {
            RolePickerSheet(roles: runtime.chatroom.configuredRoles) { roleID in
                controller.triggerSpeaker(roleID: roleID)
            }
        }
    }

    // MARK: - 横幅

    /// 轮数上限暂停横幅（决策 #8：暂停后用户解锁/追加轮数）
    private var roundLimitBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("已达 \(runtime.chatroom.reviewRoundCount) 轮上限且 Review 未通过，流程已暂停")
                .font(.callout)
            Spacer()
            Button("追加一轮") {
                controller.addRoundFromPause()
            }
            Button("接受并完成") {
                controller.completeFromPause()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private struct ContextBudget {
        let usedRatio: Double
        let limitTokens: Int
    }

    /// 共享上下文预算（决策 #7）：上限 = 所有角色中最小的 context window，
    /// 达到 80% 时提示「建议结束当前讨论」。token 用字符数粗略估算。
    private var contextBudgetWarning: ContextBudget? {
        let roles = runtime.chatroom.configuredRoles
        guard !roles.isEmpty else { return nil }

        var limit: Int?
        for role in roles {
            guard let profileID = role.providerProfileID,
                  let modelID = role.modelID,
                  let profile = viewModel.providerConfig.profiles.first(where: { $0.id == profileID }) else {
                continue
            }
            let window = profile.contextWindow(for: modelID)
            if window > 0 {
                limit = min(limit ?? window, window)
            }
        }
        guard let cap = limit, cap > 0 else { return nil }

        // 与自动压缩共用核心估算器（摘要检查点 + 检查点后消息，与实际 API 载荷一致）
        let usedTokens = ChatRoomContextBuilder.estimatedTokens(room: runtime.chatroom, history: runtime.messages)
        let ratio = Double(usedTokens) / Double(cap)
        guard ratio >= 0.8 else { return nil }
        return ContextBudget(usedRatio: ratio, limitTokens: cap)
    }

    private func budgetBanner(_ budget: ContextBudget) -> some View {
        HStack {
            Image(systemName: "gauge.with.needle")
                .foregroundStyle(.orange)
            Text("共享上下文已达预算约 \(Int(budget.usedRatio * 100))%（各角色最小窗口 \(budget.limitTokens) tokens），建议结束当前讨论")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
    
    // MARK: - 辅助方法

    private func sendUserMessage() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        controller.userSpeak(content: content)
        inputText = ""
    }

    private func endDiscussion(_ mode: ChatRoomDiscussionEndMode) {
        controller.endDiscussion(mode)
    }

    private func advancePhase() {
        controller.advancePhase()
    }

    private func review(approved: Bool) {
        controller.review(approved: approved)
    }
    
    private func extractCandidates() -> [CandidateOption] {
        for message in runtime.messages.reversed() {
            if let candidates = message.candidates, !candidates.isEmpty {
                return candidates
            }
        }
        return []
    }
}

// MARK: - 投票 Sheet

struct VoteSheet: View {
    let candidates: [CandidateOption]
    let selectedOptionID: String?
    let onVote: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(candidates) { option in
                Button {
                    onVote(option.id)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.title)
                                .font(.headline)
                            Text(option.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option.id == selectedOptionID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help("当前已选")
                        }
                    }
                }
            }
            .navigationTitle("投票")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}


// MARK: - 工具审批 Sheet

struct ChatRoomApprovalSheet: View {
    let approval: ChatRoomApprovalManager.PendingApproval
    let onApprove: () -> Void
    let onReject: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("工具审批", systemImage: "checkmark.shield")
                .font(.headline)

            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                Text(approval.roleName.isEmpty ? "未知角色" : approval.roleName)
                    .font(.subheadline)
                Spacer()
            }

            ScrollView {
                Text(approval.description)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("拒绝", role: .destructive) {
                    onReject()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("批准") {
                    onApprove()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 300)
    }
}

// MARK: - 角色选择 Sheet

struct RolePickerSheet: View {
    let roles: [ChatRoomRole]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List(roles) { role in
                Button {
                    onSelect(role.id)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: role.icon)
                        Text(role.name)
                    }
                }
            }
            .navigationTitle("指定发言人")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(minWidth: 200, minHeight: 200)
    }
}

#Preview {
    ChatRoomDetailView(
        viewModel: NewPiViewModel(),
        controller: ChatRoomFlowController(
            chatroom: ChatRoom(
                name: "测试聊天室",
                projectPath: "/tmp"
            )
        )
    )
}

