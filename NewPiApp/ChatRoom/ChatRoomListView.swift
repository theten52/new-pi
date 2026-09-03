import NewPiCore
import SwiftUI

/// 聊天室列表视图
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
