import Combine
import Foundation
import NewPiCore

/// 单个聊天室的流程控制器（CHATROOM-FLAT-MD Phase 1）。
///
/// 原来 ChatRoomRuntime / ChatRoomLoop / ChatRoomApprovalManager / runningTask 都是
/// ChatRoomDetailView 的 @StateObject/@State —— 聊天室是 sheet，关窗即销毁整个运行时，
/// 与「讨论是长期运行的流程」语义冲突。平铺化后它们的生命周期上提到本控制器：
/// UI 切换（选走再选回）不再销毁运行时，讨论流程持续进行（对齐 session 后台事件循环语义）。
///
/// view 只观察本控制器一个对象：runtime / approvalManager 的变更在这里转发。
@MainActor
final class ChatRoomFlowController: ObservableObject {
    let runtime: ChatRoomRuntime
    let approvalManager: ChatRoomApprovalManager
    private let loop: ChatRoomLoop
    /// 运行中的发言任务（原 DetailView.runningTask）。不再随 view disappear 取消——
    /// 审批 continuation 由本控制器持有的 approvalManager 承载，切回时审批 sheet
    /// 会随 pendingApprovals 自动重弹，任务无需中断。
    private var runningTask: Task<Void, Never>?
    /// 流程错误（view 层 alert 展示；原 DetailView 的 @State flowError 上移）。
    @Published var flowError: String?
    /// transcript 适配层（CHATROOM-FLAT-MD Phase 2）：派生 id 缓存随控制器存活，
    /// 保证 diff 期间 phase 分隔行 / 工具卡的条目 id 稳定。
    private var transcriptAdapter = ChatRoomTranscriptAdapter()
    private var cancellables: Set<AnyCancellable> = []

    /// providers.json 读取器：自动压缩预算 + 角色引擎构造都需要各角色配置
    private let configStore = ProviderConfigStore()

    init(chatroom: ChatRoom) {
        let manager = ChatRoomApprovalManager()
        self.approvalManager = manager
        self.runtime = ChatRoomRuntime(chatroom: chatroom)
        self.loop = ChatRoomLoop(
            approvalManager: manager,
            // 决策 #7（2026-09-05 调整）：自动压缩预算 = 各角色最小 context window
            contextBudgetTokens: { [configStore] room in
                guard let config = try? configStore.load() else { return nil }
                var limit: Int?
                for role in room.configuredRoles {
                    guard let profileID = role.providerProfileID,
                          let modelID = role.modelID,
                          let profile = config.profiles.first(where: { $0.id == profileID }) else { continue }
                    let window = profile.contextWindow(for: modelID)
                    if window > 0 { limit = min(limit ?? window, window) }
                }
                return limit
            },
            // Phase B：角色发言引擎——profile → LLMProvider + ModelConfig
            engineProvider: { [configStore] role in
                let config = try configStore.load()
                guard let profile = config.profiles.first(where: { $0.id == role.providerProfileID }) else {
                    throw ChatRoomError.roleNotConfigured(role.id)
                }
                let llm = try LLMProviderFactory.make(
                    profile: profile,
                    credentialResolver: ProviderCredentialResolver.makeDefault()
                )
                let model = ModelConfig(
                    provider: profile.preset.rawValue,
                    modelID: role.modelID ?? profile.modelID,
                    // 角色级档位优先；未单独设置则跟随所绑 provider 的默认档位。
                    thinkingLevel: role.thinkingLevel ?? profile.thinkingLevel,
                    maxTokens: profile.effectiveMaxTokens
                )
                return ChatRoomRoleEngine(llm: llm, model: model)
            },
            // Phase B：MCP 工具注入
            mcpToolsProvider: { await MCPToolLoader.loadAgentTools() }
        )
        // 历史消息在控制器创建时加载一次（原 DetailView.onAppear 的 loadMessages 上移）。
        self.runtime.messages = (try? ChatRoomStore.shared.loadMessages(for: chatroom.id)) ?? []
        // 转发 runtime / approvalManager 的变更，view 侧只需 @ObservedObject 本控制器。
        runtime.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        approvalManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - 发言推进（原 DetailView 的 trigger* 私有方法上移）

    func triggerNextSpeaker() {
        runningTask = Task {
            do {
                try await loop.triggerNextSpeaker(runtime: runtime)
            } catch is CancellationError {
                // 用户停止运行，不算错误
            } catch {
                flowError = error.localizedDescription
            }
        }
    }

    func triggerSpeaker(roleID: String) {
        runningTask = Task {
            do {
                try await loop.triggerSpeaker(roleID: roleID, runtime: runtime)
            } catch is CancellationError {
                // 用户停止运行，不算错误
            } catch {
                flowError = error.localizedDescription
            }
        }
    }

    // MARK: - 阶段流转与用户操作（同步 throws，错误统一落 flowError）

    /// 停止当前运行（原 DetailView「停止当前运行」按钮）：取消发言任务；
    /// 未决审批会被 approvalManager 以「已取消」拒绝并唤醒循环。
    func cancelRunning() {
        runningTask?.cancel()
        runningTask = nil
    }

    /// 消息 → transcript items（CHATROOM-FLAT-MD Phase 2，视图每次更新时调用；
    /// O(n) 全量重算，聊天室消息量级小，可接受）。
    func transcriptSnapshot() -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) {
        transcriptAdapter.adapt(messages: runtime.messages, roles: runtime.chatroom.roles, isRunning: runtime.isRunning)
    }

    func userSpeak(content: String) {
        do { try loop.userSpeak(content: content, runtime: runtime) } catch { flowError = error.localizedDescription }
    }

    func userVote(optionID: String) {
        do { try loop.userVote(optionID: optionID, runtime: runtime) } catch { flowError = error.localizedDescription }
    }

    func endDiscussion(_ mode: ChatRoomDiscussionEndMode) {
        do { try loop.advancePhase(runtime: runtime, discussionEnd: mode) } catch { flowError = error.localizedDescription }
    }

    func advancePhase() {
        do { try loop.advancePhase(runtime: runtime) } catch { flowError = error.localizedDescription }
    }

    func review(approved: Bool) {
        do { try loop.handleReviewResult(runtime: runtime, approved: approved) } catch { flowError = error.localizedDescription }
    }

    func addRoundFromPause() {
        do { try loop.addRoundFromPause(runtime: runtime) } catch { flowError = error.localizedDescription }
    }

    func completeFromPause() {
        do { try loop.completeFromPause(runtime: runtime) } catch { flowError = error.localizedDescription }
    }

    func stopFlow() {
        do { try loop.stopFlow(runtime: runtime) } catch { flowError = error.localizedDescription }
    }
}

/// 聊天室运行时缓存（CHATROOM-FLAT-MD Phase 1）：sidebar 列表数据源 + 每个聊天室的
/// 长命 ChatRoomFlowController。仿 SessionRuntime 的缓存语义——控制器随 app 存活，
/// 不随详情视图的显隐生灭。
@MainActor
final class ChatRoomRuntimeStore: ObservableObject {
    static let shared = ChatRoomRuntimeStore()

    /// sidebar 聊天室列表（ChatRoomStore.listAll 的内存镜像）。
    @Published private(set) var chatrooms: [ChatRoom] = []
    private var controllers: [String: ChatRoomFlowController] = [:]
    private var chatroomSyncCancellables: [String: AnyCancellable] = [:]
    /// 当前应用项目。聊天室采用项目级作用域；nil 时侧边栏不展示全局聊天室。
    private var activeProjectPath: String?

    private init() {}

    /// 切换当前项目。旧项目的隐藏运行必须取消，防止用户已看到项目 B 时，
    /// 项目 A 的聊天室仍在后台执行工具或等待不可见的审批。
    func setProject(_ projectURL: URL?) {
        let newPath = projectURL?.standardizedFileURL.resolvingSymlinksInPath().path
        if activeProjectPath != newPath {
            for controller in controllers.values {
                controller.cancelRunning()
            }
            controllers.removeAll()
            chatroomSyncCancellables.removeAll()
            activeProjectPath = newPath
        }
        reload()
    }

    /// 从磁盘重载当前项目的聊天室列表。
    func reload() {
        guard let activeProjectPath else {
            chatrooms = []
            return
        }
        let all = (try? ChatRoomStore.shared.listAll()) ?? []
        chatrooms = all.filter {
            URL(fileURLWithPath: $0.projectPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path == activeProjectPath
        }
    }

    /// 取（或惰性创建）某聊天室的流程控制器。
    func controller(for chatroom: ChatRoom) -> ChatRoomFlowController {
        if let existing = controllers[chatroom.id] { return existing }
        let controller = ChatRoomFlowController(chatroom: chatroom)
        controllers[chatroom.id] = controller
        // runtime.chatroom 随流程推进变化（阶段/轮数），同步回列表镜像让徽章即时刷新
        //（替代原 sheet onDismiss 的 loadChatrooms 刷新依赖）。
        chatroomSyncCancellables[chatroom.id] = controller.runtime.$chatroom
            .sink { [weak self] updated in
                guard let self, let index = self.chatrooms.firstIndex(where: { $0.id == updated.id }) else { return }
                self.chatrooms[index] = updated
            }
        return controller
    }

    /// 编辑后的配置同步（review #2）：除刷新列表镜像外，若该聊天室的 FlowController
    /// 已缓存，必须同步 runtime.chatroom——否则 detail 头部显示旧配置，且下次流程动作
    /// persistRuntimeState 会用旧副本回写、覆盖刚编辑的内容。运行中不同步（编辑入口
    /// 在运行时应被禁用，这里亦防一手）。
    func applyEdit(_ updated: ChatRoom) {
        reload()
        if let controller = controllers[updated.id], !controller.runtime.isRunning {
            controller.runtime.chatroom = updated
        }
    }

    /// 某聊天室是否正在运行（供 sidebar 编辑入口做禁用守卫；未缓存的控制器视为未运行）。
    func isRunning(chatroomID: String) -> Bool {
        controllers[chatroomID]?.runtime.isRunning ?? false
    }

    /// 删除聊天室：磁盘配置 + 运行时缓存 + 列表镜像一并清理。
    func delete(_ chatroom: ChatRoom) throws {
        try ChatRoomStore.shared.delete(id: chatroom.id)
        controllers.removeValue(forKey: chatroom.id)
        chatroomSyncCancellables.removeValue(forKey: chatroom.id)
        reload()
    }
}
