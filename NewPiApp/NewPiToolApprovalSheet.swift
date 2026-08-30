import NewPiCore
import SwiftUI

struct NewPiToolApprovalSheet: View {
    @ObservedObject var viewModel: NewPiViewModel
    let request: ToolApprovalRequest

    private var dangerColor: Color {
        switch request.dangerLevel {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var isHighRisk: Bool {
        request.dangerLevel == .high
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contentBlock
            if let reason = request.dangerReason, !reason.isEmpty {
                dangerBanner(reason)
            }
            if isHighRisk {
                Text("该操作风险极高。即使本次允许，后续每次执行仍会再次确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            actionRow
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - 头部：图标 + 标题 + 工具/风险徽章

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: request.dangerLevel.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(dangerColor)
                .frame(width: 36, height: 36)
                .background(dangerColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(approvalTitle)
                    .font(.headline)
                HStack(spacing: 6) {
                    badge(request.toolName.uppercased(), color: .secondary)
                    badge(request.dangerLevel.displayName, color: dangerColor)
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .clipShape(Capsule())
    }

    // MARK: - 内容块：等宽命令/摘要

    private var contentBlock: some View {
        ScrollView {
            Text(request.summary)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxHeight: 180)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - 危险提示横幅

    private func dangerBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: request.dangerLevel.systemImage)
                .font(.callout)
                .foregroundStyle(dangerColor)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(dangerColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 操作行：拒绝 / 不再询问 / 允许一次

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("拒绝") {
                viewModel.denyPendingTool()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if !isHighRisk {
                Menu {
                    Button("本对话中不再询问 \(request.toolName)") {
                        viewModel.approvePendingTool(scope: .session)
                    }
                    Button("一直允许 \(request.toolName)") {
                        viewModel.approvePendingTool(scope: .forever)
                    }
                } label: {
                    Text("不再询问…")
                }
                .menuStyle(.borderedButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("按整类工具记忆授权；高风险操作不受此设置影响")
            }

            Button("允许一次") {
                viewModel.approvePendingTool(scope: .once)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private var approvalTitle: String {
        switch request.dangerLevel {
        case .low: "确认执行？"
        case .medium: "操作确认"
        case .high: "高风险操作 · 需再次确认"
        }
    }
}

#Preview {
    NewPiToolApprovalSheet(
        viewModel: NewPiViewModel(),
        request: ToolApprovalRequest(
            id: "call_preview",
            toolName: "bash",
            arguments: .object(["command": .string("rm -rf ~/important")]),
            summary: "Run command:\nrm -rf ~/important",
            dangerLevel: .high,
            dangerReason: "递归强制删除 home/根/上级目录"
        )
    )
}
