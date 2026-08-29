import AppKit
import Foundation
import NewPiCore
import SwiftUI
import WebKit

/// UI 架构 Spike：单文档 transcript 的性能验证（docs/ui-architecture-decision.md §4.2）。
/// 一次性工具，不接入任何生产路径；入口：菜单 Help → UI Architecture Spike。
///
/// 测量四项（go/no-go 判定标准见决策文档）：
///   M1 冷挂载到首屏可读耗时（cold = markdown 全量渲染；replay = 预渲染 HTML 直出，模拟产物重放）
///   M2 模拟流式期间每帧渲染耗时（尾块全量重渲染，是生产 renderStreaming 块级增量的保守上界）
///   M3 子进程常驻内存增量（WebContent/Networking/GPU，phys_footprint 求和）
///   M4 全程滚动流畅度（rAF 驱动匀速扫滚，统计掉帧率）
/// WebKit 的 WebContent/Networking/GPU 进程由 launchd 孵化（ppid=1，非本 App 子进程），
/// 只能靠 responsibility 归属过滤。该 API 无公开头文件但符号公开导出（top/powermetrics 同款），
/// 注意它直接**返回** responsible pid（不是错误码）。
/// SPIKE-ONLY：仅限本调试工具，不得进入任何生产路径 / App Store 构建。
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func _responsiblePID(_ pid: pid_t) -> pid_t

@MainActor
final class NewPiSpikeModel: ObservableObject {
    struct Turn: Encodable {
        var user: String
        var thinking: String
        var tools: [String]
        var answer: String
    }

    @Published var turnCount = 200
    @Published var isBusy = false
    @Published var report = "Ready. 建议顺序：Cold Load → Replay Load → Stream → Scroll Sweep。\n"

    /// 自动跑完整序列（NEWPI_SPIKE_AUTORUN=1 启动时）：cold → replay → stream → scroll。
    static let autorun = ProcessInfo.processInfo.environment["NEWPI_SPIKE_AUTORUN"] == "1"
    /// 自动模式已启动标记（onAppear 可能重复触发）。
    private var autorunStarted = false
    /// 自动模式进度：0=cold 已发，1=replay 已发，2=stream 已发，3=scroll 已发。
    private var autorunStage = 0
    /// 基线内存（空 WebView 挂载后采样），用于计算 M3 增量。
    private var baselineFootprint: UInt64 = 0

    private weak var webView: WKWebView?
    private var turns: [Turn] = []

    func attach(_ webView: WKWebView) {
        self.webView = webView
        if let turnsEnv = ProcessInfo.processInfo.environment["NEWPI_SPIKE_TURNS"],
           let n = Int(turnsEnv), n > 0 {
            turnCount = n
        }
        // 等首屏空文档布局稳定后采基线。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.baselineFootprint = Self.childProcessesFootprint()
            self?.log("M3 baseline: \(Self.formatBytes(self?.baselineFootprint ?? 0))（空 WebView）")
        }
    }

    /// 自动模式入口（视图 onAppear 调用）。延迟 2.5s 启动：等基线内存采样完成。
    func startAutorunIfNeeded() {
        guard Self.autorun, !autorunStarted else { return }
        autorunStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.load(mode: "cold")
        }
    }

    /// 自动模式链式推进：上一步的结果回传后启动下一步。
    private func advanceAutorun() {
        guard Self.autorun, autorunStarted else { return }
        autorunStage += 1
        switch autorunStage {
        case 1: load(mode: "replay")
        case 2: startStreaming()
        case 3: scrollSweep()
        default:
            log("=== SPIKE DONE ===")
        }
    }

    // MARK: - 合成数据

    /// 生成贴近 coding agent 真实分布的合成会话：短提问 + 思考 + 1~4 张工具卡 + 代码密集型回答。
    private func generateTurns(_ count: Int) -> [Turn] {
        let questions = [
            "修复 markdown 渲染时高度抖动的问题",
            "把 session 列表改成按项目分组，并按最近使用排序",
            "解释一下 heightMap 的窗口化逻辑有没有并发问题",
            "给工具调用失败时加重试按钮",
        ]
        let thinkings = [
            "先定位问题：高度上报走 ResizeObserver，\n疑点在于流式量化步进与最终高度不一致。\n需要看 flush 路径。",
            "用户要的是分组 + 排序。\n涉及 UI 结构与持久化两层，先改 model。",
            "这是一个并发问题，需要仔细看 task 的生命周期。\n考虑 generation 校验。",
        ]
        let toolOutputs = [
            """
            1|import SwiftUI
            2|
            3|struct TranscriptView: View {
            4|    var body: some View {
            5|        ScrollView {
            6|            LazyVStack { /* … */ }
            7|        }
            8|    }
            9|}
            """,
            """
            $ swift test --filter HeightMapTests
            Test Suite 'HeightMapTests' started
            ✓ testPrefixSums (0.002s)
            ✓ testAnchorLookup (0.001s)
            ✓ testWindowRange (0.003s)
            [exit 0]
            """,
            """
            diff --git a/file.swift b/file.swift
            @@ -10,7 +10,7 @@
            -    let height = estimate(row)
            +    let height = measured(row) ?? estimate(row)
            """,
        ]
        let answers = [
            """
            问题定位到了：流式期间高度上报被量化到 160pt 步进，而 flush 时直接落精确高度，
            两条路径在缓存里互相覆盖。修复方式是统一入口：

            ```swift
            func setHeight(_ height: CGFloat, for key: String) {
                guard height > 0 else { return }
                entries[key] = Entry(height: height, at: Date())
            }
            ```

            另外两处调用点也要对齐：

            - 预热器的探针写入
            - WebView 的 ResizeObserver 上报

            这样冷启动首帧就能直接命中真实高度。
            """,
            """
            改动分三层：

            1. **Model**：`SessionSummary` 增加 `lastUsedAt`，列表按它降序
            2. **持久化**：写入 `~/.new-pi/agent/sessions-index.json`
            3. **UI**：`Section` 按项目分组

            | 方案 | 优点 | 缺点 |
            |---|---|---|
            | 内存排序 | 简单 | 重启丢失 |
            | 索引文件 | 跨启动稳定 | 多一次 IO |

            推荐方案二，成本可控。
            """,
            """
            看了下实现，这里的竞态是这样的：`preheat` 启动的后台 task 持有旧的 generation，
            而 `cancel` 只取消任务、不清引用，新一代启动时旧 task 的收尾会把新引用清掉。

            ```python
            # 类似结构的伪代码
            if generation == self.generation:
                self.task = None  # 只有同代才允许清
            ```

            修复就是收尾前校验 generation，这个模式在 session 切换那里已经用过了。
            """,
        ]

        return (0..<count).map { i in
            let toolCount = 1 + i % 4
            return Turn(
                user: questions[i % questions.count],
                thinking: thinkings[i % thinkings.count],
                tools: (0..<toolCount).map { toolOutputs[($0 + i) % toolOutputs.count] },
                answer: answers[i % answers.count] + (i % 3 == 0 ? "\n\n" + answers[(i + 1) % answers.count] : "")
            )
        }
    }

    // MARK: - 测量动作

    func load(mode: String) {
        guard let webView, !isBusy else { return }
        isBusy = true
        turns = generateTurns(turnCount)
        log("---\nLoad (\(mode))：\(turnCount) turns，开始…")
        guard let data = try? JSONEncoder().encode(turns),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.spikeLoad(\(jsonLiteral(json)), \(jsonLiteral(mode)));"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error { self?.log("load 调用失败：\(error.localizedDescription)") }
        }
    }

    /// 模拟流式：尾部挂一个新 turn，长回答（含代码块）按 50ms 节奏流入，尾块全量重渲染。
    /// 注意这是生产 renderStreaming 块级增量的**保守上界**——它过关则生产实现必过关。
    func startStreaming() {
        guard let webView, !isBusy else { return }
        isBusy = true
        let answer = String(repeating: """
        正在分析这个问题。先给出结论，然后展开细节：

        ```swift
        final class ScrollCoordinator {
            private var intent: Intent = .idle
            func request(_ newIntent: Intent) {
                guard newIntent.priority > intent.priority else { return }
                intent = newIntent
            }
        }
        ```

        关键点是**同一时刻只有一个写入者**。具体来说：

        - 用户滚动取消所有 pending 动画
        - 流式跟随只在原本位于底部时生效
        - 恢复锚点期间禁止钉底

        """, count: 4)
        log("---\nStream：模拟流式回答（\(answer.count) 字符，50ms 节流）…")
        webView.evaluateJavaScript("window.spikeStream(\(jsonLiteral(answer)));") { [weak self] _, error in
            if let error { self?.log("stream 调用失败：\(error.localizedDescription)") }
        }
    }

    func scrollSweep() {
        guard let webView, !isBusy else { return }
        isBusy = true
        log("---\nScroll Sweep：6s 匀速全程滚动…")
        webView.evaluateJavaScript("window.spikeScrollSweep(6000);") { [weak self] _, error in
            if let error { self?.log("scroll 调用失败：\(error.localizedDescription)") }
        }
    }

    func sampleMemory(tag: String) {
        let now = Self.childProcessesFootprint()
        let delta = now > baselineFootprint ? now - baselineFootprint : 0
        log("M3 [\(tag)]: \(Self.formatBytes(now))（Δ 基线 +\(Self.formatBytes(delta))） [\(Self.lastSampleDiagnostics)]")
    }

    // MARK: - JS 回传

    fileprivate func handleMessage(_ body: [String: Any]) {
        isBusy = false
        guard let event = body["event"] as? String else { return }
        switch event {
        case "load":
            let ms = body["ms"] as? Double ?? 0
            let mode = body["mode"] as? String ?? "?"
            let nodes = body["nodes"] as? Int ?? 0
            let height = body["height"] as? Double ?? 0
            log(String(format: "M1 [\(mode)] 首屏可读：%.0f ms；DOM 节点 %d；文档高 %.0f px", ms, nodes, height))
            sampleMemory(tag: "after \(mode) load")
        case "stream":
            let p50 = body["p50"] as? Double ?? 0
            let p95 = body["p95"] as? Double ?? 0
            let max = body["max"] as? Double ?? 0
            let fps = body["fps"] as? Double ?? 0
            log(String(format: "M2 流式每帧渲染：p50 %.1f / p95 %.1f / max %.1f ms（目标 <8）；期间 fps %.0f", p50, p95, max, fps))
            sampleMemory(tag: "after stream")
        case "scroll":
            let fps = body["fps"] as? Double ?? 0
            let jank = body["jankPercent"] as? Double ?? 0
            log(String(format: "M4 全程滚动：fps %.0f，掉帧率 %.1f%%", fps, jank))
        default:
            break
        }
        NewPiLogger.info(category: "app", message: "UI spike \(event)", details: "\(body)")
        advanceAutorun()
    }

    private func log(_ line: String) {
        report += line + "\n"
        // autorun 时同时落文件（stdout 走管道会块缓冲，超时 kill 会丢输出）。
        if Self.autorun {
            let url = URL(fileURLWithPath: "/tmp/newpi-spike-\(turnCount).log")
            let data = (line + "\n").data(using: .utf8)!
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - 内存采样（WebKit 子进程 phys_footprint 求和）

    static func childProcessesFootprint() -> UInt64 {
        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let selfPID = getpid()
        // responsibility 沿启动链传播：从 Finder 启动时归本 App；从终端启动时归终端 App（实测）。
        // 两者都接受——spike 是受控环境，同终端同时跑另一个 WebKit App 的概率可忽略。
        let selfResponsible = _responsiblePID(selfPID)
        var total: UInt64 = 0
        var webkitSeen = 0, matched = 0
        for i in 0..<max(0, count) {
            let pid = pids[i]
            guard pid > 0, pid != selfPID else { continue }
            // pbi_comm 截断到 15 字符，装不下 "com.apple.WebKit.*"——用全路径判断。
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 else { continue }
            guard String(cString: pathBuf).contains("com.apple.WebKit") else { continue }
            webkitSeen += 1
            let responsible = _responsiblePID(pid)
            guard responsible == selfPID || responsible == selfResponsible else { continue }
            matched += 1
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            guard status == 0 else { continue }
            total += UInt64(usage.ri_phys_footprint)
        }
        lastSampleDiagnostics = "webkit=\(webkitSeen) matched=\(matched) self=\(selfPID) respSelf=\(selfResponsible)"
        return total
    }

    /// 最近一次采样的诊断信息（进程计数），随 M3 日志输出，便于排查归因失败。
    private(set) static var lastSampleDiagnostics = ""

    static func formatBytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// 与生产一致的双重 JSON 编码：防止内容里的 </script> 等字符破坏 JS 字符串边界。
    private func jsonLiteral(_ string: String) -> String {
        guard let inner = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
              let innerString = String(data: inner, encoding: .utf8) else { return "\"\"" }
        return innerString.replacingOccurrences(of: "</", with: "<\\/")
    }
}

// MARK: - Spike WebView

private struct NewPiSpikeWebView: NSViewRepresentable {
    let model: NewPiSpikeModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "spike")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(Self.pageHTML(), baseURL: NewPiMarkdownWebDocument.rendererDirectoryURL())
        model.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let model: NewPiSpikeModel
        init(model: NewPiSpikeModel) { self.model = model }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            model.handleMessage(body)
        }
    }

    /// Spike 页面：与生产相同的本地资源与 CSP 结构，仅 style-src 放宽 nonce 以容纳
    /// spike 专属样式（content-visibility 等；合成数据、无不可信内容）。
    private static func pageHTML() -> String {
        let nonce = NewPiMarkdownWebDocument.scriptNonce
        let dir = NewPiMarkdownWebDocument.rendererDirectoryURL()?.absoluteString ?? ""
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'self' file: 'nonce-\(nonce)'; script-src 'self' file: 'nonce-\(nonce)'; connect-src 'none'">
          <link rel="stylesheet" href="\(dir)github-markdown-light.css">
          <link rel="stylesheet" href="\(dir)highlight-github.min.css">
          <link rel="stylesheet" href="\(dir)markdown-renderer.css">
          <style nonce="\(nonce)">
            body { margin: 0; padding: 16px; font: 13px/1.5 -apple-system, sans-serif; }
            /* 单文档虚拟化核心：视口外的 turn 跳过布局/绘制，900px 为高度预留 */
            section.turn { content-visibility: auto; contain-intrinsic-size: auto 900px;
                           margin-bottom: 24px; }
            .spike-user { background: rgba(0,112,255,0.12); border-radius: 14px; padding: 12px;
                          max-width: 640px; margin-left: auto; }
            .spike-thinking, .spike-tool { background: rgba(120,120,128,0.10); border-radius: 12px;
                          padding: 8px 12px; margin: 8px 0; max-width: 640px;
                          font: 12px/1.4 ui-monospace, monospace; white-space: pre-wrap;
                          color: rgba(60,60,67,0.85); }
            .spike-thinking::before { content: "🧠 Thinking"; display: block; font-weight: 600;
                          font-size: 11px; color: purple; margin-bottom: 4px; }
            .spike-tool::before { content: "🔧 Tool"; display: block; font-weight: 600;
                          font-size: 11px; color: gray; margin-bottom: 4px; }
            article.spike-answer { max-width: 760px; }
          </style>
        </head>
        <body>
          <main id="transcript"></main>
          <script src="\(dir)markdown-it.min.js"></script>
          <script src="\(dir)highlight.min.js"></script>
          <script nonce="\(nonce)">\(spikeJS)</script>
        </body>
        </html>
        """
    }

    /// Spike 脚本。M2 刻意用尾块全量重渲染（生产 renderStreaming 的块级增量只会更快）。
    private static let spikeJS = #"""
    (function () {
      "use strict";
      const md = window.markdownit({
        html: false, linkify: true, typographer: true, breaks: true,
        highlight: function (source, language) {
          if (language && window.hljs && window.hljs.getLanguage(language)) {
            try {
              return '<pre class="hljs"><code>' +
                window.hljs.highlight(source, { language: language, ignoreIllegals: true }).value +
                "</code></pre>";
            } catch (_) {}
          }
          return '<pre class="hljs"><code>' + md.utils.escapeHtml(source) + "</code></pre>";
        }
      });
      const main = document.getElementById("transcript");
      let prerenderedHTML = null;

      function esc(s) { return md.utils.escapeHtml(s); }

      function turnHTML(t) {
        let html = '<section class="turn">';
        html += '<div class="spike-user">' + esc(t.user) + "</div>";
        if (t.thinking) html += '<div class="spike-thinking">' + esc(t.thinking) + "</div>";
        for (const tool of t.tools) html += '<div class="spike-tool">' + esc(tool) + "</div>";
        html += '<article class="markdown-body spike-answer">' + md.render(t.answer) + "</article>";
        return html + "</section>";
      }

      function post(payload) {
        window.webkit.messageHandlers.spike.postMessage(payload);
      }

      // 等两帧：innerHTML 写入后让布局/绘制真正发生，再计时（≈ 首屏可读）。
      function afterPaint(cb) {
        requestAnimationFrame(function () { requestAnimationFrame(cb); });
      }

      window.spikeLoad = function (turnsJSON, mode) {
        const turns = JSON.parse(turnsJSON);
        const t0 = performance.now();
        if (mode === "replay" && prerenderedHTML) {
          main.innerHTML = prerenderedHTML;
        } else {
          let html = "";
          for (const t of turns) html += turnHTML(t);
          main.innerHTML = html;
          prerenderedHTML = main.innerHTML;
        }
        afterPaint(function () {
          post({ event: "load", mode: mode, ms: performance.now() - t0,
                 nodes: document.querySelectorAll("*").length, height: main.scrollHeight });
        });
      };

      window.spikeStream = function (answerSource) {
        main.insertAdjacentHTML("beforeend",
          '<section class="turn" style="content-visibility:visible">' +
          '<div class="spike-user">模拟流式提问</div>' +
          '<article class="markdown-body spike-answer" id="spike-tail"></article></section>');
        const tail = document.getElementById("spike-tail");
        tail.scrollIntoView();
        const total = answerSource.length;
        const step = Math.max(8, Math.ceil(total / 300)); // ~300 次 50ms 脉冲 ≈ 15s
        const samples = [];
        let shown = 0, frames = 0, rafStart = performance.now();
        function countFrame() { frames += 1; if (shown < total) requestAnimationFrame(countFrame); }
        requestAnimationFrame(countFrame);
        const timer = setInterval(function () {
          shown = Math.min(total, shown + step);
          const s0 = performance.now();
          tail.innerHTML = md.render(answerSource.slice(0, shown)); // 保守上界：全量重渲染尾块
          samples.push(performance.now() - s0);
          if (shown >= total) {
            clearInterval(timer);
            samples.sort(function (a, b) { return a - b; });
            const pick = function (q) { return samples[Math.min(samples.length - 1, Math.floor(q * samples.length))]; };
            const elapsed = performance.now() - rafStart;
            post({ event: "stream", p50: pick(0.5), p95: pick(0.95),
                   max: samples[samples.length - 1], fps: frames / (elapsed / 1000) });
          }
        }, 50);
      };

      window.spikeScrollSweep = function (durationMs) {
        const maxScroll = main.scrollHeight - window.innerHeight;
        if (maxScroll <= 0) { post({ event: "scroll", fps: 0, jankPercent: 0 }); return; }
        window.scrollTo(0, 0);
        const t0 = performance.now();
        let frames = 0, jank = 0, last = t0;
        function stepFrame(now) {
          frames += 1;
          if (now - last > 34) jank += 1; // 掉帧：帧间隔 > ~2 帧预算
          last = now;
          const progress = Math.min(1, (now - t0) / durationMs);
          window.scrollTo(0, maxScroll * progress);
          if (progress < 1) { requestAnimationFrame(stepFrame); }
          else {
            const elapsed = (now - t0) / 1000;
            post({ event: "scroll", fps: frames / elapsed, jankPercent: 100 * jank / frames });
          }
        }
        requestAnimationFrame(stepFrame);
      };
    }());
    """#
}

// MARK: - Spike 窗口内容

struct NewPiSpikeTranscriptView: View {
    @StateObject private var model = NewPiSpikeModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("单文档 Spike").font(.headline)
                Picker("Turns", selection: $model.turnCount) {
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
                .pickerStyle(.segmented)

                Button("1. Cold Load（markdown 全渲染）") { model.load(mode: "cold") }
                Button("2. Replay Load（预渲染直出）") { model.load(mode: "replay") }
                Button("3. Stream（模拟流式）") { model.startStreaming() }
                Button("4. Scroll Sweep（全程滚动）") { model.scrollSweep() }
                Button("采样内存") { model.sampleMemory(tag: "manual") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(model.isBusy)

                ScrollView {
                    Text(model.report)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .frame(width: 300)
            .disabled(model.isBusy && false)

            Divider()
            NewPiSpikeWebView(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.startAutorunIfNeeded() }
    }
}
