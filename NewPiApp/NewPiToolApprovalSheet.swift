import AppKit
import NewPiCore
import SwiftUI

struct NewPiToolApprovalSheet: View {
    @ObservedObject var viewModel: NewPiViewModel
    let request: ToolApprovalRequest

    var body: some View {
        NewPiApprovalContent(request: request) { decision in
            if decision.approved { viewModel.approvePendingTool(scope: decision.scope) }
            else { viewModel.denyPendingTool() }
        }
        .id(request.id)
    }
}

/// Session 与聊天室共用展示和风险按钮；授权状态与响应仍由各自控制器持有。
struct NewPiApprovalContent: View {
    struct ChatRoomContext {
        let name: String
        let role: String
        let directory: String
    }

    let request: ToolApprovalRequest
    var chatroom: ChatRoomContext? = nil
    var isInline = false
    let onDecision: (ApprovalDecision) -> Void
    @State private var responded = false

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
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
            if let chatroom {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("聊天室", value: chatroom.name)
                    LabeledContent("申请角色", value: chatroom.role)
                    Text(chatroom.directory)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .help(chatroom.directory)
                }
            }
            contentBlock
            if let reason = request.dangerReason, !reason.isEmpty {
                dangerBanner(reason)
            }
            if isHighRisk {
                Text("该操作风险极高。即使本次允许，后续每次执行仍会再次确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if chatroom != nil {
                Text("本聊天室授权覆盖所有角色的整类工具，仅本次 App 运行期间有效。允许 bash 不代表其访问范围被限制在工作目录内。高风险操作仍需确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isInline ? 130 : 320)
            Divider()
            actionRow
        }
        .padding(isInline ? 12 : 20)
        .frame(maxWidth: isInline ? .infinity : 520)
        .background(isInline ? dangerColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(isInline ? dangerColor.opacity(0.5) : .clear) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("待审批操作，" + request.dangerLevel.displayName)
    }

    // MARK: - 头部：图标 + 标题 + 工具/风险徽章

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: request.dangerLevel.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(dangerColor)
                .frame(width: 36, height: 36)
                .background(dangerColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(approvalTitle)
                    .font(.headline)
                HStack(spacing: 6) {
                    badge(request.toolName.uppercased(), color: .secondary)
                    badge(request.dangerLevel.displayName, color: dangerColor)
                }
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.summary, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制操作详情")
            .accessibilityLabel("复制操作详情")
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
            Text(request.summary)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
                respond(.deny)
            }

            Spacer()

            if !isHighRisk {
                Menu {
                    Button(chatroom == nil ? "本对话中不再询问 \(request.toolName)" : "本聊天室内允许 \(request.toolName)") {
                        respond(.allowSession)
                    }
                    if chatroom == nil {
                        Button("一直允许 \(request.toolName)") {
                            respond(.allowForever)
                        }
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
                respond(.allowOnce)
            }
            // 内联审批不可用 Return/Escape，避免编辑草稿时意外授权/拒绝。
            .buttonStyle(.borderedProminent)
        }
        .disabled(responded)
    }

    private func respond(_ decision: ApprovalDecision) {
        guard !responded else { return }
        responded = true
        onDecision(decision)
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
