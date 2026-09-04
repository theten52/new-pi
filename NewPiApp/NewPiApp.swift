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
    @Environment(\.openWindow) private var openWindow
    @State private var showLogs = false
    @State private var showingChatrooms = false
    /// Session 列表当前展示的条数（增量展开：每次点 Show all 多显示 5 条）。
    @State private var sessionDisplayLimit = 5
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""

    private let recentSessionLimit = 5
    private let sessionDisplayIncrement = 5

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

                Section("Sessions") {
                    Button("New Session") {
                        Task { await viewModel.startNewSession() }
                    }
                    .disabled(viewModel.projectURL == nil)

                    if viewModel.savedSessions.isEmpty {
                        Text("No saved sessions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(displayedSessions) { summary in
                            Button {
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
                
                Section("聊天室") {
                    Button("聊天室列表") {
                        showingChatrooms = true
                    }
                    .disabled(viewModel.projectURL == nil)
                }
            }
            .navigationTitle("NewPi")
        } detail: {
            NewPiChatView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showingChatrooms) {
            ChatRoomListView(viewModel: viewModel)
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

/// 聊天室列表视图
struct ChatRoomListView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var chatrooms: [ChatRoom] = []
    @State private var showingCreateSheet = false
    @State private var selectedChatroom: ChatRoom?
    @State private var chatroomToEdit: ChatRoom?
    @State private var chatroomToDelete: ChatRoom?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Text("聊天室")
                    .font(.headline)
                Spacer()
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("创建聊天室")
            }
            
            // 聊天室列表
            if chatrooms.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("暂无聊天室")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("创建一个聊天室，让多个 AI 模型协作完成任务")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chatrooms) { chatroom in
                            ChatRoomRow(chatroom: chatroom) {
                                selectedChatroom = chatroom
                            }
                            .contextMenu {
                                Button {
                                    chatroomToEdit = chatroom
                                } label: {
                                    Label("编辑聊天室", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    chatroomToDelete = chatroom
                                } label: {
                                    Label("删除聊天室", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
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
                        deleteChatroom(chatroomToDelete)
                        chatroomToDelete = nil
                    }
                    Button("取消", role: .cancel) {
                        chatroomToDelete = nil
                    }
                } message: {
                    Text("将删除聊天室配置与全部对话记录，不可恢复。")
                }
            }
            
            // 错误信息
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            loadChatrooms()
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateChatRoomView(viewModel: viewModel) { chatroom in
                chatrooms.insert(chatroom, at: 0)
            }
        }
        .sheet(item: $selectedChatroom, onDismiss: {
            // 从详情页回来刷新阶段徽章/轮数/时间
            loadChatrooms()
        }) { chatroom in
            ChatRoomDetailView(viewModel: viewModel, chatroom: chatroom)
        }
        .sheet(item: $chatroomToEdit) { chatroom in
            EditChatRoomView(
                viewModel: viewModel,
                chatroom: chatroom,
                conversationStarted: ChatRoomStore.shared.hasMessages(for: chatroom.id)
            ) { updated in
                if let index = chatrooms.firstIndex(where: { $0.id == updated.id }) {
                    chatrooms[index] = updated
                }
            }
        }
    }

    private func loadChatrooms() {
        do {
            chatrooms = try ChatRoomStore.shared.listAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChatroom(_ chatroom: ChatRoom?) {
        guard let chatroom else { return }
        do {
            try ChatRoomStore.shared.delete(id: chatroom.id)
            chatrooms.removeAll { $0.id == chatroom.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 聊天室行视图
struct ChatRoomRow: View {
    let chatroom: ChatRoom
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(chatroom.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    PhaseBadge(phase: chatroom.currentPhase)
                }
                
                if !chatroom.description.isEmpty {
                    Text(chatroom.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                HStack {
                    // 角色图标
                    HStack(spacing: 4) {
                        ForEach(chatroom.configuredRoles) { role in
                            Image(systemName: role.icon)
                                .font(.caption2)
                                .help(role.name)
                        }
                    }
                    
                    Spacer()
                    
                    // 轮数
                    if chatroom.currentPhase == .execution || chatroom.currentPhase == .review {
                        Text("第 \(chatroom.reviewRoundCount) 轮")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    // 时间
                    Text(chatroom.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
    ChatRoomListView(viewModel: NewPiViewModel())
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
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
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
                        RoleConfigRow(
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
        }
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

/// 角色配置行
struct RoleConfigRow: View {
    @Binding var role: ChatRoomRole
    let providerProfiles: [ProviderProfile]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: role.icon)
                    .frame(width: 20)
                Text(role.name)
                    .font(.headline)
            }
            
            Text(role.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack {
                // Provider 选择
                Picker("Provider", selection: $role.providerProfileID) {
                    Text("未选择").tag(nil as String?)
                    ForEach(providerProfiles) { profile in
                        Text(profile.name).tag(profile.id as String?)
                    }
                }
                .frame(width: 150)
                
                // Model 选择
                if let providerID = role.providerProfileID,
                   let profile = providerProfiles.first(where: { $0.id == providerID }) {
                    Picker("Model", selection: $role.modelID) {
                        Text("未选择").tag(nil as String?)
                        ForEach(profile.models, id: \.self) { model in
                            Text(model).tag(model as String?)
                        }
                    }
                    .frame(width: 150)
                }
            }
        }
        .padding(.vertical, 4)
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
                        RoleConfigRow(
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
    let chatroom: ChatRoom

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runtime: ChatRoomRuntime
    @StateObject private var approvalManager: ChatRoomApprovalManager
    @State private var loop: ChatRoomLoop
    @State private var inputText = ""
    @State private var showingVoteSheet = false
    @State private var showingRolePicker = false
    @State private var showingEndDiscussionDialog = false
    @State private var showingEditConfig = false
    @State private var runningTask: Task<Void, Never>?
    @State private var flowError: String?

    init(viewModel: NewPiViewModel, chatroom: ChatRoom) {
        self.viewModel = viewModel
        self.chatroom = chatroom
        let manager = ChatRoomApprovalManager()
        self._approvalManager = StateObject(wrappedValue: manager)
        self._runtime = StateObject(wrappedValue: ChatRoomRuntime(chatroom: chatroom))
        self.loop = ChatRoomLoop(approvalManager: manager)
    }

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
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            loadMessages()
        }
        .onDisappear {
            // 关闭详情页时取消运行中的发言/审批等待，避免审批 UI 随页面消失后
            // continuation 无人唤醒、任务永久挂起
            runningTask?.cancel()
            runningTask = nil
        }
        .alert(
            "聊天室提示",
            isPresented: Binding(
                get: { flowError != nil },
                set: { if !$0 { flowError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(flowError ?? "")
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
                    runningTask?.cancel()
                    runningTask = nil
                }
                .disabled(!runtime.isRunning)
                Divider()
                Button("结束流程", role: .destructive) {
                    do {
                        try loop.stopFlow(runtime: runtime)
                    } catch {
                        flowError = error.localizedDescription
                    }
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
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 按阶段分组显示（同一阶段在多轮执行/Review 后会出现多次，
                    // 用组序号做 ID，不能用 phase 本身）
                    let groupedMessages = groupMessagesByPhase()

                    ForEach(Array(groupedMessages.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group.messages) { message in
                                ChatRoomMessageView(message: message, roles: runtime.chatroom.roles)
                                    .id(message.id)
                            }
                        } header: {
                            PhaseHeader(phase: group.phase)
                        }
                    }
                    
                    // 当前发言者指示
                    if runtime.isRunning {
                        HStack {
                            if let speaker = runtime.currentSpeaker {
                                Image(systemName: speaker.icon)
                                    .font(.caption)
                                Text("\(speaker.name) 正在思考...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: runtime.messages.count) { _, _ in
                if let lastMessage = runtime.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
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
                    runningTask = Task { await triggerNextSpeaker() }
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

            // 输入框
            HStack {
                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit {
                        sendUserMessage()
                    }

                Button("发送") {
                    sendUserMessage()
                }
                .disabled(inputText.isEmpty)
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
                do {
                    try loop.userVote(optionID: optionID, runtime: runtime)
                } catch {
                    flowError = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showingRolePicker) {
            RolePickerSheet(roles: runtime.chatroom.configuredRoles) { roleID in
                runningTask = Task { await triggerSpeaker(roleID: roleID) }
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
                do {
                    try loop.addRoundFromPause(runtime: runtime)
                } catch {
                    flowError = error.localizedDescription
                }
            }
            Button("接受并完成") {
                do {
                    try loop.completeFromPause(runtime: runtime)
                } catch {
                    flowError = error.localizedDescription
                }
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

        let chars = runtime.messages.reduce(0) { sum, message in
            // 工具结果与参数也是上下文开销的一部分（决策 #7 预算）
            var total = sum + message.content.count
            total += message.toolResults?.reduce(0) { $0 + $1.output.count } ?? 0
            total += message.toolCalls?.reduce(0) { $0 + $1.arguments.count } ?? 0
            return total
        }
        let usedTokens = chars / 2 // 中英混合粗略估算：约 2 字符/token
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

    private func loadMessages() {
        do {
            runtime.messages = try ChatRoomStore.shared.loadMessages(for: chatroom.id)
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func sendUserMessage() {
        guard !inputText.isEmpty else { return }
        do {
            try loop.userSpeak(content: inputText, runtime: runtime)
            inputText = ""
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func endDiscussion(_ mode: ChatRoomDiscussionEndMode) {
        do {
            try loop.advancePhase(runtime: runtime, discussionEnd: mode)
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func advancePhase() {
        do {
            try loop.advancePhase(runtime: runtime)
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func review(approved: Bool) {
        do {
            try loop.handleReviewResult(runtime: runtime, approved: approved)
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func triggerNextSpeaker() async {
        do {
            try await loop.triggerNextSpeaker(runtime: runtime)
        } catch is CancellationError {
            // 用户停止运行，不算错误
        } catch {
            flowError = error.localizedDescription
        }
    }

    private func triggerSpeaker(roleID: String) async {
        do {
            try await loop.triggerSpeaker(roleID: roleID, runtime: runtime)
        } catch is CancellationError {
            // 用户停止运行，不算错误
        } catch {
            flowError = error.localizedDescription
        }
    }
    
    private func groupMessagesByPhase() -> [(phase: ChatRoomPhase, messages: [ChatRoomMessage])] {
        var groups: [(phase: ChatRoomPhase, messages: [ChatRoomMessage])] = []
        var currentPhase: ChatRoomPhase?
        var currentMessages: [ChatRoomMessage] = []
        
        for message in runtime.messages {
            if message.phase != currentPhase {
                if let phase = currentPhase {
                    groups.append((phase: phase, messages: currentMessages))
                }
                currentPhase = message.phase
                currentMessages = [message]
            } else {
                currentMessages.append(message)
            }
        }
        
        if let phase = currentPhase {
            groups.append((phase: phase, messages: currentMessages))
        }
        
        return groups
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

// MARK: - 消息视图

struct ChatRoomMessageView: View {
    let message: ChatRoomMessage
    let roles: [ChatRoomRole]
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 头像
            Image(systemName: roleIcon)
                .font(.caption)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                // 角色名
                Text(roleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // 内容
                Text(message.content)
                    .font(.body)
                
                // 候选方案
                if let candidates = message.candidates, !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("候选方案:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(candidates) { option in
                            HStack {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                Text(option.title)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // 工具调用
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("工具调用:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(toolCalls, id: \.id) { call in
                            ToolCallRow(
                                call: call,
                                result: message.toolResults?.first(where: { $0.toolCallID == call.id })
                            )
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            
            Spacer()
        }
    }
    
    private var roleIcon: String {
        if message.isUserMessage {
            return "person.fill"
        }
        return roles.first(where: { $0.id == message.roleID })?.icon ?? "person.fill"
    }
    
    private var roleName: String {
        if message.isUserMessage {
            return "用户"
        }
        return roles.first(where: { $0.id == message.roleID })?.name ?? "未知"
    }
}

// MARK: - 阶段标题

struct PhaseHeader: View {
    let phase: ChatRoomPhase
    
    var body: some View {
        HStack {
            Image(systemName: phaseIcon)
            Text(phaseName)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.vertical, 4)
        .foregroundStyle(phaseColor)
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
    
    private var phaseIcon: String {
        switch phase {
        case .discussion: "bubble.left.and.bubble.right"
        case .voting: "checkmark.circle"
        case .execution: "hammer"
        case .review: "magnifyingglass"
        case .completed: "checkmark.seal"
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

// MARK: - 工具调用行

struct ToolCallRow: View {
    let call: ChatRoomToolCall
    let result: ChatRoomToolResult?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(call.name)
                    .font(.caption.monospaced())
                if let result {
                    Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(result.isError ? .red : .green)
                }
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
            Text(call.arguments)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(call.arguments)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let result {
                        Text("结果\(result.isError ? "（失败）" : ""):")
                            .font(.caption2)
                            .foregroundStyle(result.isError ? .red : .secondary)
                        Text(result.output)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
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
        chatroom: ChatRoom(
            name: "测试聊天室",
            projectPath: "/tmp"
        )
    )
}

