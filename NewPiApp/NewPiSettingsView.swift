import NewPiCore
import SwiftUI

struct NewPiSettingsView: View {
    @ObservedObject var viewModel: NewPiViewModel

    var body: some View {
        Form {
            Section("Anthropic") {
                if viewModel.hasAnthropicAPIKey {
                    Label("API key saved in Keychain", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("No API key found. Save one here or set ANTHROPIC_API_KEY.")
                        .foregroundStyle(.secondary)
                }

                SecureField("Anthropic API Key", text: $viewModel.anthropicAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)

                Button("Save API Key") {
                    Task {
                        await viewModel.saveAnthropicAPIKey()
                    }
                }
                .disabled(viewModel.anthropicAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Paths") {
                LabeledContent("Config") {
                    Text("~/.new-pi/agent/")
                        .font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 260)
        .navigationTitle("Settings")
    }
}

#Preview {
    NewPiSettingsView(viewModel: NewPiViewModel())
}
