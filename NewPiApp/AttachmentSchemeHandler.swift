import Foundation
import NewPiCore
import WebKit

/// 附件图片的受控本地读取通道（BACKLOG-IMAGE-INPUT；docs/multi-modal-vision-plan.md §5.4/§6.3）。
///
/// WKWebView 不能（也不应）直接访问任意本地文件；JS 侧以 `pi-att://att/<相对附件路径>`
/// 引用图片，由本 handler 经 `SessionAttachments.resolve` 读取（强制限定在附件根目录内、
/// 标准化后仍在外则拒绝，阻断 `../` 穿越），渲染层因此不存在任意本地文件读取面。
/// CSP 相应放行 `img-src pi-att:`（见 NewPiMarkdownWebDocument）。
final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pi-att"

    /// 附件相对路径 → `pi-att://att/<percent-encoded>` 图片 src（原生侧构造 op 时使用）。
    static func imageURL(forRelativePath relativePath: String) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "att"
        components.path = "/" + relativePath
        return components.url?.absoluteString
    }

    // MARK: - WKURLSchemeHandler

    // 附件体积上限 5MB（ImageAttachmentProcessor.maxAttachmentBytes），本地读盘毫秒级，
    // 直接同步回填：start/stop 均在主线程调用，同步执行期间不存在被 stop 后再回调的窗口
    //（也避免了 WKURLSchemeTask 非 Sendable 在 Swift 6 严格并发下跨域捕获的问题）。
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url
        guard let payload = Self.loadPayload(for: url) else {
            task.didFailWithError(
                NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorFileDoesNotExist,
                    userInfo: [NSLocalizedDescriptionKey: "附件不可读：路径非法或文件缺失"]
                )
            )
            return
        }
        let response = HTTPURLResponse(
            url: url ?? URL(string: "\(Self.scheme)://att/missing")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": payload.mimeType,
                "Content-Length": String(payload.data.count),
            ]
        )
        guard let response else {
            task.didFailWithError(
                NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorBadURL,
                    userInfo: [NSLocalizedDescriptionKey: "附件 URL 非法"]
                )
            )
            return
        }
        task.didReceive(response)
        task.didReceive(payload.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 同步实现无需处理：见 start 的注释。
    }

    // MARK: - 受控读取（唯一边界：SessionAttachments.resolve）

    private static func loadPayload(for url: URL?) -> (data: Data, mimeType: String)? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == "att" else { return nil }
        let relativePath = String(components.path.drop(while: { $0 == "/" }))
        guard !relativePath.isEmpty else { return nil }
        guard let fileURL = SessionAttachments.resolve(relativePath: relativePath),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return (data, mimeType(forExtension: fileURL.pathExtension))
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }
}
