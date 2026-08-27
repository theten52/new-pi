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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: request.dangerLevel.systemImage)
                    .font(.title2)
                    .foregroundStyle(dangerColor)
                Text(approvalTitle)
                    .font(.title3.weight(.semibold))
            }

            Text(request.toolName.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            ScrollView {
                Text(request.summary)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)

            // 危险提示信息
            if let reason = request.dangerReason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: request.dangerLevel.systemImage)
                        .font(.body)
                        .foregroundStyle(dangerColor)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(dangerColor)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(dangerColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isHighRisk {
                Text("该操作风险极高。即使选择「本对话一直允许」或「一直允许」，后续每次执行仍会再次确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button("拒绝") {
                    viewModel.denyPendingTool()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("一次允许") {
                    viewModel.approvePendingTool(scope: .once)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("本对话一直允许") {
                    viewModel.approvePendingTool(scope: .session)
                }

                Button("一直允许") {
                    viewModel.approvePendingTool(scope: .forever)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 300)
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
            dangerReason: "递归强制删除文件；提权执行"
        )
    )
}
