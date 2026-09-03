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
