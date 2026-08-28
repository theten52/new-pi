import SwiftUI
import os

/// 聊天滚动定位协调器（每个会话面板一个实例）。
///
/// 设计原则（docs/dev-notes/chat-scroll-layout.md §3.3 教训的修订版）：
/// 每个滚动职责只有一个写者——流式钉底走 ScrollViewProxy.scrollTo（已验证可靠）；
/// 精确定位（rail 跳转）走本组件，最终经由面板注入的
/// `ScrollPosition.scrollTo(point:)` 执行（macOS 15 官方精确滚动 API）。
///
/// 为什么不用 NSScrollView.setContentOffset / 清空 scrollPosition 绑定：
/// 实测（2026-08-28 日志）绑定置 nil 本身会触发 SwiftUI 重新滚动，与手动
/// setContentOffset 互相覆盖（offset 4ms 内被改写 +1369）；只有 ScrollPosition
/// 的 scrollTo(point:) 是平台认可的单一权威写法。
///
/// 数据通路：
/// 1. `scrollPosition.scrollTo(id:)` 实例化目标行（唯一能实例化 LazyVStack 未加载行的机制）；
/// 2. 目标行上报其在**内容坐标系**的 minY（coordinateSpace 挂在内容 VStack 上，
///    不随滚动变化 = 行的绝对内容 y = 精确贴顶所需滚动点）；
/// 3. `onApplyExact(minY)` 一次滚到位；此后仅当上方测高变化使内容 y 漂移时
///    onChange 再次上报并重滚，静止即自然停（deadline 兜底）。
@MainActor
final class ChatScrollCoordinator: ObservableObject {
    /// 目标行最近上报的内容坐标 y（key: 消息 id；仅目标行进入，防无界增长）。
    private var rowContentTops: [UUID: CGFloat] = [:]
    /// 当前定位目标（nil = 无进行中的定位）。
    /// @Published 供 SwiftUI 观察：isTarget 参与行 background 的条件渲染（NewPiSessionPanel），
    /// targetID 变化必须触发该视图重算，否则连续两次点同一 rail marker、几何未变时精确贴顶
    /// 静默失效（Coordinator 内部状态变化不触发 SwiftUI 重绘）。
    @Published var targetID: UUID?
    /// 定位窗口 deadline；超过即放弃后续校正。首帧上报时重置——目标行实例化
    /// 可能比点击晚数秒（LazyVStack 远距离行），固定从点击起算会错过窗口。
    private var deadline = Date.distantPast
    /// 上次已应用的滚动点（防静止内容重复上报导致反复滚动）。
    private var lastAppliedY: CGFloat?
    /// refine 失败原因只记一次日志（防刷屏），进入新窗口时复位。
    private var loggedSkipReason = false

    private let log = os.Logger(subsystem: "com.newpi.app", category: "railjump")

    /// 面板注入的精确滚动执行者：`jumpPosition.scrollTo(point:)`。
    var onApplyExact: ((CGFloat) -> Void)?

    // MARK: - rail 跳转

    /// 发起定位：记录目标并开窗。行实例化由面板先行调用
    /// `jumpPosition.scrollTo(id:)` 完成（返回值仅为语义完整性，可忽略）。
    func beginJump(to messageID: UUID) {
        targetID = messageID
        deadline = Date().addingTimeInterval(1.5)
        lastAppliedY = nil
        loggedSkipReason = false
        // 距上次该行上报已可能很久（内容变了），丢弃旧值等新几何。
        rowContentTops[messageID] = nil
        #if DEBUG
        log.debug("rail-jump → target=\(messageID.uuidString, privacy: .public)")
        #endif
    }

    // MARK: - 行几何上报

    /// 目标行上报内容坐标 y（内容 VStack 坐标系的 minY）。
    /// 首帧上报时重置 deadline（实例化可能远晚于点击）。
    func reportRowTop(_ top: CGFloat, for id: UUID) {
        guard id == targetID else { return }
        let isFirstReport = rowContentTops[id] == nil
        rowContentTops[id] = top
        if isFirstReport {
            deadline = Date().addingTimeInterval(1.5)
            #if DEBUG
            log.debug("rail-jump first-report top=\(top, privacy: .public)")
            #endif
        }
        refine()
    }

    /// 用最新几何精确贴顶。内容坐标系 minY 即绝对内容 y，直接滚到该点。
    /// 静止内容重复上报值不变（<0.5pt）即跳过；上方测高使 y 漂移时会再上报再校正。
    private func refine() {
        if let targetID {
            if Date() >= deadline { logOnce("deadline passed") }
            if rowContentTops[targetID] == nil { logOnce("no geometry yet") }
        }
        guard let targetID, Date() < deadline, let contentY = rowContentTops[targetID] else { return }
        loggedSkipReason = false
        if let last = lastAppliedY, abs(contentY - last) < 0.5 { return }
        lastAppliedY = contentY
        #if DEBUG
        log.debug("rail-jump apply point y=\(contentY, privacy: .public)")
        #endif
        onApplyExact?(max(0, contentY))
    }

    /// 失败原因只记一次（同一窗口内）。
    private func logOnce(_ reason: String) {
        guard !loggedSkipReason else { return }
        loggedSkipReason = true
        #if DEBUG
        log.debug("rail-jump refine skip: \(reason, privacy: .public)")
        #endif
    }

    // MARK: - 查询

    /// 该行是否是当前定位目标（供行 background 决定是否挂 GeometryReader）。
    func isTarget(_ id: UUID) -> Bool { id == targetID }
}
