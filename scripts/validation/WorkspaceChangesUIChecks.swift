import AppKit
import Combine
import Foundation
import NewPiCore
import SwiftUI

// 与完整生产文件拼接为一个编译单元。绝不构造替代 Reader / Git / model，
// 不调用 refreshNow / select / selectArea / setDirectory，也不写生产 @State。
// 父级输入 directory 的变化模拟宿主切目录；所有改动面板操作均来自真实控件事件。
@MainActor private enum WorkspaceGeometry {
    static var frames: [String: [String: CGRect]] = [:]
    static var owners: [String: [String: UUID]] = [:]
    static var anchors: [String: WeakAnchor] = [:]
    final class WeakAnchor {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
}

private struct WorkspaceCoordinate: NSViewRepresentable {
    let space: String
    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        WorkspaceGeometry.anchors[space] = .init(anchor)
        return anchor
    }
    func updateNSView(_ view: Anchor, context: Context) {}
}

@MainActor private struct WorkspaceMeasurement: ViewModifier {
    let key: String
    let space: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
            WorkspaceGeometry.frames[space, default: [:]][key] = frame
            WorkspaceGeometry.owners[space, default: [:]][key] = owner
        }
        .onDisappear {
            // 只撤销自己的测量；旧分支卸载不能删除新分支刚注册的坐标。
            if WorkspaceGeometry.owners[space]?[key] == owner {
                WorkspaceGeometry.frames[space]?[key] = nil
                WorkspaceGeometry.owners[space]?[key] = nil
            }
        }
    }
}

private extension View {
    @MainActor
    func workspaceMeasure(_ key: String, space: String = "workspace-panel") -> some View {
        modifier(WorkspaceMeasurement(key: key, space: space))
    }
}

@MainActor private final class WorkspaceInput: ObservableObject {
    @Published var directory: URL?
    init(_ directory: URL?) { self.directory = directory }
}

private struct WorkspaceRoot: View {
    @ObservedObject var input: WorkspaceInput
    let button: Bool
    var body: some View {
        if button {
            VStack {
                NewPiChangesButton(directory: input.directory)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "workspace-button")
            .background(WorkspaceCoordinate(space: "workspace-button"))
        } else {
            NewPiChangesPanel(directory: input.directory)
        }
    }
}

@main @MainActor private struct WorkspaceChangesUIChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Unavailable: Error, CustomStringConvertible { let description: String }
    static var passes = 0
    static var failures = 0
    static var skips = 0
    static let untracked = "c-new-新 文件.txt"
    static let paths: Set<String> = ["a-both.txt", "b-deleted.txt", untracked]
    static let oldTokens = ["BASE_A", "STAGED_A", "WORKTREE_A", "UNTRACKED_A", "DELETED_A", "a-both.txt", untracked]

    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        passes += 1
        print("PASS: \(label)")
    }

    static func group(_ name: String, _ body: () async throws -> Void) async {
        print("CASE: \(name)")
        fflush(nil)
        do { try await body() }
        catch let error as Unavailable { skips += 1; print("SKIP: \(name): \(error)") }
        catch { failures += 1; print("FAIL: \(name): \(error)") }
        fflush(nil)
    }

    static func wait(_ label: String, seconds: Double = 10, unavailable: Bool = false,
                     _ condition: () throws -> Bool) async throws {
        if try await observe(seconds: seconds, condition) { return }
        if unavailable { throw Unavailable(description: label) }
        throw Failure(description: "\(label)：\(seconds)s 内未满足")
    }

    static func observe(seconds: Double, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // 只遍历本测试窗口，公开 object-returning getter 可兼容未声明完整协议的 SwiftUI 节点。
    // 不使用 KVC、私有 selector、AXUIElementCreateApplication 或其他进程的 AX 树。
    static func objects(_ root: NSObject) throws -> [NSObject] {
        var pending = [root], result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        while let object = pending.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            guard seen.count <= 8000 else { throw Unavailable(description: "公开 AX 树超过 8000 节点") }
            result.append(object)
            for name in ["accessibilityChildren", "accessibilityVisibleChildren", "accessibilityRows"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector),
                   let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                    pending.append(contentsOf: children)
                }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    static func texts(_ window: NSWindow) throws -> [String] {
        guard let content = window.contentView else { throw Failure(description: "测试窗口缺少 contentView") }
        return try objects(content).flatMap { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { name -> String? in
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector) else { return nil }
                let value = object.perform(selector)?.takeUnretainedValue()
                if let text = value as? String { return text }
                return (value as? NSAttributedString)?.string
            }
        }
    }

    static func contains(_ text: String, in window: NSWindow) throws -> Bool {
        try texts(window).contains { $0.contains(text) }
    }

    // 验证 diff 的实际 AX 文本，不把 model.detail、传入参数或静态源码当成屏幕输出。
    static func diffText(_ window: NSWindow, present: [String], absent: [String]) async throws {
        try await wait("真实 diff 文本 \(present)") {
            let values = try texts(window)
            return present.allSatisfy { token in values.contains { $0.contains(token) } }
        }
        try await settled(window)
        let values = try texts(window)
        try require(present.allSatisfy { token in values.contains { $0.contains(token) } }
                && absent.allSatisfy { token in !values.contains { $0.contains(token) } },
                    "真实 diff 包含 \(present)，不混入 \(absent)")
    }

    static func rect(_ key: String, space: String = "workspace-panel", window: NSWindow) throws -> CGRect {
        guard let anchor = WorkspaceGeometry.anchors[space]?.view, anchor.window === window,
              let rect = WorkspaceGeometry.frames[space]?[key], !rect.isNull, !rect.isInfinite,
              rect.width > 0, rect.height > 0 else {
            throw Failure(description: "缺少当前窗口的有效几何：\(space)/\(key)")
        }
        return rect
    }

    static func screenRect(_ rect: CGRect, space: String, window: NSWindow) throws -> CGRect {
        guard let anchor = WorkspaceGeometry.anchors[space]?.view, anchor.window === window else {
            throw Failure(description: "几何锚点未挂载到目标测试窗口")
        }
        return window.convertToScreen(anchor.convert(rect, to: nil))
    }

    static func viewport(_ window: NSWindow) throws -> CGRect {
        guard let view = window.contentView else { throw Failure(description: "缺少窗口视口") }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    static func focus(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait("测试窗口无法获得焦点；不发送全局鼠标事件", seconds: 3, unavailable: true) {
            window.isKeyWindow && NSApp.isActive
        }
    }

    // 两个事件先排队，允许真实 Button 进入正常 tracking loop。
    static func mouse(_ screenPoint: CGPoint, window: NSWindow, settle: Bool = true) async throws {
        if !window.isKeyWindow || !NSApp.isActive { try await focus(window) }
        try require(try viewport(window).contains(screenPoint), "鼠标命中点在测试窗口视口内")
        guard let content = window.contentView else { throw Failure(description: "窗口内容已卸载") }
        let point = window.convertPoint(fromScreen: screenPoint)
        let parentPoint = content.superview?.convert(point, from: nil) ?? point
        guard content.hitTest(parentPoint) != nil else {
            throw Failure(description: "真实窗口鼠标未命中任何视图")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw Unavailable(description: "AppKit 无法创建鼠标事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        if settle { try await Task.sleep(for: .milliseconds(120)) }
    }

    static func click(_ key: String, window: NSWindow, space: String = "workspace-panel",
                      settle: Bool = true) async throws {
        // 先聚焦再测量，sheet 激活、文件切换和刷新都可能改变几何。
        if !window.isKeyWindow || !NSApp.isActive { try await focus(window) }
        try await settled(window, key: key, space: space)
        let measured = try rect(key, space: space, window: window)
        let target = try screenRect(measured, space: space, window: window)
        try require(try viewport(window).insetBy(dx: -1, dy: -1).contains(target), "\(key) 完整位于窗口内")
        if key.hasPrefix("row:") {
            let list = try screenRect(rect("list", window: window), space: space, window: window)
            try require(list.insetBy(dx: -1, dy: -1).contains(target), "真实文件行在 ScrollView 可见区域内")
        } else if key.hasPrefix("area:") {
            let group = try screenRect(rect("picker", window: window), space: space, window: window)
            try require(group.insetBy(dx: -1, dy: -1).contains(target), "真实分区按钮在分区组内")
        }
        print("MOUSE: \(key) rect=\(target)")
        try await mouse(CGPoint(x: target.midX, y: target.midY), window: window, settle: settle)
        if settle && (key.hasPrefix("row:") || key.hasPrefix("area:")) {
            try await settled(window)
        }
    }

    static func chooseArea(_ area: WorkspaceDiffArea, window: NSWindow, settle: Bool = true) async throws {
        // 生产按钮的实际布局坐标，不猜等分、不调用 action 或 model。
        try await click("area:" + area.rawValue, window: window, settle: settle)
    }

    static func settled(_ window: NSWindow, key: String = "diff", space: String = "workspace-panel") async throws {
        var previous: [String: CGRect] = [:]
        var stableSince = ProcessInfo.processInfo.systemUptime
        try await wait("当前控件/详情/布局稳定：\(key)") {
            let values = try texts(window)
            let frames = WorkspaceGeometry.frames[space] ?? [:]
            let pending = values.contains { value in
                ["正在读取 Git 改动", "正在刷新；", "正在读取文件…"].contains(where: value.contains)
            }
            let needsDetail = key == "diff" || key.hasPrefix("row:") || key.hasPrefix("area:")
            let ready = WorkspaceGeometry.anchors[space]?.view?.window === window
                && frames[key] != nil && (!needsDetail || frames["diff"] != nil) && !pending
            if !ready || frames != previous {
                stableSince = ProcessInfo.processInfo.systemUptime
                previous = frames
                return false
            }
            return ProcessInfo.processInfo.systemUptime - stableSince >= 0.15
        }
    }

    static func withWindow(directory: URL?, button: Bool = false, width: CGFloat = 920, dark: Bool = false,
                           _ body: (WorkspaceInput, NSWindow) async throws -> Void) async throws {
        guard !NSScreen.screens.isEmpty else { throw Unavailable(description: "无图形桌面") }
        WorkspaceGeometry.frames = [:]
        WorkspaceGeometry.owners = [:]
        WorkspaceGeometry.anchors = [:]
        let input = WorkspaceInput(directory)
        let host = NSHostingView(rootView: WorkspaceRoot(input: input, button: button))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NewPi · 临时 Git 改动 UI 校验"
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(CGSize(width: width, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await focus(window)
        try await wait("NSHostingView 尺寸与外观同步") {
            abs(host.bounds.width - width) < 1 && host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                == (dark ? .darkAqua : .aqua)
        }
        try await wait("公开 AX 未暴露真实组件文本", seconds: 3, unavailable: true) {
            try contains(button ? "改动" : "工作区 Git 改动", in: window)
        }
        try await body(input, window)
    }

    static func inventory(_ window: NSWindow, count: Int, expected: Set<String>) async throws {
        do {
            try await wait("最近完整清单显示 \(count) 个真实文件") {
                let values = try texts(window)
                return values.contains { $0.contains("最近完整清单：") && $0.contains("· \(count) 个文件；") }
                    && expected.allSatisfy { path in values.contains { $0 == path } }
            }
        } catch {
            print("DIAGNOSTIC: inventory AX=\(try texts(window).map { String($0.prefix(240)) })")
            print("DIAGNOSTIC: inventory geometry=\(WorkspaceGeometry.frames)")
            throw error
        }
        let values = try texts(window)
        try require(expected.allSatisfy { path in values.contains { $0 == path } }, "实际文件列表包含全部 \(expected.count) 个预期路径")
        try require(!values.contains { $0 == "ignored.txt" || $0.contains("MUST_NOT_APPEAR") }, "遵循真实 Git ignore，不显示被忽略文件")
        try require(values.contains { $0.contains(WorkspaceChanges.notice) }, "真实只读/非本轮独占提示")
    }

    static func selections(_ window: NSWindow) async throws {
        // 默认第一项不能代替选择测试：先点击删除项，再返回同时有两个分区的文件。
        try await click("row:b-deleted.txt", window: window)
        try await diffText(window, present: ["-DELETED_A"], absent: ["+WORKTREE_A", "+STAGED_A", "UNTRACKED_A"])
        try await click("row:a-both.txt", window: window)
        try await chooseArea(.staged, window: window)
        try await diffText(window, present: ["-BASE_A", "+STAGED_A"], absent: ["WORKTREE_A", "UNTRACKED_A", "DELETED_A"])
        try await chooseArea(.unstaged, window: window)
        try await diffText(window, present: ["-STAGED_A", "+WORKTREE_A"], absent: ["BASE_A", "UNTRACKED_A", "DELETED_A"])
        try await click("row:" + untracked, window: window)
        try await diffText(window, present: ["UNTRACKED_A", "未跟踪文件内容预览（不是 Git diff）", "LONG_LINE_"],
                           absent: ["+WORKTREE_A", "+STAGED_A", "diff --git", "+UNTRACKED_A"])
        try require(try contains("未跟踪 · 内容预览", in: window), "未跟踪项只展示内容预览分区")
    }

    static func layout(_ window: NSWindow, width: CGFloat) throws {
        let view = try viewport(window)
        let panel = try rect("panel", window: window)
        try require(abs(view.width - width) < 1 && abs(panel.width - width) < 1, "真实面板/窗口宽度 = \(width)，未用扩大窗口掩盖越界")
        for key in ["panel", "title", "refresh", "done", "notice", "scope", "count", "list", "detail", "selected", "picker", "diff", "diff-scroll"] {
            let bounds = try screenRect(rect(key, window: window), space: "workspace-panel", window: window)
            try require(view.insetBy(dx: -1, dy: -1).contains(bounds), "\(width)pt: \(key) 不越出真实窗口 \(bounds.size)")
        }
        let list = try rect("list", window: window), detail = try rect("detail", window: window)
        let title = try rect("title", window: window), refresh = try rect("refresh", window: window), done = try rect("done", window: window)
        try require(title.maxX <= refresh.minX + 1 && refresh.maxX <= done.minX + 1, "标题/刷新/完成互不重叠")
        try require(width < 680 ? list.maxY <= detail.minY + 1 : list.maxX <= detail.minX + 1,
                    "真实 \(width < 680 ? "上下" : "左右") 响应式分栏不重叠")
        let diff = try rect("diff", window: window), scroll = try rect("diff-scroll", window: window)
        try require(detail.insetBy(dx: -1, dy: -1).contains(diff) && diff.insetBy(dx: -1, dy: -1).contains(scroll)
                    && scroll.width > 100 && scroll.height > 40, "1600 字符长行限制在真实双向滚动视口内")
        let selected = try rect("selected", window: window), picker = try rect("picker", window: window)
        try require(detail.insetBy(dx: -1, dy: -1).contains(selected)
                && detail.insetBy(dx: -1, dy: -1).contains(picker)
                && selected.maxY <= picker.minY + 1 && picker.maxY <= diff.minY + 1,
                "文件标题/分区/diff 保持在 detail 内且不互相遮挡")
    }

    static func refresh(_ root: URL) async throws {
        let repo = root.appendingPathComponent("repo-a"), file = repo.appendingPathComponent("a-both.txt")
        let added = repo.appendingPathComponent("d-refresh.txt")
        defer {
            // 只恢复本脚本自建 fixture，方便后续独立组；不访问生产仓库。
            do {
                try "WORKTREE_A\n".write(to: file, atomically: true, encoding: .utf8)
                if FileManager.default.fileExists(atPath: added.path) {
                    try FileManager.default.removeItem(at: added)
                }
            } catch { failures += 1; print("FAIL: fixture 恢复失败：\(error)") }
        }
        try await withWindow(directory: repo) { _, window in
            try await inventory(window, count: 3, expected: paths)
            try await click("row:a-both.txt", window: window)
            try await chooseArea(.unstaged, window: window)
            try await diffText(window, present: ["+WORKTREE_A"], absent: ["AFTER_REFRESH"])
            try "AFTER_REFRESH\n".write(to: file, atomically: true, encoding: .utf8)
            try "ADDED_BY_FIXTURE\n".write(to: added, atomically: true, encoding: .utf8)
            try require(!(try contains("AFTER_REFRESH", in: window)), "临时文件改变不会被冒充成已刷新 UI")
            try await click("refresh", window: window)
            try await inventory(window, count: 4, expected: paths.union(["d-refresh.txt"]))
            try await diffText(window, present: ["-STAGED_A", "+AFTER_REFRESH"], absent: ["WORKTREE_A"])
            try await click("row:d-refresh.txt", window: window)
            try await diffText(window, present: ["ADDED_BY_FIXTURE"], absent: ["+AFTER_REFRESH"])
        }
    }

    static func switching(_ root: URL, detail: Bool) async throws {
        let a = root.appendingPathComponent("repo-a"), b = root.appendingPathComponent("repo-b")
        try await withWindow(directory: a) { input, window in
            try await inventory(window, count: 3, expected: paths)
            try await click("row:a-both.txt", window: window)
            try await diffText(window, present: ["+WORKTREE_A"], absent: ["SWITCH_B"])
            var witnessed = false
            for attempt in 0..<8 {
                if detail {
                    try await chooseArea(attempt.isMultiple(of: 2) ? .staged : .unstaged, window: window, settle: false)
                } else {
                    try await click("refresh", window: window, settle: false)
                }
                witnessed = try await observe(seconds: 0.5) {
                    try contains(detail ? "正在读取文件…" : "正在刷新；下方为上次完整清单", in: window)
                }
                if witnessed { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            // 不注入延时、不篡改 Git 可执行文件、不停进程；未遇到真实在途请求就不谎报竞态通过。
            guard witnessed else {
                throw Unavailable(description: "8 次真实点击未捕获 \(detail ? "detail" : "status") loading；目录切换竞态未验证")
            }
            let host = window.contentView
            input.directory = b // 唯一宿主输入变化；无 .id、无重建 host、无生产 model 调用。
            var leftOldDirectory = false
            try await wait("过渡期清除 A 并显示 B 的真实 diff，期间不得再次出现 A") {
                let values = try texts(window)
                let showsOld = values.contains { value in
                    oldTokens.contains(where: value.contains) || value.contains(a.path)
                }
                if !showsOld { leftOldDirectory = true }
                else if leftOldDirectory { throw Failure(description: "切目录过渡期旧内容回填") }
                return leftOldDirectory && values.contains { $0.contains(b.path) }
                    && values.contains { $0.contains("+SWITCH_B") }
            }
            try await inventory(window, count: 1, expected: ["b-only.txt"])
            try await diffText(window, present: ["+SWITCH_B"], absent: oldTokens)
            try require(window.contentView === host, "在途读取时切目录复用同一 NSHostingView / 生产 Panel")
            // 覆盖 Reader 默认 8s 预算；整个窗口期持续查旧路径、清单根与 diff，不只看最后一帧。
            let deadline = ProcessInfo.processInfo.systemUptime + 9
            var samples = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                let values = try texts(window)
                if values.contains(where: { value in oldTokens.contains(where: value.contains) || value.contains(a.path) }) {
                    throw Failure(description: "目录切换后旧 \(detail ? "diff" : "清单") 回填，sample=\(samples)")
                }
                guard values.contains(where: { $0.contains("+SWITCH_B") }) else {
                    throw Failure(description: "B 已就绪后正确 diff 消失，sample=\(samples)")
                }
                samples += 1
                try await Task.sleep(for: .milliseconds(20))
            }
            try require(samples > 100, "真实在途 \(detail ? "diff" : "status") 切 A→B，9s/\(samples) 次采样无旧结果回填")
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure(description: "必须由配套 shell 创建隔离 fixture 后传入目录") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        try require(root.deletingLastPathComponent().path == temporaryRoot.path
                    && root.lastPathComponent.hasPrefix("newpi-workspace-changes-ui."), "fixture 必须为专用 /private/tmp 子目录")
        try require(try String(contentsOf: root.appendingPathComponent("fixture-owner"), encoding: .utf8)
                    == "newpi-workspace-changes-ui\n", "验证配套脚本 fixture 标识")
        let repo = root.appendingPathComponent("repo-a")
        for name in ["repo-a", "repo-b", "clean", "not-git"] {
            let directory = root.appendingPathComponent(name)
            try require(directory.resolvingSymlinksInPath().path == directory.path, "fixture 目录不是外部 symlink：\(name)")
        }
        let index = repo.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: index)
        await group("真实 ChangesButton 点击打开/完成关闭 sheet；子目录仍统计整个根目录") {
            try await withWindow(directory: repo.appendingPathComponent("nested"), button: true) { _, window in
                try await wait("按钮可访问名称显示真实去重计数 3") { try contains("3 个文件（最近一次完整读取）", in: window) }
                try require(window.attachedSheet == nil, "点击前未呈现面板")
                try await click("open", window: window, space: "workspace-button")
                try await wait("真实 Button 打开实际 NSWindow sheet") { window.attachedSheet?.isVisible == true }
                guard let sheet = window.attachedSheet else { throw Failure(description: "sheet 丢失") }
                try await inventory(sheet, count: 3, expected: paths)
                try require(try contains(repo.path, in: sheet), "从 nested 进入展示真实仓库根目录")
                await group("sheet 内真实文件/分区选择") { try await selections(sheet) }
                try await click("done", window: sheet)
                try await wait("真实完成按钮关闭 sheet") { window.attachedSheet == nil }
                try require(try contains("3 个文件（最近一次完整读取）", in: window), "关闭后按钮保留真实文件计数")
            }
        }
        for width in [CGFloat(420), CGFloat(920)] {
            for dark in [false, true] {
                await group("真实 Panel \(width)pt / \(dark ? "dark" : "light") 选择与边界") {
                    try await withWindow(directory: repo, width: width, dark: dark) { _, window in
                        try await inventory(window, count: 3, expected: paths)
                        await group("\(width)pt / \(dark ? "dark" : "light") 分区点击") {
                            try await selections(window)
                        }
                        await group("\(width)pt / \(dark ? "dark" : "light") 独立布局检查") {
                            try await click("row:" + untracked, window: window)
                            try await diffText(window, present: ["UNTRACKED_A", "LONG_LINE_"], absent: ["+WORKTREE_A"])
                            try layout(window, width: width)
                        }
                    }
                }
            }
        }
        await group("真实刷新按钮更新计数、当前 diff 与新文件") { try await refresh(root) }
        await group("非 Git 空态不初始化、不冒充零改动") {
            let directory = root.appendingPathComponent("not-git")
            try await withWindow(directory: directory) { _, window in
                try await wait("非 Git 空态") { try contains("非 Git 工作区", in: window) }
                try require(try contains(WorkspaceChangesError.notRepository.localizedDescription, in: window), "明确非 Git 原因")
                try await click("refresh", window: window)
                try await wait("非 Git 刷新后仍显示空态") { try contains("非 Git 工作区", in: window) }
                try require(!(try contains("最近完整清单：", in: window)) && !(try contains("没有 Git 改动", in: window)), "非 Git 不显示成功清单/零改动")
                try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "非 Git 目录保持为空，不自动 git init")
            }
        }
        await group("干净 Git 与未选目录是不同空态") {
            try await withWindow(directory: root.appendingPathComponent("clean")) { input, window in
                try await wait("干净仓库空态") { try contains("没有 Git 改动", in: window) }
                try await inventory(window, count: 0, expected: [])
                input.directory = nil
                try await wait("未选目录空态") { try contains("未选择工作目录", in: window) }
                try require(!(try contains("最近完整清单：", in: window)), "取消目录后不残留旧清单")
            }
        }
        await group("读取清单期间切目录，旧结果不得回填") { try await switching(root, detail: false) }
        await group("读取 diff 期间切目录，旧内容不得回填") { try await switching(root, detail: true) }
        await group("真实 UI 全程只读 fixture Git index 与内容") {
            try require(try Data(contentsOf: index) == originalIndex, "Git index 字节完全未变")
            try require(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path), "无残留 index.lock")
            try require(try String(contentsOf: repo.appendingPathComponent("a-both.txt"), encoding: .utf8) == "WORKTREE_A\n", "暂存/分区点击没有改写 worktree")
            try require(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("b-deleted.txt").path), "只读 UI 未恢复删除文件")
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        Task { @MainActor in
            await group("独立真实 Git/UI 校验") { try await run() }
            print("LIMIT: 仅独立组件，不操作用户 App；无像素/对比度/VoiceOver/键盘导航验收；几何不证明文字未截断。")
            print("LIMIT: 420/920×720；不覆盖低于生产 minWidth=420、超大文件列表滚动、二进制/rename/submodule。")
            print("LIMIT: 竞态只验证观察到的真实 loading 与取消路径，9s/20ms 采样；不保证捕获不可取消的迟到完成或帧间瞬态；未捕获 loading 必须 SKIP。")
            print("SUMMARY: PASS=\(passes) FAIL=\(failures) SKIP=\(skips)")
            exit(failures > 0 ? 1 : (skips > 0 ? 2 : 0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            // NSApp.windows 仅属于本进程；不查找或操作用户 NewPi 窗口。
            NSApp.windows.forEach { $0.orderOut(nil) }
            print("FAIL: 原生校验超过 180s")
            exit(1)
        }
        NSApp.run()
    }
}