import NewPiCore
import SwiftUI

struct NewPiToolApprovalSheet: View {
    @ObservedObject var viewModel: NewPiViewModel
    let request: ToolApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow tool execution?")
                .font(.title3.weight(.semibold))

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

            HStack {
                Button("Deny") {
                    viewModel.denyPendingTool()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Allow") {
                    viewModel.approvePendingTool()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 280)
    }
}

#Preview {
    NewPiToolApprovalSheet(
        viewModel: NewPiViewModel(),
        request: ToolApprovalRequest(
            id: "call_preview",
            toolName: "bash",
            arguments: .object(["command": .string("pwd && ls -la")]),
            summary: "Run command:\npwd && ls -la"
        )
    )
}
