import NewPiCore
import SwiftUI

/// 可直接放入 header；状态与任务不依赖会话或审批模型。
struct NewPiChangesButton: View {
    let directory: URL?
    var refreshToken: Int = 0
    @StateObject private var model = NewPiChangesModel()

    var body: some View {
        Button {
            model.isPresented = true
            model.refreshNow()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text("改动")
                switch model.phase {
                case .ready:
                    Text("\(model.snapshot?.files.count ?? 0)").monospacedDigit()
                case .loading:
                    ProgressView().controlSize(.mini)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                case .notGit:
                    Text("非 Git").font(.caption)
                case .noDirectory:
                    Text("—")
                }
            }
        }
        .help("查看整个 Git 工作区的改动；只读。\(model.phaseDescription)")
        .accessibilityLabel("改动，\(model.phaseDescription)")
        .sheet(isPresented: $model.isPresented) {
            NewPiChangesPanelContent(model: model)
        }
        .task(id: directory) { model.setDirectory(directory) }
        .onChange(of: refreshToken) { _, _ in model.requestRefresh() }
        .onChange(of: model.isPresented) { _, presented in
            if !presented { model.cancelDetail() }
        }
        .onDisappear { model.stop() }
    }
}

/// 独立嵌入或作为 sheet 使用；与按钮共用面板布局，不需要审批调用。
struct NewPiChangesPanel: View {
    let directory: URL?
    var refreshToken: Int = 0
    @StateObject private var model = NewPiChangesModel()

    var body: some View {
        NewPiChangesPanelContent(model: model)
            .task(id: directory) {
                model.isPresented = true
                model.setDirectory(directory)
            }
            .onChange(of: refreshToken) { _, _ in model.requestRefresh() }
            .onDisappear { model.stop() }
    }
}

typealias NewPiChangesSheet = NewPiChangesPanel

@MainActor
private final class NewPiChangesModel: ObservableObject {
    enum Phase { case noDirectory, loading, ready, notGit, failed(String) }
    enum Detail { case idle, loading, ready(WorkspaceFileDiff), failed(String) }

    @Published var phase: Phase = .noDirectory
    @Published var snapshot: WorkspaceChangesSnapshot?
    @Published var selectedPath: String?
    @Published var area: WorkspaceDiffArea = .unstaged
    @Published var detail: Detail = .idle
    @Published var isPresented = false
    private var directory: URL?
    private var configured = false
    private var generation = UUID()
    private var detailGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var lastRefreshStart = ContinuousClock.now - .seconds(3)
    private let reader = WorkspaceChangesReader()

    var phaseDescription: String {
        switch phase {
        case .noDirectory: "未选择工作目录"
        case .loading: "正在读取，文件数未知"
        case .ready: "\(snapshot?.files.count ?? 0) 个文件（最近一次完整读取）"
        case .notGit: "非 Git 工作区"
        case .failed(let message): message
        }
    }

    var selectedFile: WorkspaceChangedFile? { snapshot?.files.first { $0.path == selectedPath } }
    var areas: [WorkspaceDiffArea] {
        guard let file = selectedFile else { return [] }
        if file.isUntracked { return [.untracked] }
        return (file.hasStagedChanges ? [.staged] : []) + (file.hasUnstagedChanges ? [.unstaged] : [])
    }

    func setDirectory(_ value: URL?) {
        guard !configured || value != directory else { return }
        stop()
        configured = true
        directory = value
        snapshot = nil
        selectedPath = nil
        lastRefreshStart = .now - .seconds(3)
        guard value != nil else { phase = .noDirectory; return }
        phase = .loading
        schedule(immediate: true)
    }

    func requestRefresh() { schedule(immediate: false) }
    func refreshNow() { schedule(immediate: true) }

    /// 合并流式 token 通知，自动刷新至多每三秒一次；保留尾随刷新而不逐 token 调 Git。
    private func schedule(immediate: Bool) {
        guard let directory else { return }
        if refreshTask != nil { pendingRefresh = true; return }
        let current = generation
        let earliest = immediate ? ContinuousClock.now : max(.now + .milliseconds(400), lastRefreshStart + .seconds(3))
        refreshTask = Task { [weak self, reader] in
            do {
                try await ContinuousClock().sleep(until: earliest)
                guard let self, self.generation == current else { return }
                self.pendingRefresh = false
                self.phase = .loading
                self.lastRefreshStart = .now
                let snapshot = try await reader.changes(in: directory)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                self.snapshot = snapshot
                self.phase = .ready
                if !snapshot.files.contains(where: { $0.path == self.selectedPath }) {
                    self.selectedPath = snapshot.files.first?.path
                }
                self.loadDetail()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == current else { return }
                self.snapshot = nil
                self.cancelDetail()
                self.phase = (error as? WorkspaceChangesError) == .notRepository ? .notGit : .failed(error.localizedDescription)
            }
            guard let self, self.generation == current else { return }
            self.refreshTask = nil
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.schedule(immediate: false)
            }
        }
    }

    func select(_ path: String?) {
        selectedPath = path
        loadDetail()
    }

    func selectArea(_ value: WorkspaceDiffArea) {
        area = value
        loadDetail()
    }

    private func loadDetail() {
        cancelDetail()
        guard isPresented, let snapshot, let file = selectedFile else { return }
        if !areas.contains(area) { area = areas.first ?? .unstaged }
        let selectedArea = area
        let current = detailGeneration
        let rootGeneration = generation
        detail = .loading
        detailTask = Task { [weak self, reader] in
            do {
                let diff = try await reader.diff(for: file, area: selectedArea, in: snapshot)
                try Task.checkCancellation()
                guard let self, self.detailGeneration == current, self.generation == rootGeneration else { return }
                self.detail = .ready(diff)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.detailGeneration == current, self.generation == rootGeneration else { return }
                self.detail = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDetail() {
        detailGeneration = UUID()
        detailTask?.cancel()
        detailTask = nil
        detail = .idle
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = false
        cancelDetail()
        configured = false
    }
}

private struct NewPiChangesPanelContent: View {
    @ObservedObject var model: NewPiChangesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("工作区 Git 改动", systemImage: "arrow.triangle.branch").font(.headline)
                    Spacer()
                    Button("刷新", systemImage: "arrow.clockwise") { model.refreshNow() }
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(WorkspaceChanges.notice)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let snapshot = model.snapshot {
                    Text("范围：整个 Git 根目录（不限于所选子目录）\n\(WorkspaceChanges.displayPath(snapshot.repositoryRoot.path))")
                        .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("最近完整清单：\(snapshot.readAt.formatted(date: .omitted, time: .standard)) · \(snapshot.files.count) 个文件；diff 按需读取，非原子快照")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding().background(.bar)
            Divider()
            switch model.phase {
            case .noDirectory:
                message("未选择工作目录", symbol: "folder", detail: "选择一个本地 Git 工作目录后查看改动。")
            case .loading:
                if model.snapshot != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在刷新；下方为上次完整清单，当前文件数待确认。").font(.caption)
                    }.padding(8)
                    repositoryContent
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 Git 改动…").foregroundStyle(.secondary)
                        Text("完整清单返回前不显示文件数。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .notGit:
                message("非 Git 工作区", symbol: "folder", detail: WorkspaceChangesError.notRepository.localizedDescription)
            case .failed(let error):
                message("读取未完成", symbol: "exclamationmark.triangle", detail: error)
            case .ready:
                repositoryContent
            }
        }
        .frame(minWidth: 420, idealWidth: 920, minHeight: 420, idealHeight: 650)
    }

    @ViewBuilder
    private var repositoryContent: some View {
        if model.snapshot?.files.isEmpty == true {
            message("没有 Git 改动", symbol: "checkmark.circle", detail: "暂存、未暂存和未跟踪文件均为空（遵循 Git ignore 规则）。")
        } else {
            GeometryReader { geometry in
                if geometry.size.width >= 680 {
                    HStack(spacing: 0) {
                        fileList.frame(width: min(300, geometry.size.width * 0.34))
                        Divider()
                        detailView
                    }
                } else {
                    VStack(spacing: 0) {
                        fileList.frame(height: min(200, geometry.size.height * 0.45))
                        Divider()
                        detailView
                    }
                }
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.snapshot?.files ?? []) { file in
                    Button {
                        model.select(file.path)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(file.displayPath).font(.system(.body, design: .monospaced))
                                .lineLimit(3).help(file.displayPath)
                            if let old = file.originalPath {
                                Text("原路径：\(WorkspaceChanges.displayPath(old))").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(file.statusLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(model.selectedPath == file.path ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(file.displayPath)
                    .accessibilityValue(file.statusLabel)
                    .accessibilityAddTraits(model.selectedPath == file.path ? .isSelected : [])
                }
            }
            .padding(8)
        }
        .background(.bar)
        .accessibilityLabel("改动文件")
    }

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = model.selectedFile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.displayPath).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    HStack(spacing: 8) { areaButtons }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("改动分区")
                }.padding(12)
                Divider()
                switch model.detail {
                case .idle:
                    message("选择一个文件", symbol: "doc.text", detail: "按需读取真实 Git diff。")
                case .loading:
                    ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let error):
                    message("文件读取未完成", symbol: "exclamationmark.triangle", detail: error)
                case .ready(let diff):
                    if let note = diff.message {
                        Text(note).font(.caption)
                            .foregroundStyle(diff.isTruncated ? Color.orange : Color.secondary)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(diff.isTruncated ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.06))
                    }
                    if diff.isTruncated {
                        Label("已截断 · 不完整", systemImage: "exclamationmark.triangle")
                            .font(.caption.bold()).padding(.horizontal, 10)
                    }
                    NewPiChangesDiffLines(diff: diff)
                }
            } else {
                message("选择一个文件", symbol: "doc.text", detail: "暂存与未暂存的改动分开显示。")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var areaButtons: some View {
        ForEach(model.areas, id: \.self) { area in
            Button { model.selectArea(area) } label: {
                Label(areaTitle(area), systemImage: model.area == area ? "checkmark.circle.fill" : "circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .tint(model.area == area ? Color.accentColor : nil)
            .accessibilityAddTraits(model.area == area ? .isSelected : [])
        }
    }

    private func areaTitle(_ area: WorkspaceDiffArea) -> String {
        switch area {
        case .staged: "已暂存"
        case .unstaged: "未暂存"
        case .untracked: "未跟踪 · 内容预览"
        }
    }

    private func message(_ title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail).textSelection(.enabled)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NewPiChangesDiffLines: View {
    let diff: WorkspaceFileDiff

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(line))
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                            .background(color(line).opacity(isHighlighted(line) ? 0.09 : 0))
                    }
                }.textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // 只有真正的 patch 行才使用 +/- 色彩；未跟踪预览绝不伪装成 diff。
    private func color(_ line: String) -> Color {
        guard diff.kind == .patch else { return .primary }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .secondary }
        if line.hasPrefix("+") { return Color(nsColor: .systemGreen) }
        if line.hasPrefix("-") { return Color(nsColor: .systemRed) }
        return .primary
    }

    private func isHighlighted(_ line: String) -> Bool {
        diff.kind == .patch && (line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@"))
    }
}