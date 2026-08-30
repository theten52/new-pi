import Foundation

/// 单文档 transcript 的 HTML 外壳工厂（BACKLOG-SINGLE-DOC 完成后，本文件只保留此用途）。
/// 遗留的 per-message WebView 宿主、高度缓存、滚轮转发器已随 Phase 2 验收删除
/// （布局/滚动/虚拟化全部由文档内浏览器引擎承担，见 docs/ui-architecture-decision.md）。
enum NewPiMarkdownWebDocument {
    static let scriptNonce = "com-newpi-markdown-renderer"

    static func rendererDirectoryURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "MarkdownRenderer", withExtension: nil)
    }

    static func rendererScriptURL(in bundle: Bundle = .main) -> URL? {
        rendererDirectoryURL(in: bundle)?.appendingPathComponent("markdown-renderer.js")
    }

    /// 单文档 transcript 外壳：<main id="transcript"> 容器 + markdown-it/hljs/渲染器 +
    /// transcript-document.js（条目 DOM 管理 + 滚动状态机）。内容全部由原生侧 diff → ops 驱动。
    /// SECURITY-REVIEW: CSP 无 unsafe-inline；条目 id 为原生 UUID，文本内容一律经
    /// textContent / markdown-it（escape 开启）进入 DOM，不存在注入面。
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

    private static func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
