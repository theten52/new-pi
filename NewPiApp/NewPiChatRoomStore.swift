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
    /// 从点击推进到任务完全退出均为 true，用于消除 runtime.isRunning 设置前的竞态窗口。
    @Published private(set) var isTaskActive = false
    /// 流程错误（view 层 alert 展示；原 DetailView 的 @State flowError 上移）。
    @Published var flowError: String?
    @Published private(set) var directoryIssue: ChatRoomWorkingDirectory.Issue?
    /// transcript 适配层（CHATROOM-FLAT-MD Phase 2）：派生 id 缓存随控制器存活，
    /// 保证 diff 期间 phase 分隔行 / 工具卡的条目 id 稳定。
    private var transcriptAdapter = ChatRoomTranscriptAdapter()
    private var cancellables: Set<AnyCancellable> = []

    /// providers.json 读取器：自动压缩预算 + 角色引擎构造都需要各角色配置
    private let configStore = ProviderConfigStore()

    init(chatroom: ChatRoom, store: ChatRoomStore = .shared) {
        let manager = ChatRoomApprovalManager()
        self.approvalManager = manager
        self.runtime = ChatRoomRuntime(chatroom: chatroom)
        self.directoryIssue = ChatRoomWorkingDirectory.issue(for: chatroom.projectPath)
        self.loop = ChatRoomLoop(
            store: store,
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
        self.runtime.messages = (try? store.loadMessages(for: chatroom.id)) ?? []
        // 转发 runtime / approvalManager 的变更，view 侧只需 @ObservedObject 本控制器。
        runtime.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        approvalManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refreshWorkingDirectory() {
        let issue = ChatRoomWorkingDirectory.issue(for: runtime.chatroom.projectPath)
        if directoryIssue != issue { directoryIssue = issue }
    }

    private func validateWorkingDirectory() -> Bool {
        refreshWorkingDirectory()
        guard let directoryIssue else { return true }
        flowError = directoryIssue.localizedDescription
        return false
    }

    // MARK: - 发言推进（原 DetailView 的 trigger* 私有方法上移）

    func triggerNextSpeaker() {
        guard !isBusy, validateWorkingDirectory() else { return }
        isTaskActive = true
        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                runningTask = nil
                isTaskActive = false
            }
            do {
                try Task.checkCancellation()
                guard validateWorkingDirectory() else { return }
                try await loop.triggerNextSpeaker(runtime: runtime)
            } catch is CancellationError {
                // 用户停止运行，不算错误
            } catch {
                flowError = error.localizedDescription
            }
        }
    }

    func triggerSpeaker(roleID: String) {
        guard !isBusy, validateWorkingDirectory() else { return }
        isTaskActive = true
        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                runningTask = nil
                isTaskActive = false
            }
            do {
                try Task.checkCancellation()
                guard validateWorkingDirectory() else { return }
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
    }

    /// Task 刚创建、模型正在输出或工具审批等待期间都视为忙碌。
    /// 不能只看 runtime.isRunning：Task 从点击到 speak() 设置状态之间存在一个短窗口。
    var isBusy: Bool {
        isTaskActive || runtime.isRunning || !approvalManager.pendingApprovals.isEmpty
    }

    /// 列表只需要忙碌状态的翻转，不需要正文/Thinking/用量的每次发布。
    /// 使用 publisher 的新值组合；@Published 在 willSet 发射，此时读取 isBusy 会得到旧值。
    var busyChanges: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest3(
            $isTaskActive,
            runtime.$isRunning,
            approvalManager.$pendingApprovals.map { !$0.isEmpty }
        )
        .map { taskActive, running, awaitingApproval in taskActive || running || awaitingApproval }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    /// 消息 → transcript items，仍按视图更新全量适配。
    /// 本轮只隔离列表通知；适配成本用 check-chatroom-performance.sh 跟踪。
    func transcriptSnapshot() -> (items: [NewPiTranscriptItem], tintHues: [UUID: Int]) {
        transcriptAdapter.adapt(messages: runtime.messages, roles: runtime.chatroom.roles, liveSpeech: runtime.liveSpeech)
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
    @Published private(set) var directoryIssues: [String: ChatRoomWorkingDirectory.Issue] = [:]
    private var controllers: [String: ChatRoomFlowController] = [:]
    private var chatroomSyncCancellables: [String: AnyCancellable] = [:]
    private var controllerChangeCancellables: [String: Set<AnyCancellable>] = [:]
    private let store: ChatRoomStore

    init(store: ChatRoomStore = .shared) {
        self.store = store
        reload()
    }

    /// 聊天室与 Session 的当前项目相互独立：每个聊天室保存自己的工作目录，
    /// 因此侧边栏始终展示全部聊天室，不随 Session 切换项目而过滤或取消运行。
    func reload() {
        chatrooms = (try? store.listAll()) ?? []
        refreshWorkingDirectories()
    }

    func refreshWorkingDirectories() {
        let issues = Dictionary(uniqueKeysWithValues: chatrooms.compactMap { room in
            ChatRoomWorkingDirectory.issue(for: room.projectPath).map { (room.id, $0) }
        })
        if directoryIssues != issues { directoryIssues = issues }
        for controller in controllers.values { controller.refreshWorkingDirectory() }
    }

    /// 取（或惰性创建）某聊天室的流程控制器。
    func controller(for chatroom: ChatRoom) -> ChatRoomFlowController {
        if let existing = controllers[chatroom.id] { return existing }
        let controller = ChatRoomFlowController(chatroom: chatroom, store: store)
        controllers[chatroom.id] = controller
        // runtime.chatroom 随流程推进变化（阶段/轮数），同步回列表镜像让徽章即时刷新
        //（替代原 sheet onDismiss 的 loadChatrooms 刷新依赖）。
        chatroomSyncCancellables[chatroom.id] = controller.runtime.$chatroom
            .sink { [weak self] updated in
                guard let self, let index = self.chatrooms.firstIndex(where: { $0.id == updated.id }) else { return }
                self.chatrooms[index] = updated
            }
        // 跳过订阅的初始值，避免 body 中惰性创建控制器时再次使整个根视图失效。
        // 仍同步发布忙碌边界，删除等命令继续直接读取 controller.isBusy 做最终守卫。
        controller.busyChanges.dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &controllerChangeCancellables[chatroom.id, default: []])
        controller.$directoryIssue.removeDuplicates().dropFirst()
            .sink { [weak self] issue in
                guard let self, self.directoryIssues[chatroom.id] != issue else { return }
                self.directoryIssues[chatroom.id] = issue
            }
            .store(in: &controllerChangeCancellables[chatroom.id, default: []])
        return controller
    }

    /// 编辑后的配置同步（review #2）：除刷新列表镜像外，若该聊天室的 FlowController
    /// 已缓存，必须同步 runtime.chatroom——否则 detail 头部显示旧配置，且下次流程动作
    /// persistRuntimeState 会用旧副本回写、覆盖刚编辑的内容。运行中不同步（编辑入口
    /// 在运行时应被禁用，这里亦防一手）。
    func applyEdit(_ updated: ChatRoom) {
        reload()
        if let controller = controllers[updated.id], !controller.isBusy {
            controller.runtime.chatroom = updated
        }
    }

    /// 某聊天室是否正在运行或等待工具审批（供编辑、删除、导出入口统一做守卫）。
    func isRunning(chatroomID: String) -> Bool {
        controllers[chatroomID]?.isBusy ?? false
    }

    /// 删除聊天室：运行中一律拒绝，防止后台任务在目录删除后继续写消息或执行工具。
    func delete(_ chatroom: ChatRoom) throws {
        guard !isRunning(chatroomID: chatroom.id) else {
            throw ChatRoomRuntimeStoreError.cannotDeleteWhileRunning
        }
        try store.delete(id: chatroom.id)
        controllers.removeValue(forKey: chatroom.id)
        chatroomSyncCancellables.removeValue(forKey: chatroom.id)
        controllerChangeCancellables.removeValue(forKey: chatroom.id)
        reload()
    }
}

private enum ChatRoomRuntimeStoreError: LocalizedError {
    case cannotDeleteWhileRunning

    var errorDescription: String? {
        switch self {
        case .cannotDeleteWhileRunning:
            "聊天室正在运行或等待工具审批，请先停止运行再删除。"
        }
    }
}
