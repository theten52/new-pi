import AppKit
import Foundation
import NewPiCore
import os
import SwiftUI
import WebKit

// 真实 SwiftUI/Coordinator/JS；只使用合成正文，不联网、不写用户指标或会话。
actor LLMMetricsRecorder {
    static let shared = LLMMetricsRecorder()
    private var dom: [Double] = []
    func record(_ metric: UITranscriptDiffMetric) {}
    func record(_ metric: UIDomApplyMetric) { dom.append(metric.duration * 1000) }
    func takeDOM() -> [Double] { defer { dom = [] }; return dom }
}

enum NewPiLogger {
    static func info(category: String, message: String, details: String) {}
    static func error(category: String, message: String, details: String? = nil) {
        print("Coordinator: \(message) \(details ?? "")")
    }
}

@MainActor
final class PresentationModel: ObservableObject {
    @Published var items: [NewPiTranscriptItem] = (0..<50).map { i in
        NewPiTranscriptItem(kind: i.isMultiple(of: 2) ? .user : .assistant,
            body: i.isMultiple(of: 2) ? "History \(i)" :
                "## History \(i)\n\n" + String(repeating: "历史正文 History content. ", count: 100)
                    + "\n\n```swift\nlet value = \(i)\n```")
    }
    @Published var running = false
    @Published var tick = 0
    @Published var confettiTrigger = 0
    let controller = TranscriptDocumentController()
}

private struct PresentationRoot: View {
    @ObservedObject var model: PresentationModel
    @ObservedObject var controller: TranscriptDocumentController
    @State private var draft = "Preserve this draft"

    var body: some View {
        NavigationSplitView {
            List(0..<30) { index in Text("Session \(index)") }
                .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    NewPiTranscriptDocumentView(
                        transcript: model.items, isStreaming: model.running,
                        streamingBubbleComplete: !model.running, storeKey: nil, controller: controller)
                        .overlay(alignment: .bottom) {
                            Button("Jump to latest") { controller.scrollToBottom() }
                                .padding(12)
                                .background(.regularMaterial, in: Capsule())
                                .opacity(model.running && !controller.isNearBottom ? 1 : 0)
                        }
                    NewPiUserMessageRail(
                        markers: model.items.filter(\.isUser).map { UserMessageMarker(id: $0.id, preview: $0.body) },
                        positions: controller.markerPositions, onSelect: controller.jumpTo)
                        .padding(.trailing, 10)
                }
                NewPiAgentStatusBar(
                    presentation: NewPiAgentStatusPresentation(
                        systemImage: model.running ? "text.append" : "checkmark.circle",
                        label: model.running ? "Writing" : "Ready", isActive: model.running),
                    tokenRateText: "Tick \(model.tick)")
                    .padding(10)
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder).padding(12)
            }
            .overlay(alignment: .bottomTrailing) { NewPiConfettiBurstView(trigger: model.confettiTrigger) }
        }
    }
}

@main
struct TranscriptPresentationChecks {
    struct Failure: Error { let message: String }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+90) {
            print("FAIL: presentation timeout"); exit(1)
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let previouslyActive = NSWorkspace.shared.frontmostApplication
        let model = PresentationModel()
        let host = NSHostingController(rootView: PresentationRoot(model: model, controller: model.controller))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 1100, height: 780),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        let hostView = host.view
        window.title = "NewPi synthetic 200-line presentation replay"
        window.setContentSize(NSSize(width: 1100, height: 780))
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            previouslyActive?.activate(options: [])
        }
        var loadedWebView: WKWebView?
        for _ in 0..<200 {
            if let webView = findWebView(hostView), !webView.isLoading {
                let count = try await webView.evaluateJavaScript("document.querySelectorAll('.ti').length") as? Int
                if count == model.items.count { loadedWebView = webView; break }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let webView = loadedWebView else { throw Failure(message: "Document did not load") }
        try await Task.sleep(for: .seconds(3))
        report("REPLAY READY pid=\(ProcessInfo.processInfo.processIdentifier) viewport=\(webView.frame) visible=\(window.occlusionState.contains(.visible))")
        guard webView.frame.height > 500, window.occlusionState.contains(.visible) else {
            throw Failure(message: "Replay requires a visible full-size window")
        }
        var sampler: Process?
        if let output = ProcessInfo.processInfo.environment["NEWPI_PRESENTATION_SAMPLE"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "20", "2", "-file", output]
            try process.run()
            sampler = process
        }
        defer { if let sampler, sampler.isRunning { sampler.terminate() } }
        for turn in 1...3 {
            let id = UUID()
            model.items.append(NewPiTranscriptItem(kind: .user, body: "Print 200 lines, turn \(turn)"))
            model.items.append(NewPiTranscriptItem(id: id, kind: .assistant, body: "```text\n"))
            model.running = true
            var latest = model.items
            let body = "```text\n" + (1...200).map { index in
                String(format: "%03d", index) + " 这是用于检查连续输出与原生呈现的测试文本。abcdef\n"
            }.joined() + "```"
            let chunks = body.split(separator: "\n", omittingEmptySubsequences: false)
            let progress = OSAllocatedUnfairLock(initialState: 0)
            let producer = Task.detached {
                for index in 1...chunks.count {
                    progress.withLock { $0 = index }
                    try await Task.sleep(for: .milliseconds(45))
                }
                return ContinuousClock.now
            }
            var lags: [Double] = []
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    let expected = ContinuousClock.now.advanced(by: .milliseconds(100))
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    lags.append(max(0, milliseconds(expected.duration(to: .now))))
                }
            }
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    model.tick += 1
                }
            }
            defer { heartbeat.cancel(); ticker.cancel(); producer.cancel() }
            _ = await LLMMetricsRecorder.shared.takeDOM()
            let start = ContinuousClock.now
            var applied = 0
            var dispatches = 0
            while applied < chunks.count {
                let available = progress.withLock { $0 }
                if available > applied {
                    applied = available
                    latest[latest.count-1] = NewPiTranscriptItem(id: id, kind: .assistant,
                        body: chunks.prefix(available).joined(separator: "\n"))
                    model.controller.applyLive(items: latest, isStreaming: true,
                        streamingBubbleComplete: false, tintHues: [:])
                    dispatches += 1
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            let producedAt = try await producer.value
            report("turn=\(turn) produced/consumed dispatches=\(dispatches)")
            latest[latest.count-1] = NewPiTranscriptItem(id: id, kind: .assistant, body: body)
            model.controller.applyLive(items: latest, isStreaming: false, streamingBubbleComplete: true, tintHues: [:])
            model.items = latest
            model.running = false
            model.confettiTrigger += 1
            model.controller.endLiveApply()
            let complete = try await webView.callAsyncJavaScript("""
                await new Promise((resolve,reject)=>{
                  const timeout=setTimeout(()=>reject(new Error('No animation frame in visible replay')),3000);
                  requestAnimationFrame(()=>requestAnimationFrame(()=>{clearTimeout(timeout);resolve();}));
                });
                return document.querySelector('main').lastElementChild.querySelector('pre code').textContent === expected;
                """, arguments: ["expected": chunks.dropFirst().dropLast().joined(separator: "\n") + "\n"],
                in: nil, contentWorld: .page) as? Bool
            guard complete == true else { throw Failure(message: "Final 200-line content mismatch") }
            let end = ContinuousClock.now
            try await Task.sleep(for: .seconds(2))
            heartbeat.cancel()
            ticker.cancel()
            let dom = await LLMMetricsRecorder.shared.takeDOM()
            print(String(format: "turn=%d wall=%.2fs afterProducer=%.1fms dispatches=%d maxMainActorLag=%.1fms lagP95=%.1fms domTotal=%.1fms domMax=%.1fms",
                turn, milliseconds(start.duration(to: end))/1000,
                milliseconds(producedAt.duration(to: end)), dispatches, lags.max() ?? 0,
                percentile(lags, 0.95), dom.reduce(0,+), dom.max() ?? 0))
            if ProcessInfo.processInfo.environment["NEWPI_EXPECT_RESPONSIVE_PRESENTATION"] == "1",
               (lags.max() ?? 0) > 500 {
                throw Failure(message: "MainActor unavailable for more than 500ms")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    @MainActor private static func findWebView(_ view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews { if let found = findWebView(child) { return found } }
        return nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[Int(Double(values.count-1)*fraction)]
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
