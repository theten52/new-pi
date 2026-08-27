import AppKit
import Foundation
import NewPiCore
import SwiftUI
import WebKit

/// 每条消息渲染完成后的高度缓存。冷重建（切换回未保活会话）时首帧直接用缓存高度，
/// 避免 0 → 真实高度的渐进测高闪烁，也减少一次布局回跳。
/// 使用 NSCache：内存吃紧时自动淘汰，避免只增不减的内存泄漏；key 用哈希而非完整 markdown。
@MainActor
final class MarkdownRenderingCache {
    static let shared = MarkdownRenderingCache()
    private let cache = NSCache<NSString, NSNumber>()

    private init() {
        cache.countLimit = 512
    }

    func height(for markdown: String, flush: Bool) -> CGFloat? {
        guard let number = cache.object(forKey: key(markdown, flush) as NSString) else { return nil }
        return CGFloat(number.doubleValue)
    }

    func setHeight(_ height: CGFloat, for markdown: String, flush: Bool) {
        cache.setObject(NSNumber(value: height), forKey: key(markdown, flush) as NSString)
    }

    /// 项目切换等场景下清空缓存，避免跨项目高度残留。
    func clear() {
        cache.removeAllObjects()
    }

    private func key(_ markdown: String, _ flush: Bool) -> String {
        "\(flush ? "f" : "s")|\(String(markdown.hashValue))"
    }
}

/// 标记当前会话面板是否为活跃可交互面板。滚轮转发只在活跃面板内生效：
/// 保活后多个会话面板 frame 重叠，若所有面板的 WebView 都注册转发，
/// 每个滚轮事件都会同时命中多层面板导致转发混乱、滚动卡死。
private struct PanelIsActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelIsActive: Bool {
        get { self[PanelIsActiveEnvironmentKey.self] }
        set { self[PanelIsActiveEnvironmentKey.self] = newValue }
    }
}

enum NewPiMarkdownWebDocument {
    enum DocumentError: Error {
        case invalidJSONString
    }

    static let scriptNonce = "com-newpi-markdown-renderer"

    static func rendererDirectoryURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "MarkdownRenderer", withExtension: nil)
    }

    static func rendererScriptURL(in bundle: Bundle = .main) -> URL? {
        rendererDirectoryURL(in: bundle)?.appendingPathComponent("markdown-renderer.js")
    }

    // SECURITY-REVIEW: Model Markdown is untrusted. The source is double JSON-encoded
    // before entering inline script / evaluateJavaScript so characters such as </script>
    // cannot break out of the JavaScript string boundary.
    static func documentHTML(markdown: String, rendererScriptURL: URL, streaming: Bool = false) throws -> String {
        let rendererDirectoryURL = rendererScriptURL.deletingLastPathComponent()
        let markdownItURL = rendererDirectoryURL.appendingPathComponent("markdown-it.min.js")
        let highlightURL = rendererDirectoryURL.appendingPathComponent("highlight.min.js")
        let githubMarkdownCSSURL = rendererDirectoryURL.appendingPathComponent("github-markdown-light.css")
        let highlightCSSURL = rendererDirectoryURL.appendingPathComponent("highlight-github.min.css")
        let appCSSURL = rendererDirectoryURL.appendingPathComponent("markdown-renderer.css")
        let initialRenderScript = try renderJavaScript(for: markdown, streaming: streaming)

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'self' file:; script-src 'self' file: 'nonce-\(scriptNonce)'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          <link rel="stylesheet" href="\(htmlAttributeEscaped(githubMarkdownCSSURL.absoluteString))">
          <link rel="stylesheet" href="\(htmlAttributeEscaped(highlightCSSURL.absoluteString))">
          <link rel="stylesheet" href="\(htmlAttributeEscaped(appCSSURL.absoluteString))">
        </head>
        <body>
          <article id="markdown-root" class="markdown-body"></article>
          <script nonce="\(scriptNonce)">
            window.onerror = function (message, source, line, column) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rendererError) {
                window.webkit.messageHandlers.rendererError.postMessage(
                  String(message) + " @ " + String(source) + ":" + String(line) + ":" + String(column)
                );
              }
            };
          </script>
          <script src="\(htmlAttributeEscaped(markdownItURL.absoluteString))"></script>
          <script src="\(htmlAttributeEscaped(highlightURL.absoluteString))"></script>
          <script src="\(htmlAttributeEscaped(rendererScriptURL.absoluteString))"></script>
          <script nonce="\(scriptNonce)">\(initialRenderScript)</script>
        </body>
        </html>
        """
    }

    static func renderJavaScript(for markdown: String, streaming: Bool = false) throws -> String {
        let expression = try jsonParseExpression(for: markdown)
        if streaming {
            return "window.renderMarkdown(\(expression), { streaming: true });"
        }
        return "window.renderMarkdown(\(expression));"
    }

    static func jsonParseExpression(for markdown: String) throws -> String {
        let markdownData = try JSONSerialization.data(withJSONObject: markdown, options: [.fragmentsAllowed])
        guard let markdownJSON = String(data: markdownData, encoding: .utf8) else {
            throw DocumentError.invalidJSONString
        }

        let scriptData = try JSONSerialization.data(withJSONObject: markdownJSON, options: [.fragmentsAllowed])
        guard var scriptLiteral = String(data: scriptData, encoding: .utf8) else {
            throw DocumentError.invalidJSONString
        }

        scriptLiteral = scriptLiteral.replacingOccurrences(of: "</", with: "<\\/")
        return "JSON.parse(\(scriptLiteral))"
    }

    private static func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// 所有 Markdown WebView 共享的滚轮转发器。
/// 每条消息一个 WebView，若按实例各注册一个全局 NSEvent 监听，N 条消息会让
/// 每个滚轮事件串行经过 N 个监听器；改为单例监听 + 弱引用注册表，命中即转发。
@MainActor
private final class MarkdownScrollWheelForwarder {
    static let shared = MarkdownScrollWheelForwarder()

    private var monitor: Any?
    private let webViews = NSHashTable<WKWebView>.weakObjects()

    private init() {}

    func register(_ webView: WKWebView) {
        webViews.add(webView)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MarkdownScrollWheelForwarder.shared.forward(event)
        }
    }

    func unregister(_ webView: WKWebView) {
        webViews.remove(webView)
        guard webViews.count == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// 垂直滚轮落在某个 WebView 上时，转发给它所在的外层 NSScrollView 并消费掉；
    /// 否则原样返回，不影响其它视图。
    private func forward(_ event: NSEvent) -> NSEvent? {
        guard let eventWindow = event.window,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              event.scrollingDeltaY != 0 else {
            return event
        }

        for webView in webViews.allObjects {
            guard eventWindow === webView.window else { continue }
            let point = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(point) else { continue }
            guard let scrollView = enclosingScrollView(outside: webView) else { return event }
            scrollView.scrollWheel(with: event)
            return nil
        }
        return event
    }

    private func enclosingScrollView(outside view: NSView) -> NSScrollView? {
        var currentView = view.superview
        while let view = currentView {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            currentView = view.superview
        }
        return nil
    }
}

struct NewPiMarkdownWebRendererView: NSViewRepresentable {
    let markdown: String
    let rendererScriptURL: URL
    @Binding var height: CGFloat
    var flushRendering: Bool
    let onRenderingFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onRenderingFailed: onRenderingFailed)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "height")
        configuration.userContentController.add(context.coordinator, name: "copyText")
        configuration.userContentController.add(context.coordinator, name: "rendererError")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        configureForEmbeddedMarkdown(webView)
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 只在活跃面板内启用滚轮转发，避免保活多面板 frame 重叠导致滚动卡死。
        if context.environment.panelIsActive {
            context.coordinator.installScrollWheelForwarding(for: webView)
        }
        context.coordinator.loadInitial(
            markdown: markdown,
            rendererScriptURL: rendererScriptURL,
            flush: flushRendering,
            in: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 面板活跃状态变化时同步滚轮转发的启用/停用（inactive 面板不转发）。
        let shouldForward = context.environment.panelIsActive
        if shouldForward != context.coordinator.isScrollForwardingEnabled {
            if shouldForward {
                context.coordinator.installScrollWheelForwarding(for: webView)
            } else {
                context.coordinator.removeScrollWheelForwarding()
            }
        }
        context.coordinator.scheduleUpdate(
            markdown: markdown,
            flush: flushRendering,
            rendererScriptURL: rendererScriptURL,
            in: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.removeScrollWheelForwarding()
        coordinator.cancelPendingUpdate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyText")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rendererError")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func configureForEmbeddedMarkdown(_ webView: WKWebView) {
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        Self.configureEmbeddedScrollViews(in: webView)
    }

    private static func configureEmbeddedScrollViews(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
            scrollView.automaticallyAdjustsContentInsets = false
        }
        view.subviews.forEach(configureEmbeddedScrollViews)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        @Binding private var height: CGFloat
        private let onRenderingFailed: () -> Void
        private var isPageLoaded = false
        private var pendingMarkdown: String?
        private var lastRenderedMarkdown: String?
        /// 上一次实际渲染是否为最终（flush）渲染。文本相同但 flush 状态翻转时
        /// 也必须重渲染 —— 否则流式结束时的去抖会跳过最终渲染，
        /// 导致流式光标残留、代码块永远拿不到 hljs 高亮。
        private var lastRenderWasFlush = true
        private var rendererScriptURL: URL?
        private var throttleWorkItem: DispatchWorkItem?
        private var isFlushRendering = true
        private var isRenderingJavaScript = false
        private var rerenderAfterFlight = false
        private var lastRenderTime = Date.distantPast
        private var hasReportedFailure = false
        /// 内容进程终止后只允许自动重建一次，反复崩溃则退回原生渲染。
        private var hasAttemptedProcessRecovery = false
        /// 页面加载看门狗：loadHTMLString 若始终不回调 didFinish，WebView 会永久白屏。
        private var loadWatchdog: DispatchWorkItem?
        /// 页面加载看门狗超时（秒）。
        private let loadWatchdogInterval: TimeInterval = 10
        private weak var scrollForwardingWebView: WKWebView?
        /// 当前 WebView 是否已启用滚轮转发（随面板活跃状态同步）。
        var isScrollForwardingEnabled = false

        /// Minimum interval between streaming renders (throttle, not debounce).
        private let throttleInterval: TimeInterval = 0.05
        private let streamingHeightEpsilon: CGFloat = 4

        init(height: Binding<CGFloat>, onRenderingFailed: @escaping () -> Void) {
            _height = height
            self.onRenderingFailed = onRenderingFailed
        }

        func loadInitial(markdown: String, rendererScriptURL: URL, flush: Bool, in webView: WKWebView) {
            self.rendererScriptURL = rendererScriptURL
            isFlushRendering = flush
            pendingMarkdown = markdown
            // 重建页面（如内容进程终止后的恢复）时，在途的 evaluateJavaScript 回调
            // 不会再触发，必须重置在途状态，否则后续渲染会被永久卡住。
            throttleWorkItem?.cancel()
            throttleWorkItem = nil
            isRenderingJavaScript = false
            rerenderAfterFlight = false
            do {
                let html = try NewPiMarkdownWebDocument.documentHTML(
                    markdown: markdown,
                    rendererScriptURL: rendererScriptURL,
                    streaming: !flush
                )
                // 禁止在视图更新周期内写 @Binding（makeNSView 里直接赋值会触发
                // SwiftUI “Modifying state during view update” 运行时警告），延后到下一轮 runloop 再置初值。
                DispatchQueue.main.async { [weak self] in
                    self?.height = 44
                }
                isPageLoaded = false
                lastRenderedMarkdown = nil
                lastRenderWasFlush = flush
                webView.loadHTMLString(html, baseURL: rendererScriptURL.deletingLastPathComponent())
                armLoadWatchdog(for: webView)
            } catch {
                reportFailure(reason: "documentHTML encoding failed: \(error.localizedDescription)")
            }
        }

        private func armLoadWatchdog(for webView: WKWebView) {
            loadWatchdog?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.loadWatchdog = nil
                guard !self.isPageLoaded, webView.window != nil else { return }
                self.reportFailure(reason: "page load watchdog timed out (\(self.loadWatchdogInterval)s without didFinish)")
            }
            loadWatchdog = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + loadWatchdogInterval, execute: workItem)
        }

        private func disarmLoadWatchdog() {
            loadWatchdog?.cancel()
            loadWatchdog = nil
        }

        func scheduleUpdate(
            markdown: String,
            flush: Bool,
            rendererScriptURL: URL,
            in webView: WKWebView
        ) {
            self.rendererScriptURL = rendererScriptURL
            pendingMarkdown = markdown
            isFlushRendering = flush

            if flush {
                throttleWorkItem?.cancel()
                throttleWorkItem = nil
                renderPending(in: webView)
                return
            }

            let elapsed = Date().timeIntervalSince(lastRenderTime)
            if elapsed >= throttleInterval {
                renderPending(in: webView)
                return
            }

            guard throttleWorkItem == nil else { return }

            let delay = throttleInterval - elapsed
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.throttleWorkItem = nil
                self.renderPending(in: webView)
            }
            throttleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func cancelPendingUpdate() {
            throttleWorkItem?.cancel()
            throttleWorkItem = nil
            disarmLoadWatchdog()
        }

        func installScrollWheelForwarding(for webView: WKWebView) {
            scrollForwardingWebView = webView
            MarkdownScrollWheelForwarder.shared.register(webView)
            isScrollForwardingEnabled = true
        }

        func removeScrollWheelForwarding() {
            if let webView = scrollForwardingWebView {
                MarkdownScrollWheelForwarder.shared.unregister(webView)
            }
            scrollForwardingWebView = nil
            isScrollForwardingEnabled = false
        }

        private func renderPending(in webView: WKWebView) {
            guard let markdown = pendingMarkdown else { return }
            guard markdown != lastRenderedMarkdown || isFlushRendering != lastRenderWasFlush else { return }

            if isRenderingJavaScript {
                rerenderAfterFlight = true
                return
            }

            if isPageLoaded {
                renderViaJavaScript(markdown: markdown, in: webView)
            }
        }

        private func renderViaJavaScript(markdown: String, in webView: WKWebView) {
            isRenderingJavaScript = true
            // 本地捕获渲染模式：JS 在途期间新的 scheduleUpdate 可能翻转 isFlushRendering，
            // 完成回调里要记录的是本次实际渲染所用的模式。
            let flush = isFlushRendering
            do {
                let script = try NewPiMarkdownWebDocument.renderJavaScript(
                    for: markdown,
                    streaming: !flush
                )
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard let self else { return }
                    self.isRenderingJavaScript = false
                    if let error {
                        self.reportFailure(reason: "evaluateJavaScript failed: \(error.localizedDescription)")
                        return
                    }
                    self.lastRenderedMarkdown = markdown
                    self.lastRenderWasFlush = flush
                    self.lastRenderTime = Date()
                    if self.rerenderAfterFlight {
                        self.rerenderAfterFlight = false
                        self.renderPending(in: webView)
                    }
                }
            } catch {
                isRenderingJavaScript = false
                reportFailure(reason: "renderJavaScript encoding failed: \(error.localizedDescription)")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // JS 侧未捕获异常（含初始内联引导脚本，evaluateJavaScript 的错误回调覆盖不到）
            if message.name == "rendererError" {
                let detail = message.body as? String ?? "unknown"
                reportFailure(reason: "window.onerror: \(detail)")
                return
            }

            // 代码块复制按钮：file:// 源下 navigator.clipboard 不可靠，由原生写剪贴板
            if message.name == "copyText" {
                guard let text = message.body as? String else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                return
            }

            guard message.name == "height" else { return }

            let reportedHeight: CGFloat
            if let number = message.body as? NSNumber {
                reportedHeight = max(1, CGFloat(truncating: number))
            } else if let doubleValue = message.body as? Double {
                reportedHeight = max(1, CGFloat(doubleValue))
            } else {
                return
            }

            scheduleHeightUpdate(reportedHeight)
        }

        private func scheduleHeightUpdate(_ reportedHeight: CGFloat) {
            if isFlushRendering {
                if abs(reportedHeight - height) >= streamingHeightEpsilon {
                    height = reportedHeight
                }
                // 最终渲染的高度写入缓存，供冷重建首帧直接用，避免 0→真实高度的闪烁。
                if let markdown = lastRenderedMarkdown ?? pendingMarkdown {
                    MarkdownRenderingCache.shared.setHeight(reportedHeight, for: markdown, flush: true)
                }
                return
            }

            applyStreamingHeight(reportedHeight)
        }

        private func applyStreamingHeight(_ reportedHeight: CGFloat) {
            // 流式期间高度只增不减，避免布局回跳；滚动跟随由 ChatView 监听
            // transcript 变化驱动，无需在此额外发通知。
            let nextHeight = max(height, max(1, reportedHeight))
            guard nextHeight > height else { return }

            height = nextHeight
        }

        // SECURITY-REVIEW: Only local file resources and about:blank are allowed.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                return
            }

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.isFileURL || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure(reason: "navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure(reason: "provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            disarmLoadWatchdog()
            isPageLoaded = true
            NewPiMarkdownWebRendererView.configureEmbeddedScrollViews(in: webView)

            if let markdown = pendingMarkdown, markdown != lastRenderedMarkdown {
                renderViaJavaScript(markdown: markdown, in: webView)
            }
        }

        // WebKit 内容进程被终止（内存压力、同时挂载过多 WebView 等）时，
        // WebView 会变成白屏且不再响应任何 evaluateJavaScript，且不会走 didFail 回调。
        // 用当前内容重建一次页面；再次终止则退回原生渲染兜底。
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            NewPiLogger.error(
                category: "app",
                message: "Markdown web content process terminated",
                details: "willRecover=\(!hasAttemptedProcessRecovery)"
            )
            guard !hasAttemptedProcessRecovery, let rendererScriptURL else {
                reportFailure(reason: "web content process terminated again after recovery")
                return
            }
            hasAttemptedProcessRecovery = true
            loadInitial(
                markdown: pendingMarkdown ?? lastRenderedMarkdown ?? "",
                rendererScriptURL: rendererScriptURL,
                flush: isFlushRendering,
                in: webView
            )
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        private func reportFailure(reason: String) {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            NewPiLogger.error(
                category: "app",
                message: "Markdown renderer failed, falling back to native text",
                details: reason
            )
            onRenderingFailed()
        }
    }
}
