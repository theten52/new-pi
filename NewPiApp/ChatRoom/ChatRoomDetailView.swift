import NewPiCore
import SwiftUI

/// 聊天室详情视图
struct ChatRoomDetailView: View {
    @ObservedObject var viewModel: NewPiViewModel
    let chatroom: ChatRoom
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runtime: ChatRoomRuntime
    @State private var loop: ChatRoomLoop
    @State private var inputText = ""
    @State private var showingVoteSheet = false
    @State private var showingRolePicker = false
    
    init(viewModel: NewPiViewModel, chatroom: ChatRoom) {
        self.viewModel = viewModel
        self.chatroom = chatroom
        self._runtime = StateObject(wrappedValue: ChatRoomRuntime(chatroom: chatroom))
        self.loop = ChatRoomLoop()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            headerBar
            
            // 消息列表
            messageList
            
            // 输入栏
            inputBar
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            loadMessages()
        }
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
                Button("设置") { }
                Divider()
                Button("停止", role: .destructive) { dismiss() }
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
                    // 按阶段分组显示
                    let groupedMessages = groupMessagesByPhase()
                    
                    ForEach(groupedMessages, id: \.phase) { group in
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
                    Task { await triggerNextSpeaker() }
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
                .disabled(runtime.isRunning)
                
                Spacer()
                
                // 阶段流转按钮
                switch runtime.chatroom.currentPhase {
                case .discussion:
                    Button("结束讨论") {
                        Task { try? await loop.advancePhase(runtime: runtime) }
                    }
                case .voting:
                    Button("投票") {
                        showingVoteSheet = true
                    }
                case .execution:
                    Button("进入 Review") {
                        Task { try? await loop.advancePhase(runtime: runtime) }
                    }
                case .review:
                    HStack {
                        Button("通过") {
                            Task { try? loop.handleReviewResult(runtime: runtime, approved: true) }
                        }
                        Button("需修改") {
                            Task { try? loop.handleReviewResult(runtime: runtime, approved: false) }
                        }
                        .disabled(runtime.chatroom.isAtRoundLimit)
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
        .sheet(isPresented: $showingVoteSheet) {
            VoteSheet(candidates: extractCandidates(), onVote: { optionID in
                try? loop.userVote(optionID: optionID, runtime: runtime)
            })
        }
        .sheet(isPresented: $showingRolePicker) {
            RolePickerSheet(roles: runtime.chatroom.configuredRoles) { roleID in
                Task { try? await loop.triggerSpeaker(roleID: roleID, runtime: runtime) }
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func loadMessages() {
        do {
            runtime.messages = try ChatRoomStore.shared.loadMessages(for: chatroom.id)
        } catch {
            runtime.error = error.localizedDescription
        }
    }
    
    private func sendUserMessage() {
        guard !inputText.isEmpty else { return }
        do {
            try loop.userSpeak(content: inputText, runtime: runtime)
            inputText = ""
        } catch {
            runtime.error = error.localizedDescription
        }
    }
    
    private func triggerNextSpeaker() async {
        do {
            try await loop.triggerNextSpeaker(runtime: runtime)
        } catch {
            runtime.error = error.localizedDescription
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
    let onVote: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List(candidates) { option in
                Button {
                    onVote(option.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(option.title)
                            .font(.headline)
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
