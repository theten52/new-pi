import Combine
import Foundation

/// 仅替代 VM 的公开发布接口，配套脚本提取真实 createSessionForComposer 实现。
/// 不构造生产 VM（它会恢复用户项目），不访问存储或模型。
@MainActor final class SessionRuntime {
    let sessionID = UUID()
    var transcript: [String] = []
}

@MainActor final class NewPiViewModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var isSwitchingSession = false
    var keptAliveRuntimes: [SessionRuntime] = []
    var active: SessionRuntime?
    var creation: (() async -> Void)?
    var starts = 0
    var composerSessionGeneration = 0
    func isActiveRuntime(_ runtime: SessionRuntime) -> Bool { runtime === active }
    func startNewSession() async {
        starts += 1
        composerSessionGeneration += 1
        isSwitchingSession = true
        defer { isSwitchingSession = false }
        await creation?()
    }
    func install() {
        let runtime = SessionRuntime()
        keptAliveRuntimes.append(runtime)
        active = runtime
    }
}

@main @MainActor struct ComposerCreationChecks {
    static func main() async {
        let project = URL(fileURLWithPath: "/synthetic/project")
        func model() -> NewPiViewModel {
            let vm = NewPiViewModel()
            vm.projectURL = project
            return vm
        }
        let success = model()
        success.creation = { [weak success] in await Task.yield(); success?.install() }
        let accepted = await success.createSessionForComposer(project: project)
        precondition(accepted === success.active && accepted != nil && success.starts == 1)
        let duplicate = await success.createSessionForComposer(project: project)
        precondition(duplicate == nil && success.starts == 1, "已有活跃会话不重复创建")

        let failure = model()
        let failed = await failure.createSessionForComposer(project: project)
        precondition(failed == nil, "创建失败没有目标")

        let superseded = model()
        superseded.creation = { [weak superseded] in
            await Task.yield()
            superseded?.isSwitchingSession = true // 同项目另一次 begin/resume 的同步取号发布
            superseded?.composerSessionGeneration += 1
            superseded?.install()
        }
        let wrongSession = await superseded.createSessionForComposer(project: project)
        precondition(wrongSession == nil, "第二代会话不能接收原草稿")

        let aba = model()
        aba.creation = { [weak aba] in
            aba?.composerSessionGeneration += 1
            aba?.projectURL = URL(fileURLWithPath: "/synthetic/other")
            aba?.projectURL = project
            aba?.install()
        }
        let wrongProject = await aba.createSessionForComposer(project: project)
        precondition(wrongProject == nil, "项目ABA不借相同路径绕过守卫")

        let shutdown = model()
        shutdown.creation = { [weak shutdown] in
            shutdown?.install()
            shutdown?.composerSessionGeneration += 1
            shutdown?.isSwitchingSession = false
            // 模拟 shutdown 的 await：projectURL 与 active runtime 尚未清除。
            await Task.yield()
        }
        let shuttingDown = await shutdown.createSessionForComposer(project: project)
        precondition(shuttingDown == nil, "shutdown窗口不能借旧项目/旧runtime接收草稿")

        let used = model()
        used.creation = { [weak used] in used?.install(); used?.active?.transcript = ["已接收其他输入"] }
        let overwritten = await used.createSessionForComposer(project: project)
        precondition(overwritten == nil, "不借已使用会话自动发送")

        let cancelled = model()
        let task = Task { @MainActor in await cancelled.createSessionForComposer(project: project) }
        task.cancel()
        let result = await task.value
        precondition(result == nil && cancelled.starts == 0, "已取消任务不开始创建")
        print("PASS: composer creation guard scenarios; API fixture only, no production VM/user data")
    }
}