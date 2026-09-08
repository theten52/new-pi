import AppKit
import WebKit

/// 加载真实 JS/CSS 的 WKWebView 检查，不发送模型请求、不触碰用户会话。
@MainActor
final class TranscriptStreamingDOMChecks: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
    }

    func run() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("NewPiApp/MarkdownRenderer")
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("renderer"))
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="renderer/github-markdown-light.css">
        <link rel="stylesheet" href="renderer/highlight-github.min.css">
        <link rel="stylesheet" href="renderer/markdown-renderer.css">
        <link rel="stylesheet" href="renderer/transcript-document.css">
        </head><body><main id="transcript"></main>
        <script src="renderer/markdown-it.min.js"></script><script src="renderer/highlight.min.js"></script>
        <script src="renderer/markdown-renderer.js"></script><script src="renderer/transcript-document.js"></script>
        </body></html>
        """
        let file = root.appendingPathComponent("index.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        NSApp.setActivationPolicy(.accessory)
        window.orderBack(nil)
        webView.loadFileURL(file, allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        const apply = ops => window.transcriptDoc.apply(JSON.stringify(ops));
        const check = (condition, name) => { if (!condition) throw new Error(name); };
        const node = id => document.querySelector(`[data-iid="${id}"]`);
        // 产品已关闭正文 ✦ 光标；检查真实渲染函数调用，不依赖光标是否存在。
        const renders = {streaming:0, final:0};
        const originalCreate = window.createMarkdownRenderer;
        window.createMarkdownRenderer = (...args) => {
          const renderer = originalCreate(...args);
          const stream = renderer.renderStreaming.bind(renderer), final = renderer.renderFinal.bind(renderer);
          renderer.renderStreaming = body => { renders.streaming++; return stream(body); };
          renderer.renderFinal = body => { renders.final++; return final(body); };
          return renderer;
        };
        apply([
          {op:'reset'}, {op:'forkLock',locked:true},
          {op:'upsert',id:'group',kind:'detailGroup',detailTurnID:'speech',collapsed:false,body:''},
          {op:'upsert',id:'thinking',kind:'thinking',detailTurnID:'speech',body:'Reasoning',streaming:true},
          {op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph',streaming:true},
          {op:'upsert',id:'user',kind:'user',body:'User steering',streaming:false}
        ]);
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        const answer = node('answer');
        check(renders.streaming === 1 && renders.final === 0, 'non-last assistant must stream');
        check(!node('thinking').classList.contains('detail-hidden'), 'steering must not collapse active group');
        node('thinking').querySelector('.card-hd').click();
        apply([
          {op:'upsert',id:'thinking',kind:'thinking',detailTurnID:'speech',body:'Reasoning finished',streaming:false},
          {op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph grows\n\n```swift\nlet x = 1',streaming:true}
        ]);
        check(node('answer') === answer, 'assistant DOM must retain identity');
        check(renders.streaming === 2 && renders.final === 0, 'subsequent update must remain streaming');
        check(node('thinking').querySelector('.card').classList.contains('expanded'), 'manual expansion must persist');
        apply([{op:'upsert',id:'answer',kind:'assistant',speaker:'Role A',body:'A paragraph grows\n\n```swift\nlet x = 1\n```',streaming:false}]);
        check(renders.final === 1, 'message end must freeze before run ends');
        check(!answer.querySelector('.streaming-caret'), 'must not reintroduce disabled caret');
        check(answer.style.height === '', 'message end must release stepped height');
        check(!!answer.querySelector('pre code'), 'final markdown must retain code block');
        check(node('user').textContent.includes('User steering'), 'user steering must not disappear');
        apply([{op:'forkLock',locked:false}]);
        return 'PASS: WKWebView non-last streaming, stable DOM, thinking expansion, message finalization, steering retained';
        """#
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                print(result ?? "missing result")
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("FAIL: \(error)"); exit(1)
    }
}

@main
struct Runner {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let runner = TranscriptStreamingDOMChecks(root: root)
        try runner.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("FAIL: WebView test timeout"); exit(1) }
        withExtendedLifetime(runner) { NSApp.run() }
    }
}
