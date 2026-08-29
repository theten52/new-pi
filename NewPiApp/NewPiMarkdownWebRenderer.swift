import AppKit
import CryptoKit
import Foundation
import NewPiCore
import SwiftUI
import WebKit

/// 每条消息渲染完成后的高度缓存。冷重建（切换回未保活会话）或 rail 跳转前，
/// 首帧直接用缓存高度，避免 0 → 真实高度的渐进测高闪烁，也让 LazyVStack 的
/// 滚动位置估算足够准（rail 跳转定位依赖它）。
/// - key 为内容的 SHA256（跨启动稳定，可持久化；`hashValue` 每次启动都会变，不能用）
/// - 高度是宽度的函数：条目记录实测时的内容宽度，宽度变化即整体失效并重新填充
/// - markdown 渲染高度同时受引擎指纹约束：渲染器 js/css 变更后旧高度一律 miss
///   （与 renderedHTML 产物查询的引擎校验对齐；文本行估算高度与引擎无关，不校验）
/// - LRU 上限 512 条；debounce 持久化到 ~/.new-pi/agent/markdown-height-cache.json
@MainActor
final class MarkdownRenderingCache: ObservableObject {
    static let shared = MarkdownRenderingCache()

    /// 缓存内容版本号：预热/实测写入时递增，供高度表等订阅方重建
    /// （预热在后台陆续填充缓存，没有通知的话占位高度永远停留在估算值）。
    @Published private(set) var version = 0

    private struct Entry: Codable {
        var height: Double
        var lastAccess: Date
        /// 最终渲染产物（innerHTML）。存在即表示该消息可重放，不再需要解析渲染。
        var html: String?
        /// 捕获产物时的渲染引擎指纹（MarkdownRenderer 资源哈希）；不匹配则产物作废。
        var engine: String?
    }

    /// 磁盘格式 v2：外层 key 为内容宽度的量化字符串（String(Int(width))，JS 上报 ceil 已是整数），
    /// 内层 key 为内容 SHA256。宽度变只切换桶、不整表失效（窗口 resize 来回不丢缓存）。
    private struct DiskFormat: Codable {
        var buckets: [String: [String: Entry]]
    }

    /// 磁盘格式 v1（单宽度全局一张表），用于旧文件一次性迁移。
    private struct LegacyDiskFormat: Codable {
        var width: Double
        var entries: [String: Entry]
    }

    /// 内存桶：widthKey -> [sha256 -> Entry]
    private var buckets: [String: [String: Entry]] = [:]
    /// 当前生效的内容宽度（来自最近一次实测）；命中判定选这个宽度的桶。
    private var currentWidth: CGFloat = 0
    /// 最近一次实测生效的内容宽度（只读），供离屏预测高探针对齐"同一宽度桶"。
    var activeWidth: CGFloat { currentWidth }
    /// 全局条目上限（跨桶拍平 LRU，GLM review 意见6）。
    private let maxEntries = 2048
    private var saveWorkItem: DispatchWorkItem?
    private let fileURL: URL

    private init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".new-pi/agent/markdown-height-cache.json")
        load()
    }

    /// 当前渲染引擎指纹（MarkdownRenderer 目录 js/css 内容哈希，带缓存，读取廉价）。
    /// 供引擎相关高度的读写校验：指纹变化后旧高度一律 miss，重新实测填充。
    private var currentEngine: String? {
        guard let url = NewPiMarkdownWebDocument.rendererScriptURL() else { return nil }
        return NewPiMarkdownWebDocument.engineFingerprint(rendererScriptURL: url)
    }

    /// markdown 渲染高度查询（引擎相关）：引擎指纹不匹配（含无指纹的遗留条目）一律 miss。
    func height(for markdown: String) -> CGFloat? {
        guard currentWidth > 0 else { return nil }
        let key = key(for: markdown)
        let widthKey = Self.widthKey(currentWidth)
        guard var entry = buckets[widthKey]?[key], entry.height > 0 else { return nil }
        guard let engine = entry.engine, engine == currentEngine else { return nil }
        entry.lastAccess = Date()
        buckets[widthKey]?[key] = entry
        return CGFloat(entry.height)
    }

    /// 指定宽度桶的高度查询（文本行估算高度用：NSAttributedString 排版结果，与渲染引擎无关，
    /// 不做引擎校验）。供高度表按行类型各自的宽度口径查询，不受 currentWidth 影响。
    func height(for markdown: String, width: CGFloat) -> CGFloat? {
        let key = key(for: markdown)
        let widthKey = Self.widthKey(width)
        guard var entry = buckets[widthKey]?[key], entry.height > 0 else { return nil }
        entry.lastAccess = Date()
        buckets[widthKey]?[key] = entry
        return CGFloat(entry.height)
    }

    /// - engineDependent: true（默认，markdown 渲染高度）时盖上当前引擎指纹，
    ///   供 height(for:) 校验；false（文本行估算高度）则不盖戳、不参与引擎失效。
    func setHeight(_ height: CGFloat, width: CGFloat, for markdown: String, updateActiveWidth: Bool = true, engineDependent: Bool = true) {
        guard height > 0, width > 0 else { return }
        // 文本行等次级写入者不翻动活动宽度桶：桶选择基线只属于真实 md 渲染宽度。
        if updateActiveWidth { currentWidth = width }
        let widthKey = Self.widthKey(width)
        let hash = key(for: markdown)
        // 就地更新而不是整体替换：保留已捕获的渲染产物（html）字段。
        if var entry = buckets[widthKey, default: [:]][hash] {
            entry.height = Double(height)
            entry.lastAccess = Date()
            if engineDependent { entry.engine = currentEngine }
            buckets[widthKey]?[hash] = entry
        } else {
            buckets[widthKey, default: [:]][hash] = Entry(
                height: Double(height),
                lastAccess: Date(),
                engine: engineDependent ? currentEngine : nil
            )
        }
        evictIfNeeded()
        scheduleSave()
        scheduleVersionBump()
    }

    /// 命中即返回可重放的最终渲染产物（HTML）。要求当前宽度桶内有该内容、
    /// 且产物捕获时的引擎指纹与当前一致（渲染器/样式变更后旧产物整体作废）。
    func renderedHTML(for markdown: String, engine: String) -> String? {
        guard currentWidth > 0 else { return nil }
        let hash = key(for: markdown)
        let widthKey = Self.widthKey(currentWidth)
        guard var entry = buckets[widthKey]?[hash],
              let html = entry.html,
              entry.engine == engine else { return nil }
        entry.lastAccess = Date()
        buckets[widthKey]?[hash] = entry
        return html
    }

    /// 写入最终渲染产物。高度仍由高度上报通道写入，这里只补 html/engine。
    func setRenderedHTML(_ html: String, width: CGFloat, engine: String, for markdown: String) {
        guard !html.isEmpty, width > 0 else { return }
        currentWidth = width
        let widthKey = Self.widthKey(width)
        let hash = key(for: markdown)
        var entry = buckets[widthKey, default: [:]][hash] ?? Entry(height: 0, lastAccess: Date())
        entry.html = html
        entry.engine = engine
        entry.lastAccess = Date()
        buckets[widthKey]?[hash] = entry
        evictIfNeeded()
        scheduleSave()
        scheduleVersionBump()
    }

    /// 版本号通知合并：预热/实测会连续写入（一个预热批次可达上百次），
    /// 逐次 bump 会让订阅方（高度表重建 + 锚点校正）每行都跑一次 → 滚动条频繁跳动。
    /// 数据写入是即时的（height(for:) 读取不受影响），合并的只是「通知」；
    /// 300ms 窗口内的写入合并为一次版本变更。
    private var versionBumpWorkItem: DispatchWorkItem?
    private func scheduleVersionBump() {
        guard versionBumpWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.versionBumpWorkItem = nil
            self.version += 1
        }
        versionBumpWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// 项目切换等场景下清空缓存，避免跨项目高度残留。
    /// 刻意保留 currentWidth：同 app 窗口的内容宽度跨项目不变，activeWidth 基线继续有效；
    /// 桶已清空则 height(for:) 必 miss，行为正确（K3 review minor）。
    func clear() {
        buckets.removeAll()
        scheduleSave()
        // 清空需要即时通知（新项目的占位高度必须立刻生效），不合并。
        versionBumpWorkItem?.cancel()
        versionBumpWorkItem = nil
        version += 1
    }

    private func key(for markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 宽度量化到整数（JS 上报 Math.ceil(clientWidth) 已是整数），作为桶 key，
    /// 避免 Double 直接序列化与 1pt 容差不齐（GLM review 意见6）。
    private static func widthKey(_ width: CGFloat) -> String {
        "w\(Int(width))"
    }

    /// 从桶集里挑出「最近被访问条目」所属的宽度，作为冷启动时的当前宽度，提升命中率。
    private func mostRecentlyUsedWidth() -> CGFloat {
        var latest = Date.distantPast
        var width: CGFloat = 0
        for (widthKeyValue, map) in buckets {
            guard let value = Double(widthKeyValue.dropFirst()) else { continue }
            for entry in map.values where entry.lastAccess > latest {
                latest = entry.lastAccess
                width = CGFloat(value)
            }
        }
        return width
    }

    private func evictIfNeeded() {
        let total = buckets.values.reduce(0) { $0 + $1.count }
        guard total > maxEntries else { return }
        // 跨桶拍平收集后按 lastAccess 全局排序，淘汰最旧的一批（回到桶里删除）。
        var all: [(widthKey: String, hash: String, entry: Entry)] = []
        for (wk, map) in buckets {
            for (hash, entry) in map {
                all.append((wk, hash, entry))
            }
        }
        let overflow = total - maxEntries + maxEntries / 5
        let oldest = all.sorted { $0.entry.lastAccess < $1.entry.lastAccess }.prefix(overflow)
        for victim in oldest {
            buckets[victim.widthKey]?.removeValue(forKey: victim.hash)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let disk = try? JSONDecoder().decode(DiskFormat.self, from: data) {
            buckets = disk.buckets
            currentWidth = mostRecentlyUsedWidth()
            return
        }
        if let legacy = try? JSONDecoder().decode(LegacyDiskFormat.self, from: data) {
            // v1（单宽度全局表）→ v2（按宽度分桶）一次性迁移；旧格式被 try? 静默丢弃是排障黑洞
            // （GLM review 意见6），故加 info 日志并立即重写为新格式。
            buckets = [Self.widthKey(CGFloat(legacy.width)): legacy.entries]
            currentWidth = CGFloat(legacy.width)
            NewPiLogger.info(
                category: "app",
                message: "Migrated legacy markdown height cache (v1 → v2)",
                details: "entries=\(legacy.entries.count) width=\(legacy.width)"
            )
            scheduleSave()
            return
        }
        NewPiLogger.info(category: "app", message: "Markdown height cache decode failed, resetting", details: "")
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func saveNow() {
        let disk = DiskFormat(buckets: buckets)
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
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

    /// 渲染引擎指纹：MarkdownRenderer 目录资源（js/css）内容哈希。
    /// 渲染器或样式任何变化都会改变指纹，使已存渲染产物整体失效
    /// （回落正常渲染并重新捕获），无需手工维护版本号。
    @MainActor
    static func engineFingerprint(rendererScriptURL: URL) -> String {
        if let cached = cachedEngineFingerprint { return cached }
        let directory = rendererScriptURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
        var hash = SHA256()
        for name in names {
            let fileURL = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            hash.update(data: Data(name.utf8))
            hash.update(data: data)
        }
        let digest = hash.finalize()
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        cachedEngineFingerprint = fingerprint
        return fingerprint
    }

    @MainActor private static var cachedEngineFingerprint: String?

    /// 重放文档：与 documentHTML 相同的 CSP 与样式表，但 article 预填最终渲染产物，
    /// 不内联 markdown 源码、不走解析/增量/光标管线，仅重绑交互并上报高度。
    /// 产物是 markdown-it(html:false) 的转义输出；CSP 无 unsafe-inline，
    /// 产物中即便混入内联脚本或事件属性也不会执行。
    static func replayDocumentHTML(renderedHTML: String, rendererScriptURL: URL) -> String {
        let rendererDirectoryURL = rendererScriptURL.deletingLastPathComponent()
        let markdownItURL = rendererDirectoryURL.appendingPathComponent("markdown-it.min.js")
        let highlightURL = rendererDirectoryURL.appendingPathComponent("highlight.min.js")
        let githubMarkdownCSSURL = rendererDirectoryURL.appendingPathComponent("github-markdown-light.css")
        let highlightCSSURL = rendererDirectoryURL.appendingPathComponent("highlight-github.min.css")
        let appCSSURL = rendererDirectoryURL.appendingPathComponent("markdown-renderer.css")

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
          <article id="markdown-root" class="markdown-body">\(renderedHTML)</article>
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
          <script nonce="\(scriptNonce)">window.replayRendered();</script>
        </body>
        </html>
        """
    }

    /// 单文档 transcript 外壳（BACKLOG-SINGLE-DOC，Phase 1）：整条会话一个文档。
    /// 与 per-message 页同样的本地资源 + CSP；多加载 transcript-document.css/js。
    static func transcriptDocumentHTML(rendererScriptURL: URL) -> String {
        let rendererDirectoryURL = rendererScriptURL.deletingLastPathComponent()
        let markdownItURL = rendererDirectoryURL.appendingPathComponent("markdown-it.min.js")
        let highlightURL = rendererDirectoryURL.appendingPathComponent("highlight.min.js")
        let githubMarkdownCSSURL = rendererDirectoryURL.appendingPathComponent("github-markdown-light.css")
        let highlightCSSURL = rendererDirectoryURL.appendingPathComponent("highlight-github.min.css")
        let appCSSURL = rendererDirectoryURL.appendingPathComponent("markdown-renderer.css")
        let transcriptCSSURL = rendererDirectoryURL.appendingPathComponent("transcript-document.css")
        let transcriptJSURL = rendererDirectoryURL.appendingPathComponent("transcript-document.js")

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
          <link rel="stylesheet" href="\(htmlAttributeEscaped(transcriptCSSURL.absoluteString))">
        </head>
        <body>
          <main id="transcript"></main>
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
          <script src="\(htmlAttributeEscaped(transcriptJSURL.absoluteString))"></script>
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
    /// 首次 flush 高度到达后回调一次（= 本行初始渲染完成），供冷加载就绪门控用。
    var onInitialRendered: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            height: $height,
            onRenderingFailed: onRenderingFailed,
            onInitialRendered: onInitialRendered
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "height")
        configuration.userContentController.add(context.coordinator, name: "copyText")
        configuration.userContentController.add(context.coordinator, name: "rendererError")
        configuration.userContentController.add(context.coordinator, name: "renderedSnapshot")

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "renderedSnapshot")
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
        private let onInitialRendered: (() -> Void)?
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
        /// 渲染代号：每次 loadInitial（含内容进程终止后的重建）递增，使所有在途的
        /// evaluateJavaScript 回调失效。WebKit 内容进程被杀后，在途调用可能以「错误回调」
        /// 收场——若据此重置 isRenderingJavaScript 并 reportFailure 会一次性锁存、恢复白做。
        /// epoch 不匹配的直接忽略回调，无论 WebKit 以何种方式收尾都正确。
        private var renderEpoch = 0
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
        /// 本 Coordinator 生命周期内是否已发出过「初始渲染完成」信号（每次 loadInitial 重置）。
        private var hasSignaledInitialRender = false

        /// Minimum interval between streaming renders (throttle, not debounce).
        private let throttleInterval: TimeInterval = 0.05
        private let streamingHeightEpsilon: CGFloat = 4

        init(
            height: Binding<CGFloat>,
            onRenderingFailed: @escaping () -> Void,
            onInitialRendered: (() -> Void)? = nil
        ) {
            _height = height
            self.onRenderingFailed = onRenderingFailed
            self.onInitialRendered = onInitialRendered
        }

        func loadInitial(markdown: String, rendererScriptURL: URL, flush: Bool, in webView: WKWebView) {
            self.rendererScriptURL = rendererScriptURL
            isFlushRendering = flush
            pendingMarkdown = markdown
            // 重建页面（如内容进程终止后的恢复）时，在途的 evaluateJavaScript 回调
            // 不会再触发，必须重置在途状态，否则后续渲染会被永久卡住。
            throttleWorkItem?.cancel()
            throttleWorkItem = nil
            renderEpoch += 1
            hasSignaledInitialRender = false
            isRenderingJavaScript = false
            rerenderAfterFlight = false
            do {
                // 产物重放：非流式行且产物缓存命中（同宽度桶 + 同引擎指纹）时，
                // 直接加载预填最终 HTML 的重放文档——不跑解析/增量/光标管线。
                let engine = NewPiMarkdownWebDocument.engineFingerprint(rendererScriptURL: rendererScriptURL)
                let html: String
                if flush, let renderedHTML = MarkdownRenderingCache.shared.renderedHTML(for: markdown, engine: engine) {
                    html = NewPiMarkdownWebDocument.replayDocumentHTML(
                        renderedHTML: renderedHTML,
                        rendererScriptURL: rendererScriptURL
                    )
                } else {
                    html = try NewPiMarkdownWebDocument.documentHTML(
                        markdown: markdown,
                        rendererScriptURL: rendererScriptURL,
                        streaming: !flush
                    )
                }
                // 不要无条件把高度重置为 44：NewPiMarkdownText 已用缓存高度初始化 webHeight，
                // 这里若覆盖会架空高度缓存，使 LazyVStack 用 44 估算、滚动定位失真。
                // 仅当无有效初值（<=0）时才兜底为 44。
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.height <= 0 { self.height = 44 }
                }
                isPageLoaded = false
                // 页面内的内联引导 script 已完成初次渲染，这里记本次 markdown 而非 nil，
                // didFinish 才不会对相同内容再强制 evaluateJavaScript 一次（重复二次渲染）。
                lastRenderedMarkdown = markdown
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
            // 本地捕获渲染代号与模式：JS 在途期间新的 scheduleUpdate 可能翻转 isFlushRendering，
            // 完成回调里记录的是本次实际渲染所用的模式；epoch 用于识别 loadInitial 重建后
            // 已过期的在途回调（内容进程恢复场景）。
            let epoch = renderEpoch
            let flush = isFlushRendering
            do {
                let script = try NewPiMarkdownWebDocument.renderJavaScript(
                    for: markdown,
                    streaming: !flush
                )
                webView.evaluateJavaScript(script) { [weak self] _, error in
                    guard let self else { return }
                    // loadInitial 重建（含内容进程终止恢复）已使本次在途调用过期：epoch 不匹配
                    // 直接忽略，不重置 isRenderingJavaScript（loadInitial 已重置）、也不 reportFailure，
                    // 否则一次错误回调就会把恢复路径白做、退款回原生文本。
                    guard self.renderEpoch == epoch else { return }
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

            // 最终渲染产物回传（仅 flush 渲染路径会发）：写入产物缓存，此后该消息重放展示。
            // 高度仍由 height 通道独立写入，这里只补 html/engine。
            if message.name == "renderedSnapshot" {
                guard let payload = message.body as? [String: Any],
                      let html = payload["html"] as? String, !html.isEmpty else { return }
                let width = Self.numericValue(payload["width"])
                guard width > 0,
                      let markdown = lastRenderedMarkdown ?? pendingMarkdown,
                      let rendererScriptURL else { return }
                let engine = NewPiMarkdownWebDocument.engineFingerprint(rendererScriptURL: rendererScriptURL)
                MarkdownRenderingCache.shared.setRenderedHTML(html, width: width, engine: engine, for: markdown)
                return
            }

            guard message.name == "height" else { return }

            // JS 上报 { height, width }：高度是宽度的函数，宽度随高度一起进缓存。
            // 兼容旧的纯数字格式。
            var reportedHeight: CGFloat = 0
            var reportedWidth: CGFloat = 0
            if let payload = message.body as? [String: Any] {
                reportedHeight = Self.numericValue(payload["height"])
                reportedWidth = Self.numericValue(payload["width"])
            } else {
                reportedHeight = Self.numericValue(message.body)
            }
            guard reportedHeight > 0 else { return }

            scheduleHeightUpdate(reportedHeight, width: reportedWidth)
        }

        private static func numericValue(_ value: Any?) -> CGFloat {
            guard let number = value as? NSNumber else { return 0 }
            return CGFloat(truncating: number)
        }

        private func scheduleHeightUpdate(_ reportedHeight: CGFloat, width reportedWidth: CGFloat) {
            if isFlushRendering {
                // 首个 flush 高度 = 本 Coordinator 生命周期内「初始渲染完成」信号（GLM review 意见5：
                // 流式行结束的 flush 重渲染也走此处，语义为「生命周期内第一次 flush 高度」而非仅初始）。
                // JS 侧 flush 渲染必发第一次 height 上报（markdown-renderer.js lastPostedHeight=0 后 force
                // 上报）。仅供冷加载就绪门控读，只读不写缓存。活跃会话 pending 恒空，多余信号幂等无害。
                if !hasSignaledInitialRender {
                    hasSignaledInitialRender = true
                    onInitialRendered?()
                }
                if abs(reportedHeight - height) >= streamingHeightEpsilon {
                    height = reportedHeight
                }
                // 最终渲染的高度写入缓存，供冷重建首帧直接用，避免 0→真实高度的闪烁。
                if let markdown = lastRenderedMarkdown ?? pendingMarkdown {
                    MarkdownRenderingCache.shared.setHeight(reportedHeight, width: reportedWidth, for: markdown)
                }
                return
            }

            applyStreamingHeight(reportedHeight)
        }

        private func applyStreamingHeight(_ reportedHeight: CGFloat) {
            // 流式期间高度只增不减，且量化到 160pt 向上步进：内容增高未越档就不改 frame。
            // 实测（sample）主线程约 73% 时间阻塞在 WebView layer 重分配的 CA 表面同步
            // （RBLayer display → wait_for_allocations）上，根因就是这里每次 delta 都改高度；
            // 量化把 layer 重分配次数降一到两个数量级。flush（完成态）走 scheduleHeightUpdate
            // 落精确高度。frame ≥ 内容恒成立，不会裁剪（.clipped() 安全）。
            let step: CGFloat = 160
            let stepped = ceil(max(1, reportedHeight) / step) * step
            let nextHeight = max(height, stepped)
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

            // 文本相同但渲染模式翻转（如流式在页面加载完成前结束、flush 更新被 isPageLoaded
            // 挡掉丢弃）也必须渲染：否则最终高亮/终态光标/ResizeObserver 永不发生——当初
            // lastRenderWasFlush 修的就是这类 bug。判断与 renderPending 保持一致。
            if let markdown = pendingMarkdown,
               markdown != lastRenderedMarkdown || isFlushRendering != lastRenderWasFlush {
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
