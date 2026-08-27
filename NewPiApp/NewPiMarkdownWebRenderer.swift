import AppKit
import Foundation
import SwiftUI
import WebKit

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
    static func documentHTML(markdown: String, rendererScriptURL: URL) throws -> String {
        let rendererDirectoryURL = rendererScriptURL.deletingLastPathComponent()
        let markdownItURL = rendererDirectoryURL.appendingPathComponent("markdown-it.min.js")
        let highlightURL = rendererDirectoryURL.appendingPathComponent("highlight.min.js")
        let githubMarkdownCSSURL = rendererDirectoryURL.appendingPathComponent("github-markdown-light.css")
        let highlightCSSURL = rendererDirectoryURL.appendingPathComponent("highlight-github.min.css")
        let appCSSURL = rendererDirectoryURL.appendingPathComponent("markdown-renderer.css")
        let markdownExpression = try jsonParseExpression(for: markdown)

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
          <script src="\(htmlAttributeEscaped(markdownItURL.absoluteString))"></script>
          <script src="\(htmlAttributeEscaped(highlightURL.absoluteString))"></script>
          <script src="\(htmlAttributeEscaped(rendererScriptURL.absoluteString))"></script>
          <script nonce="\(scriptNonce)">window.renderMarkdown(\(markdownExpression));</script>
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        configureForEmbeddedMarkdown(webView)
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.installScrollWheelForwarding(for: webView)
        context.coordinator.loadInitial(
            markdown: markdown,
            rendererScriptURL: rendererScriptURL,
            in: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
        private var rendererScriptURL: URL?
        private var throttleWorkItem: DispatchWorkItem?
        private var isFlushRendering = true
        private var isRenderingJavaScript = false
        private var rerenderAfterFlight = false
        private var lastRenderTime = Date.distantPast
        private var hasReportedFailure = false
        private weak var scrollForwardingWebView: WKWebView?
        private var scrollWheelMonitor: Any?

        /// Minimum interval between streaming renders (throttle, not debounce).
        private let throttleInterval: TimeInterval = 0.05
        private let streamingHeightEpsilon: CGFloat = 4

        init(height: Binding<CGFloat>, onRenderingFailed: @escaping () -> Void) {
            _height = height
            self.onRenderingFailed = onRenderingFailed
        }

        func loadInitial(markdown: String, rendererScriptURL: URL, in webView: WKWebView) {
            self.rendererScriptURL = rendererScriptURL
            pendingMarkdown = markdown
            do {
                let html = try NewPiMarkdownWebDocument.documentHTML(
                    markdown: markdown,
                    rendererScriptURL: rendererScriptURL
                )
                // 禁止在视图更新周期内写 @Binding（makeNSView 里直接赋值会触发
                // SwiftUI “Modifying state during view update” 运行时警告），延后到下一轮 runloop 再置初值。
                DispatchQueue.main.async { [weak self] in
                    self?.height = 44
                }
                isPageLoaded = false
                lastRenderedMarkdown = nil
                webView.loadHTMLString(html, baseURL: rendererScriptURL.deletingLastPathComponent())
            } catch {
                reportFailure()
            }
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
        }

        func installScrollWheelForwarding(for webView: WKWebView) {
            scrollForwardingWebView = webView
            guard scrollWheelMonitor == nil else { return }

            scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.forwardVerticalScrollIfNeeded(event) ?? event
            }
        }

        func removeScrollWheelForwarding() {
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor)
            }
            scrollWheelMonitor = nil
            scrollForwardingWebView = nil
        }

        private func renderPending(in webView: WKWebView) {
            guard let markdown = pendingMarkdown else { return }
            guard markdown != lastRenderedMarkdown else { return }

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
            do {
                let script = try NewPiMarkdownWebDocument.renderJavaScript(
                    for: markdown,
                    streaming: !isFlushRendering
                )
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard let self else { return }
                    self.isRenderingJavaScript = false
                    if error != nil {
                        self.reportFailure()
                        return
                    }
                    self.lastRenderedMarkdown = markdown
                    self.lastRenderTime = Date()
                    if self.rerenderAfterFlight {
                        self.rerenderAfterFlight = false
                        self.renderPending(in: webView)
                    }
                }
            } catch {
                isRenderingJavaScript = false
                reportFailure()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
                return
            }

            applyStreamingHeight(reportedHeight)
        }

        private func applyStreamingHeight(_ reportedHeight: CGFloat) {
            let nextHeight = max(height, max(1, reportedHeight))
            guard nextHeight > height else { return }

            height = nextHeight
            NotificationCenter.default.post(name: .newPiStreamingContentDidGrow, object: nil)
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
            reportFailure()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            NewPiMarkdownWebRendererView.configureEmbeddedScrollViews(in: webView)

            if let markdown = pendingMarkdown, markdown != lastRenderedMarkdown {
                renderViaJavaScript(markdown: markdown, in: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        private func reportFailure() {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            onRenderingFailed()
        }

        private func forwardVerticalScrollIfNeeded(_ event: NSEvent) -> NSEvent? {
            guard
                let webView = scrollForwardingWebView,
                let eventWindow = event.window,
                eventWindow === webView.window
            else {
                return event
            }

            let eventPoint = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(eventPoint) else { return event }
            guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.scrollingDeltaY != 0 else {
                return event
            }

            guard let outerScrollView = enclosingScrollView(outside: webView) else {
                return event
            }

            outerScrollView.scrollWheel(with: event)
            return nil
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
}
