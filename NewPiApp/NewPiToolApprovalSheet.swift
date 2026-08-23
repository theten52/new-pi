import NewPiCore
import SwiftUI

struct NewPiToolApprovalSheet: View {
    @ObservedObject var viewModel: NewPiViewModel

    var body: some View {
        if let request = viewModel.pendingToolApproval {
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow tool execution?")
                    .font(.headline)

                Text(request.toolName.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(request.summary)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)

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
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}

#Preview {
    NewPiToolApprovalSheet(viewModel: NewPiViewModel())
}
