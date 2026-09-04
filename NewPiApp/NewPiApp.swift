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

// MARK: - ChatRoom List View (临时实现)

struct ChatRoomListView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var chatrooms: [ChatRoom] = []
    @State private var showingCreateSheet = false
    @State private var selectedChatroom: ChatRoom?
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
                        }
                    }
                    .padding(.vertical, 8)
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
        .sheet(item: $selectedChatroom) { chatroom in
            ChatRoomDetailView(viewModel: viewModel, chatroom: chatroom)
        }
    }
    
    private func loadChatrooms() {
        do {
            chatrooms = try ChatRoomStore.shared.listAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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

// MARK: - Create ChatRoom View (临时实现)

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

// MARK: - ChatRoom Detail View (简化实现)

struct ChatRoomDetailView: View {
    @ObservedObject var viewModel: NewPiViewModel
    let chatroom: ChatRoom
    
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatRoomMessage] = []
    @State private var inputText = ""
    @State private var isRunning = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading) {
                    Text(chatroom.name)
                        .font(.headline)
                    PhaseBadge(phase: chatroom.currentPhase)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()
            .background(.bar)
            
            // 消息列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatRoomMessageRow(message: message, roles: chatroom.roles)
                    }
                }
                .padding()
            }
            
            // 输入栏
            HStack {
                TextField("输入消息...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        sendUserMessage()
                    }
                
                Button("发送") {
                    sendUserMessage()
                }
                .disabled(inputText.isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            loadMessages()
        }
    }
    
    private func loadMessages() {
        do {
            messages = try ChatRoomStore.shared.loadMessages(for: chatroom.id)
        } catch {
            print("加载消息失败: \(error)")
        }
    }
    
    private func sendUserMessage() {
        guard !inputText.isEmpty else { return }
        
        let message = ChatRoomMessage(
            chatroomID: chatroom.id,
            roleID: "user",
            content: inputText,
            phase: chatroom.currentPhase
        )
        
        messages.append(message)
        
        do {
            try ChatRoomStore.shared.appendMessage(message, to: chatroom.id)
        } catch {
            print("保存消息失败: \(error)")
        }
        
        inputText = ""
    }
}

struct ChatRoomMessageRow: View {
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
