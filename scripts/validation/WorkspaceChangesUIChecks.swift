import AppKit
import Combine
import Foundation
import NewPiCore
import SwiftUI

// 与完整生产文件拼接为一个编译单元。绝不构造替代 Reader / Git / model，
// 不调用 refreshNow / select / selectArea / setDirectory，也不写生产 @State。
// 父级输入 directory 的变化模拟宿主切目录；所有改动面板操作均来自真实控件事件。
@MainActor private enum WorkspaceGeometry {
    // 每个实际 NSView 独立注册，按所属窗口读取，两个 overlay 不共享最后一次坐标。
    static var views: [UUID: WeakView] = [:]
    final class WeakView {
        weak var view: WorkspaceCoordinate.Anchor?
        init(_ view: WorkspaceCoordinate.Anchor) { self.view = view }
    }
    static func view(_ key: String?, space: String, window: NSWindow) -> NSView? {
        views.values.compactMap(\.view).first {
            $0.key == key && $0.space == space && $0.window === window && !$0.isHiddenOrHasHiddenAncestor
        }
    }
    static func frames(space: String, window: NSWindow) -> [String: CGRect] {
        guard let anchor = view(nil, space: space, window: window) else { return [:] }
        var result: [String: CGRect] = [:]
        for view in views.values.compactMap(\.view) where view.window === window && view.space == space {
            if let key = view.key, !view.isHiddenOrHasHiddenAncestor {
                result[key] = anchor.convert(view.bounds, from: view)
            }
        }
        return result
    }
}

private struct WorkspaceCoordinate: NSViewRepresentable {
    let space: String
    var key: String? = nil
    final class Anchor: NSView {
        let id = UUID()
        var space = ""
        var key: String?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.space = space
        anchor.key = key
        WorkspaceGeometry.views[anchor.id] = .init(anchor)
        return anchor
    }
    func updateNSView(_ view: Anchor, context: Context) {
        view.space = space
        view.key = key
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        WorkspaceGeometry.views[view.id] = nil
    }
}

private extension View {
    @MainActor
    func workspaceMeasure(_ key: String, space: String = "workspace-panel") -> some View {
        background(WorkspaceCoordinate(space: space, key: key).allowsHitTesting(false))
    }
}

@MainActor private final class WorkspaceInput: ObservableObject {
    @Published var directory: URL?
    init(_ directory: URL?) { self.directory = directory }
}

private struct WorkspaceRoot: View {
    @ObservedObject var input: WorkspaceInput
    var body: some View {
        VStack {
            NewPiChangesButton(directory: input.directory)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "workspace-button")
        .background(WorkspaceCoordinate(space: "workspace-button"))
    }
}

@MainActor private final class WorkspaceSentinel: NSButton {
    private(set) var clicks = 0
    init(label: String = "测试宿主按钮") {
        super.init(frame: CGRect(x: 20, y: 20, width: 140, height: 28))
        title = label
        target = self
        action = #selector(record)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) {
        print("SENTINEL: down window=\(window?.windowNumber ?? -1) eventWindow=\(event.windowNumber) point=\(event.locationInWindow) frame=\(frame)")
        super.mouseDown(with: event)
    }
    @objc private func record() { clicks += 1; print("SENTINEL: action window=\(window?.windowNumber ?? -1) clicks=\(clicks)") }
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
        fflush(nil)
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
        try await reveal("diff", window: window)
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
        guard let rect = WorkspaceGeometry.frames(space: space, window: window)[key], !rect.isNull, !rect.isInfinite,
              rect.width > 0, rect.height > 0 else {
            throw Failure(description: "缺少当前窗口的有效几何：\(space)/\(key)")
        }
        return rect
    }

    static func screenRect(_ rect: CGRect, space: String, window: NSWindow) throws -> CGRect {
        guard let anchor = WorkspaceGeometry.view(nil, space: space, window: window) else {
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

    // 两个事件按顺序进入同一 App 队列，避免同步 sendEvent 与窗口切换中的派发状态混用。
    static func mouse(_ screenPoint: CGPoint, window: NSWindow, settle: Bool = true) async throws {
        if !window.isKeyWindow || !NSApp.isActive { try await focus(window) }
        try require(try viewport(window).contains(screenPoint), "鼠标命中点在测试窗口视口内")
        guard let content = window.contentView else { throw Failure(description: "窗口内容已卸载") }
        let point = window.convertPoint(fromScreen: screenPoint)
        let parentPoint = content.superview?.convert(point, from: nil) ?? point
        guard content.hitTest(parentPoint) != nil else {
            throw Failure(description: "真实窗口鼠标未命中任何视图")
        }
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw Unavailable(description: "AppKit 无法创建鼠标事件")
            }
            events.append(event)
        }
        NSApp.postEvent(events[0], atStart: false)
        NSApp.postEvent(events[1], atStart: false)
        if settle { try await Task.sleep(for: .milliseconds(120)) }
    }

    static func click(_ key: String, window: NSWindow, space: String = "workspace-panel",
                      settle: Bool = true) async throws {
        // 先聚焦再测量；只向实际卡片的可见控件发送事件。
        if !window.isKeyWindow || !NSApp.isActive { try await focus(window) }
        if key.hasPrefix("row:") || key.hasPrefix("area:") {
            try await reveal(key, window: window)
        }
        try await settled(window, key: key, space: space)
        let measured = try rect(key, space: space, window: window)
        let target = try screenRect(measured, space: space, window: window)
        try require(try viewport(window).insetBy(dx: -1, dy: -1).contains(target), "\(key) 完整位于窗口内")
        if key.hasPrefix("row:") {
            let list = try screenRect(rect("cards-scroll", window: window), space: space, window: window)
            try require(list.insetBy(dx: -1, dy: -1).contains(target), "真实文件卡片标题在 ScrollView 可见区域内")
        } else if key.hasPrefix("area:") {
            let group = try screenRect(rect("picker", window: window), space: space, window: window)
            try require(group.insetBy(dx: -1, dy: -1).contains(target), "真实分区按钮在分区组内")
        }
        print("MOUSE: \(key) rect=\(target)")
        try await mouse(CGPoint(x: target.midX, y: target.midY), window: window, settle: settle)
        if settle && (key.hasPrefix("row:") || key.hasPrefix("area:")) {
            try await settled(window, key: key)
        }
    }

    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    static func cardsScroll(_ window: NSWindow) throws -> NSScrollView {
        let expected = try screenRect(rect("cards-scroll", window: window), space: "workspace-panel", window: window)
        guard let content = window.contentView,
              let scroll = views(content).compactMap({ $0 as? NSScrollView }).first(where: {
                  let bounds = window.convertToScreen($0.convert($0.bounds, to: nil))
                  return abs(bounds.minX - expected.minX) < 2 && abs(bounds.minY - expected.minY) < 2
                      && abs(bounds.width - expected.width) < 2 && abs(bounds.height - expected.height) < 2
              }) else { throw Failure(description: "未找到与实际卡片视口匹配的原生 ScrollView") }
        return scroll
    }

    static func wheel(_ delta: Int32, scroll: NSScrollView) async throws {
        // CGEvent 只用于构造 NSEvent；不 post 全局事件、不改 clipView offset/生产状态。
        guard let window = scroll.window, let screen = NSScreen.screens.first else {
            throw Failure(description: "滚轮目标没有实际窗口/屏幕")
        }
        let bounds = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: delta, wheel2: 0, wheel3: 0) else {
            throw Unavailable(description: "无法构造本地滚轮事件")
        }
        // 缺省 CGEvent 使用系统鼠标位置；SwiftUI 嵌套 ScrollView 会据此路由到错误视口。
        // 外层 12pt padding 内取点，不能落在展开卡片的内层 diff ScrollView。
        cg.location = CGPoint(x: bounds.minX + 3, y: screen.frame.maxY - bounds.midY)
        guard let event = NSEvent(cgEvent: cg) else {
            throw Unavailable(description: "无法构造本地滚轮事件")
        }
        scroll.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(100))
    }

    static func visible(_ key: String, window: NSWindow) throws -> Bool {
        guard let target = WorkspaceGeometry.frames(space: "workspace-panel", window: window)[key] else { return false }
        let clip = try cardsScroll(window).contentView
        let clipBounds = window.convertToScreen(clip.convert(clip.bounds, to: nil))
        let screen = try screenRect(target, space: "workspace-panel", window: window)
        let viewportBounds = try viewport(window)
        return target.width > 0 && target.height > 0
            && clipBounds.insetBy(dx: -1, dy: -1).contains(screen)
            && viewportBounds.insetBy(dx: -1, dy: -1).contains(screen)
    }

    static func reveal(_ key: String, window: NSWindow) async throws {
        try await settled(window, key: "cards-scroll")
        if try visible(key, window: window) { return }
        // 未挂载时从顶端扫描；已有真实坐标则只滚动必要距离，不每次重走整个列表。
        if WorkspaceGeometry.frames(space: "workspace-panel", window: window)[key] == nil {
            let scroll = try cardsScroll(window)
            try await wheel(Int32(ceil(scroll.contentView.bounds.minY)), scroll: scroll)
        }
        for _ in 0..<100 {
            // 滚轮可触发平滑滚动/弹性回弹；瞬时进入不代表稳定后仍可点击。
            // 先等真实布局稳定，再判完整可见；不改 clipView、不放宽裁切边界。
            try await settled(window, key: "cards-scroll")
            if try visible(key, window: window) {
                try await settled(window, key: key)
                if try visible(key, window: window) {
                    try require(try visible(key, window: window), "\(key) 滚动后完整可见、未裁切")
                    return
                }
            }
            // loading/ready 分支切换会重建 ScrollView；不能保存一次查找得到的旧实例。
            let scroll = try cardsScroll(window)
            var delta = -scroll.contentView.bounds.height / 2
            if let frame = WorkspaceGeometry.frames(space: "workspace-panel", window: window)[key] {
                let clip = scroll.contentView
                let clipScreen = window.convertToScreen(clip.convert(clip.bounds, to: nil))
                let screen = try screenRect(frame, space: "workspace-panel", window: window)
                if screen.height > clipScreen.height + 1 || screen.width > clipScreen.width + 1 {
                    throw Failure(description: "\(key) 大于真实卡片可视区，无法完整展示")
                }
                if screen.maxY > clipScreen.maxY { delta = ceil(screen.maxY - clipScreen.maxY) + 1 }
                else if screen.minY < clipScreen.minY { delta = floor(screen.minY - clipScreen.minY) - 1 }
            }
            try await wheel(Int32(delta), scroll: scroll)
        }
        let scroll = try cardsScroll(window)
        throw Failure(description: "真实滚轮无法使 \(key) 完整进入卡片视口；clip=\(scroll.contentView.bounds) document=\(String(describing: scroll.documentView?.frame)) frames=\(WorkspaceGeometry.frames(space: "workspace-panel", window: window))")
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
            let frames = WorkspaceGeometry.frames(space: space, window: window)
            let pending = values.contains { value in
                ["正在读取 Git 改动", "正在刷新；", "正在读取文件…"].contains(where: value.contains)
            }
            let ready = WorkspaceGeometry.view(nil, space: space, window: window) != nil
                && frames[key] != nil && !pending
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
        let input = WorkspaceInput(directory)
        let host = NSHostingView(rootView: WorkspaceRoot(input: input))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "NewPi · 临时 Git 改动 UI 校验"
        let content = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 720))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        window.contentView = content
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(CGSize(width: width, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer {
            // 先触发生产 willClose 清理 overlay/monitor，再卸载宿主。
            window.close()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await focus(window)
        try await wait("NSHostingView 尺寸与外观同步") {
            abs(host.bounds.width - width) < 1 && host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                == (dark ? .darkAqua : .aqua)
        }
        try await wait("公开 AX 未暴露真实组件文本", seconds: 3, unavailable: true) {
            try contains("改动", in: window)
        }
        if button {
            try await body(input, window)
        } else {
            let panel = try await open(window)
            try await body(input, panel)
        }
    }

    static func open(_ parent: NSWindow) async throws -> NewPiUsagePanel {
        try require(parent.attachedSheet == nil && overlays(parent).isEmpty, "打开前无 sheet/overlay")
        try await click("open", window: parent, space: "workspace-button")
        try await wait("真实按钮打开所属窗口的 hosted overlay") { overlays(parent).count == 1 }
        guard let panel = overlays(parent).first, let backdrop = panel.contentView as? NewPiUsageHostedBackdrop else {
            throw Failure(description: "缺少完整生产 hosted backdrop")
        }
        try await settled(panel, key: "panel")
        try require(parent.attachedSheet == nil && panel.parent === parent && panel.isVisible,
                    "实际改动入口为父窗口内子 panel，不是 sheet")
        try require(abs(backdrop.dialog.frame.midX - backdrop.bounds.midX) < 1
                    && abs(backdrop.dialog.frame.midY - backdrop.bounds.midY) < 1, "真实 overlay 卡片居中")
        try require(parent.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }
                    .contains { $0.blendingMode == .withinWindow } == true, "实际父窗口内 blur")
        return panel
    }

    static func overlays(_ parent: NSWindow) -> [NewPiUsagePanel] {
        parent.childWindows?.compactMap { $0 as? NewPiUsagePanel } ?? []
    }

    static func clickView(_ view: NSView, window: NSWindow) async throws {
        if !window.isKeyWindow || !NSApp.isActive { try await focus(window) }
        window.contentView?.layoutSubtreeIfNeeded()
        try require(view.window === window && !view.isHiddenOrHasHiddenAncestor, "原生控件属于目标测试窗口")
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        let visible = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        try require(try viewport(window).contains(bounds) && visible.insetBy(dx: -1, dy: -1).contains(bounds),
                    "原生控件完整可见、未被祖先裁切")
        let point = window.convertPoint(fromScreen: CGPoint(x: bounds.midX, y: bounds.midY))
        let hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(point, from: nil) ?? point) }
        print("NATIVE MOUSE: window=\(window.windowNumber) rect=\(bounds) hit=\(String(describing: hit)) target=\(view)")
        try await mouse(CGPoint(x: bounds.midX, y: bounds.midY), window: window)
    }

    static func key(_ code: UInt16, text: String, window: NSWindow) async throws {
        try await focus(window)
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw Unavailable(description: "无法构造本地键盘事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    static func close(_ panel: NSWindow, escape: Bool = false) async throws {
        guard let parent = panel.parent, let backdrop = panel.contentView as? NewPiUsageHostedBackdrop else {
            throw Failure(description: "关闭目标不是实际 hosted overlay")
        }
        if escape { try await key(53, text: "\u{1b}", window: panel) }
        else { try await clickView(backdrop.closeButton, window: panel) }
        try await wait("\(escape ? "Escape" : "真实关闭按钮") 移除子 panel") {
            overlays(parent).isEmpty && !panel.isVisible && panel.parent == nil
        }
        try require(parent.isVisible && parent.attachedSheet == nil, "关闭只移除 overlay，保留父窗口")
        try require(parent.contentView?.subviews.contains { $0 is NSVisualEffectView } == false,
                    "关闭清除本窗口 blur")
    }

    static func inventory(_ window: NSWindow, count: Int, expected: Set<String>) async throws {
        do {
            try await wait("最近完整清单显示 \(count) 个真实文件") {
                let values = try texts(window)
                return values.contains { $0.contains("最近完整清单：") && $0.contains("· \(count) 个文件；") }
            }
        } catch {
            print("DIAGNOSTIC: inventory AX=\(try texts(window).map { String($0.prefix(240)) })")
            print("DIAGNOSTIC: inventory geometry=\(WorkspaceGeometry.frames(space: "workspace-panel", window: window))")
            throw error
        }
        var values = try texts(window)
        var witnessed = Set<String>()
        // 卡片懒加载：逐个滚入可见区域读真实 AX，而非要求离屏节点一直挂载。
        for path in expected.sorted() {
            try await reveal("row:" + path, window: window)
            let current = try texts(window)
            try require(current.contains(path), "真实可见卡片包含路径：\(path)")
            witnessed.insert(path)
            values += current
        }
        try require(witnessed == expected, "实际文件卡片包含全部 \(expected.count) 个预期路径")
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

    static func layout(_ window: NSWindow, width: CGFloat, path: String, longLine: Bool) async throws {
        try await reveal("diff", window: window)
        guard let parent = window.parent, let backdrop = window.contentView as? NewPiUsageHostedBackdrop else {
            throw Failure(description: "布局检查必须运行于真实 hosted overlay")
        }
        let view = try viewport(window)
        let panel = try rect("panel", window: window)
        let parentView = try viewport(parent)
        try require(abs(parentView.width - width) < 1 && abs(view.width - width) < 1
                    && abs(parentView.height - 720) < 1, "真实父窗口/overlay = \(width)×720，未扩大窗口掩盖越界")
        try require(abs(backdrop.dialog.frame.width - min(920, width - 40)) < 1
                    && abs(panel.width - backdrop.host.bounds.width) < 1
                    && abs(panel.height - backdrop.host.bounds.height) < 1,
                    "实际内容服从 production dialog/host 尺寸，不冒充父窗口宽度")
        try require(backdrop.bounds.contains(backdrop.dialog.frame)
                    && backdrop.dialog.bounds.contains(backdrop.host.frame)
                    && backdrop.dialog.bounds.contains(backdrop.closeButton.frame)
                    && backdrop.closeButton.frame.maxY <= backdrop.host.frame.minY,
                    "居中卡片、host、关闭按钮未裁切且关闭按钮不遮挡正文")
        let headerFields = backdrop.dialog.subviews.compactMap { $0 as? NSTextField }
        try require(headerFields.count == 1 && headerFields.allSatisfy {
            backdrop.dialog.bounds.contains($0.frame) && $0.frame.maxX <= backdrop.closeButton.frame.minX
                && $0.frame.maxY <= backdrop.host.frame.minY
        }, "原生弹窗标题与关闭按钮/正文互不重叠")
        let hostScreen = window.convertToScreen(backdrop.host.convert(backdrop.host.bounds, to: nil))
        for key in ["panel", "title", "refresh", "notice", "scope", "count", "cards-scroll"] {
            let bounds = try screenRect(rect(key, window: window), space: "workspace-panel", window: window)
            try require(view.insetBy(dx: -1, dy: -1).contains(bounds)
                        && hostScreen.insetBy(dx: -1, dy: -1).contains(bounds), "\(width)pt: \(key) 不越出实际 host")
        }
        let title = try rect("title", window: window), refresh = try rect("refresh", window: window)
        try require(title.maxX <= refresh.minX + 1, "正文标题与刷新互不重叠")
        let notice = try rect("notice", window: window), scope = try rect("scope", window: window)
        let count = try rect("count", window: window), list = try rect("cards-scroll", window: window)
        try require(max(title.maxY, refresh.maxY) <= notice.minY + 1 && notice.maxY <= scope.minY + 1
                    && scope.maxY <= count.minY + 1 && count.maxY <= list.minY + 1,
                    "标题/只读提示/范围/计数/卡片视口依次排列、不遮挡")
        let card = try rect("card:" + path, window: window), row = try rect("row:" + path, window: window)
        let detail = try rect("detail", window: window)
        try require(card.insetBy(dx: -1, dy: -1).contains(row) && card.insetBy(dx: -1, dy: -1).contains(detail)
                    && row.maxY <= detail.minY + 1 && abs(detail.height - 320) < 1,
                    "实际展开卡片包含标题与 320pt 详情，不重叠")
        let cards = WorkspaceGeometry.frames(space: "workspace-panel", window: window)
            .filter { $0.key.hasPrefix("card:") }.values.sorted { $0.minY < $1.minY }
        try require(zip(cards, cards.dropFirst()).allSatisfy { $0.0.maxY <= $0.1.minY + 1 }, "已挂载文件卡片纵向排列、不互相覆盖")
        let diff = try rect("diff", window: window), scroll = try rect("diff-scroll", window: window)
        try require(detail.insetBy(dx: -1, dy: -1).contains(diff) && diff.insetBy(dx: -1, dy: -1).contains(scroll)
                    && scroll.width > 100 && scroll.height > 40, "diff 限制在真实双向滚动视口内")
        if longLine {
            try require(try rect("diff-content", window: window).width > scroll.width,
                        "1600 字符原始长行确实超出内层视口，但没有撑大卡片/host")
        }
        let selected = try rect("selected", window: window), picker = try rect("picker", window: window)
        try require(detail.insetBy(dx: -1, dy: -1).contains(selected)
                && detail.insetBy(dx: -1, dy: -1).contains(picker)
                && selected.maxY <= picker.minY + 1 && picker.maxY <= diff.minY + 1,
                "文件标题/分区/diff 保持在 detail 内且不互相遮挡")
        let areas: [WorkspaceDiffArea] = path == untracked ? [.untracked] : [.staged, .unstaged]
        for area in areas {
            try require(try picker.insetBy(dx: -1, dy: -1).contains(rect("area:" + area.rawValue, window: window)),
                        "\(area.rawValue) 按钮完全位于分区组")
        }
        if areas.count == 2 {
            let staged = try rect("area:staged", window: window), unstaged = try rect("area:unstaged", window: window)
            try require(staged.maxX <= unstaged.minX + 1, "暂存与未暂存按钮不重叠")
        }
        // 整张卡片允许比外层视口高；每个可交互控件及内层 diff 视口必须可完整滚入。
        for key in ["row:" + path, "selected", "picker", "diff-scroll"] + areas.map({ "area:" + $0.rawValue }) {
            try await reveal(key, window: window)
            try require(try visible(key, window: window), "\(width)pt: \(key) 实际可见、无裁切")
        }
        try await reveal("diff", window: window)
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
            guard let backdrop = window.contentView as? NewPiUsageHostedBackdrop else {
                throw Failure(description: "切换测试缺少生产 hosted backdrop")
            }
            let host = backdrop.host
            let parentHost = window.parent?.contentView
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
            try require((window.contentView as? NewPiUsageHostedBackdrop)?.host === host
                        && window.parent?.contentView === parentHost, "在途读取时切目录复用同一父宿主/overlay NSHostingView")
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

    static func errors(_ root: URL) async throws {
        let repo = root.appendingPathComponent("repo-a")
        let file = repo.appendingPathComponent(untracked)
        let original = try Data(contentsOf: file)
        defer {
            do { try original.write(to: file) }
            catch { failures += 1; print("FAIL: 错误 fixture 恢复失败：\(error)") }
        }
        try await withWindow(directory: repo) { input, window in
            try await inventory(window, count: 3, expected: paths)
            try FileManager.default.removeItem(at: file)
            try await click("row:" + untracked, window: window)
            try await reveal("picker", window: window)
            try await wait("真实未跟踪文件读取失败") { try contains("文件读取未完成", in: window) }
            try require(try contains(WorkspaceChangesError.unreadableFile.localizedDescription, in: window), "错误展示真实 Reader 原因")
            let values = try texts(window)
            try require(!values.contains { value in ["UNTRACKED_A", "+WORKTREE_A", "+STAGED_A"].contains(where: value.contains) },
                        "detail 失败不残留旧 diff/预览")
            try original.write(to: file)
            try await click("row:" + untracked, window: window)
            try await diffText(window, present: ["UNTRACKED_A", "LONG_LINE_"], absent: ["文件读取未完成"])
            let missing = root.appendingPathComponent("missing-directory")
            try require(!FileManager.default.fileExists(atPath: missing.path), "错误目录确实不存在")
            input.directory = missing
            try await wait("实际清单读取失败") {
                try contains("读取未完成", in: window) && contains(WorkspaceChangesError.invalidDirectory.localizedDescription, in: window)
            }
            try require(!(try contains("最近完整清单：", in: window)) && !(try contains("没有 Git 改动", in: window)),
                        "清单失败不冒充成功/零改动")
            try require(!(try texts(window)).contains { value in oldTokens.contains(where: value.contains) }, "清单错误清除旧文件/内容")
            try await click("refresh", window: window)
            try await settled(window, key: "panel")
            try require(try contains(WorkspaceChangesError.invalidDirectory.localizedDescription, in: window), "失败后仍可真实刷新并展示错误")
            input.directory = root.appendingPathComponent("repo-b")
            try await inventory(window, count: 1, expected: ["b-only.txt"])
            try await diffText(window, present: ["+SWITCH_B"], absent: oldTokens + ["读取未完成"])
        }
    }

    static func isolation(_ root: URL) async throws {
        try await withWindow(directory: root.appendingPathComponent("repo-a"), button: true) { _, a in
            let sentinelA = WorkspaceSentinel()
            a.contentView?.addSubview(sentinelA)
            try await clickView(sentinelA, window: a)
            try require(sentinelA.clicks == 1, "A 底层控件基线可点击")
            let editor = NSTextView(frame: CGRect(x: 180, y: 20, width: 250, height: 60))
            editor.string = "只保留测试草稿"
            a.contentView?.addSubview(editor)
            a.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            let panelA = try await open(a)
            try await inventory(panelA, count: 3, expected: paths)
            try require(a.firstResponder === editor && editor.selectedRange().location == 2, "打开实际改动不改变父输入选区")
            try await clickView(sentinelA, window: a)
            try require(sentinelA.clicks == 1 && overlays(a).first === panelA, "overlay 阻挡发往所属父窗口的底层点击")
            try await withWindow(directory: root.appendingPathComponent("repo-b"), button: true) { _, b in
                let sentinelB = WorkspaceSentinel()
                b.contentView?.addSubview(sentinelB)
                try await clickView(sentinelB, window: b)
                try require(sentinelB.clicks == 1, "A 的本地 monitor 不吞 B 的普通控件事件")
                let panelB = try await open(b)
                try await inventory(panelB, count: 1, expected: ["b-only.txt"])
                try await diffText(panelB, present: ["+SWITCH_B"], absent: oldTokens)
                try await click("row:a-both.txt", window: panelA)
                try await chooseArea(.staged, window: panelA)
                try await diffText(panelA, present: ["-BASE_A", "+STAGED_A"], absent: ["SWITCH_B", "WORKTREE_A"])
                try await diffText(panelB, present: ["+SWITCH_B"], absent: oldTokens)
                try require(overlays(a).count == 1 && overlays(b).count == 1 && panelA !== panelB,
                            "两窗口独立 overlay/卡片选择/几何，不共享面板")
                try await close(panelA)
                try require(a.firstResponder === editor && editor.string == "只保留测试草稿"
                            && editor.selectedRange().location == 2, "真实关闭恢复原输入焦点、草稿与选区")
                try require(overlays(b).first === panelB && panelB.isVisible, "关闭 A 不关闭 B")
                try await click("refresh", window: panelB)
                try await diffText(panelB, present: ["+SWITCH_B"], absent: oldTokens)
                let reopened = try await open(a)
                try await inventory(reopened, count: 3, expected: paths)
                try await close(panelB, escape: true)
                try require(overlays(a).first === reopened && reopened.isVisible, "B 的 Escape 不关闭 A")
                try await close(reopened, escape: true)
                try await clickView(sentinelA, window: a)
                try await clickView(sentinelB, window: b)
                try require(sentinelA.clicks == 2 && sentinelB.clicks == 2, "关闭后两个窗口的 monitor 均已移除，底层事件恢复")
                let last = try await open(a)
                a.close()
                try await wait("父窗口关闭清理实际子 panel") { !last.isVisible && last.parent == nil }
                try require(b.isVisible, "关闭父窗口 A 不影响 B")
            }
        }
    }

    static func fixtureContents(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in ["repo-a", "repo-b", "clean", "not-git"] {
            let directory = root.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw Failure(description: "无法枚举隔离 fixture：\(name)")
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure(description: "fixture 出现意外 symlink") }
                if values.isRegularFile == true {
                    result[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
                }
            }
        }
        return result
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
        let originalContents = try fixtureContents(root)
        await group("真实 ChangesButton 打开/关闭/Escape；子目录仍统计整个根目录") {
            try await withWindow(directory: repo.appendingPathComponent("nested"), button: true) { _, window in
                try await wait("按钮可访问名称显示真实去重计数 3") { try contains("3 个文件（最近一次完整读取）", in: window) }
                let panel = try await open(window)
                try await inventory(panel, count: 3, expected: paths)
                try require(try contains(repo.path, in: panel), "从 nested 进入展示真实仓库根目录")
                await group("overlay 内真实文件/分区选择") { try await selections(panel) }
                try await close(panel)
                try require(try contains("3 个文件（最近一次完整读取）", in: window), "关闭后按钮保留真实文件计数")
                let reopened = try await open(window)
                try await inventory(reopened, count: 3, expected: paths)
                try await close(reopened, escape: true)
                try require(try contains("3 个文件（最近一次完整读取）", in: window), "Escape 后保留真实文件计数")
            }
        }
        for width in [CGFloat(420), CGFloat(920)] {
            for dark in [false, true] {
                await group("真实 overlay 父窗口 \(width)pt / \(dark ? "dark" : "light") 选择与边界") {
                    try await withWindow(directory: repo, width: width, dark: dark) { _, window in
                        try await inventory(window, count: 3, expected: paths)
                        await group("\(width)pt / \(dark ? "dark" : "light") 分区点击") {
                            try await selections(window)
                        }
                        await group("\(width)pt / \(dark ? "dark" : "light") 独立布局检查") {
                            try await click("row:" + untracked, window: window)
                            try await diffText(window, present: ["UNTRACKED_A", "LONG_LINE_"], absent: ["+WORKTREE_A"])
                            try await layout(window, width: width, path: untracked, longLine: true)
                            try await click("row:a-both.txt", window: window)
                            try await chooseArea(.unstaged, window: window)
                            try await diffText(window, present: ["+WORKTREE_A"], absent: ["UNTRACKED_A"])
                            try await layout(window, width: width, path: "a-both.txt", longLine: false)
                        }
                    }
                }
            }
        }
        await group("真实刷新按钮更新计数、当前 diff 与新文件") { try await refresh(root) }
        await group("真实文件/清单错误与恢复") { try await errors(root) }
        await group("双窗口 overlay 事件/选择/关闭隔离与焦点恢复") { try await isolation(root) }
        await group("就绪目录 A→B→A，不依赖能否捕获在途 loading") {
            try await withWindow(directory: repo) { input, window in
                try await inventory(window, count: 3, expected: paths)
                input.directory = root.appendingPathComponent("repo-b")
                try await inventory(window, count: 1, expected: ["b-only.txt"])
                try await diffText(window, present: ["+SWITCH_B"], absent: oldTokens)
                input.directory = repo
                try await inventory(window, count: 3, expected: paths)
                try await diffText(window, present: ["+WORKTREE_A"], absent: ["SWITCH_B", "b-only.txt"])
            }
        }
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
            try require(try fixtureContents(root) == originalContents, "全部 fixture 的 Git 元数据/已跟踪/未跟踪/ignored 内容逐字节未变（测试主动修改已恢复）")
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
            print("LIMIT: 完整生产 Status（除 Preview）与 Changes，独立窗口；不操作用户 App，无全局 AX/录屏；不覆盖像素/对比度/VoiceOver/完整键盘导航，几何不证明字形未截断。")
            print("LIMIT: 父窗口 420/920×720，实际 hosted overlay 内的卡片滚动与控件边界；不覆盖更小窗口、超大文件清单、二进制/rename/submodule。")
            print("LIMIT: 竞态只验证观察到的真实 loading 与取消路径，9s/20ms 采样；不保证捕获不可取消的迟到完成或帧间瞬态；未捕获 loading 必须 SKIP。")
            print("SUMMARY: PASS=\(passes) FAIL=\(failures) SKIP=\(skips)")
            exit(failures > 0 ? 1 : (skips > 0 ? 2 : 0))
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 600) {
            // tracking loop 或主线程同步调用阻塞也必须失败退出；进程退出只清理自己的窗口。
            FileHandle.standardError.write(Data("FAIL: 原生校验超过 600s（包含卡片滚动、双窗口与竞态组）\n".utf8))
            exit(1)
        }
        NSApp.run()
    }
}