import AppKit
import Foundation
import NewPiCore
import WebKit

/// 冷恢复时的"离线预测高"：把 cache-miss 的 markdown 行用**离屏探针 WKWebView** 先测出真实高度，
/// 写入 MarkdownRenderingCache。这样用户滚动到某行时该行"实例化即命中缓存"→ 首帧即真实高度 →
/// LazyVStack 对未实例化行的外推保持稳定 → 滚动条不再明显变短（响应"切换后滚动条变短"问题）。
///
/// 承载体：探针 WKWebView 挂到一个**屏幕内 alpha=0 透明 NSWindow**（`ignoresMouseEvents`、`orderFrontRegardless`）。
/// 纯离屏（无 window）在 WKWebView 下 rAF/布局会被冻结（spike 实测证伪）；且 WebKit 对「orderOut / 视口外 /
/// 屏幕外 origin」的窗口同样不渲染（实测 measured=0）。屏幕内 alpha=0 窗口对用户不可见不可点，但 WebKit 仍按
///「可见窗口」布局渲染（与现有"保活面板 opacity-0 面板内 WebView 仍持续渲染+上报高度"的行为同构）。
///
/// 关键约束（GLM review 落地裁决）：
/// - 探针 `setHeight` 一律用**起始 activeWidth 快照**作为宽度，禁透传探针自身上报的 clientWidth，
///   否则 1px 离屏出入（或为 0）会写错桶、并污染 `currentWidth` 影响所有真实行的桶选择。
/// - 循环内每行重读 `activeWidth`，与快照不一致（窗口 resize / 尾部真实行把桶翻掉）即中止本轮，
///   避免整批写进将失效的桶。
/// - 串行（并发=1）、每行新建销毁、单行 3s 看门狗、上限 ~40 条、`preheat` 前 `cancel` 上一次。
/// - 换项目 `cache.clear()` 处必须同步 `MarkdownHeightPreheater.shared.cancel()`（防跨项目写残留）。
@MainActor
final class MarkdownHeightPreheater {
    static let shared = MarkdownHeightPreheater()

    private var task: Task<Void, Never>?
    /// 预加热代号：每次 preheat 递增，旧 task 收尾时校验，避免误清新一代 preheat 的引用（K3 review major）。
    private var generation = 0
    /// 全量预热：几十条/会话的规模下全覆盖（曾是尾部 8 条/40 探针上限——
    /// 长会话中段行无缓存，是「滚动条越滚越短」的直接根因）。看门狗仍保护单行。
    private let maxProbes = 120
    private let rowWatchdogSeconds: TimeInterval = 3

    private init() {}

    /// 冷恢复入口：对 cache-miss 的 markdown 行（尾部优先）串行离屏测高并写缓存。
    func preheat(items: [NewPiTranscriptItem]) {
        cancel()
        generation += 1
        let gen = generation
        guard let rendererScriptURL = NewPiMarkdownWebDocument.rendererScriptURL() else { return }
        let widthSnapshot = MarkdownRenderingCache.shared.activeWidth
        // 无宽度基线（全新安装未测得宽度）时没有可对齐的桶，跳过（退化为现状，不更糟）。
        guard widthSnapshot > 0 else { return }

        // 全量扫 cache-miss 行（尾部优先——用户总是从底部开始浏览）。
        // 几十条/会话的规模 + maxProbes 上限兜底；逐行 SHA256 成本可忽略。
        let misses = items.reversed().filter { item in
            item.isAssistantMarkdown
                && MarkdownRenderingCache.shared.height(for: item.body) == nil
        }
        guard !misses.isEmpty else { return }

        task = Task { [weak self] in
            guard let self else { return }
            let rendererScriptURL = rendererScriptURL
            var measured = 0
            var skipped = 0
            let timeStart = Date()
            NewPiLogger.info(category: "app", message: "Markdown height preheat start", details: "miss=\(misses.count) width=\(widthSnapshot)")
            for item in misses.prefix(maxProbes) {
                if Task.isCancelled { break }
                // 宽度漂移（resize / 尾部行翻桶）即中止，避免写进将失效的桶。
                guard MarkdownRenderingCache.shared.activeWidth == widthSnapshot else {
                    NewPiLogger.info(category: "app", message: "Markdown height preheat aborted (width drift)", details: "miss=\(misses.count)")
                    break
                }
                // 每行处理前重查 miss：已被真实行实测写进缓存，则跳过，省得白测。
                guard MarkdownRenderingCache.shared.height(for: item.body) == nil else { skipped += 1; continue }
                let ok = await self.probe(item.body, width: widthSnapshot, rendererScriptURL: rendererScriptURL)
                if ok { measured += 1 } else { skipped += 1 }
            }
            let elapsed = Date().timeIntervalSince(timeStart)
            NewPiLogger.info(
                category: "app",
                message: "Markdown height preheat done",
                details: "measured=\(measured) skipped=\(skipped) elapsedMs=\(Int(elapsed * 1000))"
            )
            // 仅在仍是本代 task 时清引用：否则会把新一代 preheat 刚存入的 task 清掉（cancel 失效、并发 1→2）。
            if self.generation == gen {
                self.task = nil
            }
        }
    }

    /// 取消当前预加热。目前只在换项目（openProject 的 cache.clear() 旁）调用；
    /// 同项目内切换会话不取消——缓存按内容哈希寻址，继续测得的高度跨会话仍有效（K3 review minor）。
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 用离屏探针测单行高度并写缓存。返回是否成功（收到有效高度 & 未超时）。
    private func probe(_ markdown: String, width: CGFloat, rendererScriptURL: URL) async -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 5),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 关键（实测修复）：WKWebView 对「视口外 / orderOut / 屏幕外 origin」的窗口**不渲染、rAF 冻结**，
        // 探针永远收不到 height 上报（日志 measured=0）。必须让窗口「在屏幕内 + 真实显示」WebKit 才布局渲染
        //（与 app 内保活面板 opacity-0 仍渲染同构）。alpha=0 完全透明、ignoresMouseEvents 不拦截，用户不可见不可点。
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: width, height: 5)
        window.setFrameOrigin(NSPoint(x: visible.origin.x + 20, y: visible.origin.y + 20))
        window.orderFrontRegardless()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = ProbeHeightHandler(markdown: markdown, width: width, rendererScriptURL: rendererScriptURL)
        configuration.userContentController.add(handler, name: "height")
        // 探针同时捕获渲染产物（html 与高度一起写缓存）——首次揭示即重放。
        configuration.userContentController.add(handler, name: "renderedSnapshot")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 5), configuration: configuration)
        window.contentView = webView

        do {
            let html = try NewPiMarkdownWebDocument.documentHTML(
                markdown: markdown,
                rendererScriptURL: rendererScriptURL,
                streaming: false
            )
            webView.loadHTMLString(html, baseURL: rendererScriptURL.deletingLastPathComponent())
        } catch {
            window.orderOut(nil)
            return false
        }

        // 等首个有效 height（看门狗兜底；resume 幂等用 class 引用，避免 Swift 6 可变捕获告警——K3 review minor）。
        final class ResumeBox { var done = false }
        let box = ResumeBox()
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            func resumeOnce(_ value: Bool) {
                guard !box.done else { return }
                box.done = true
                continuation.resume(returning: value)
            }
            handler.onHeight = { resumeOnce(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + rowWatchdogSeconds) {
                resumeOnce(false) // 看门狗超时：未收到有效高度
            }
        }

        // 高度已到；产物消息（renderedSnapshot）与高度异步并行到达，拆探针前
        // 给最多 400ms 宽限等产物落缓存，此后该行首次揭示即可走重放。
        var snapshotWait: TimeInterval = 0
        while !handler.snapshotDelivered, snapshotWait < 0.4, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            snapshotWait += 0.05
        }

        webView.stopLoading()
        configuration.userContentController.removeScriptMessageHandler(forName: "height")
        configuration.userContentController.removeScriptMessageHandler(forName: "renderedSnapshot")
        window.contentView = nil
        window.orderOut(nil)
        return ok
    }
}

/// 探针的消息 handler：收到首个有效高度即写缓存（宽度钉死为传入的 activeWidth 快照）；
/// renderedSnapshot 通道顺带把最终渲染产物写缓存。
@MainActor
private final class ProbeHeightHandler: NSObject, WKScriptMessageHandler {
    /// 首次有效高度后回调一次，供 probe 的 continuation 恢复。
    var onHeight: (() -> Void)?
    /// 产物是否已落缓存（供 probe 拆探针前宽限等待）。
    private(set) var snapshotDelivered = false
    private let markdown: String
    private let width: CGFloat
    private let rendererScriptURL: URL

    init(markdown: String, width: CGFloat, rendererScriptURL: URL) {
        self.markdown = markdown
        self.width = width
        self.rendererScriptURL = rendererScriptURL
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "renderedSnapshot" {
            guard let body = message.body as? [String: Any],
                  let html = body["html"] as? String, !html.isEmpty else { return }
            let engine = NewPiMarkdownWebDocument.engineFingerprint(rendererScriptURL: rendererScriptURL)
            // 宽度同样钉死快照值，不用探针自报的 clientWidth（与高度写缓存同约束）。
            MarkdownRenderingCache.shared.setRenderedHTML(html, width: width, engine: engine, for: markdown)
            snapshotDelivered = true
            return
        }
        guard message.name == "height",
              let body = message.body as? [String: Any],
              let height = (body["height"] as? NSNumber)?.doubleValue,
              height > 0 else { return }
        // 钉死宽度：不用探针自身上报的 clientWidth（离屏 1px 出入 / 0 会写错桶并污染 currentWidth）。
        MarkdownRenderingCache.shared.setHeight(CGFloat(height), width: width, for: markdown)
        onHeight?()
    }
}
