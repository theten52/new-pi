import NewPiCore
import SwiftUI

struct NewPiSettingsView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @State private var showingAddSheet = false
    @State private var editingProfile: ProviderProfile?

    var body: some View {
        Form {
            Section("Default Provider") {
                Picker("Active provider", selection: defaultProfileBinding) {
                    ForEach(viewModel.providerConfig.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
            }

            Section("Providers") {
                if viewModel.providerListItems.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.providerListItems) { item in
                        NewPiProviderRow(item: item) {
                            editingProfile = item.profile
                        }
                    }
                }

                Button("Add Provider…") {
                    showingAddSheet = true
                }
            }

            Section("Paths") {
                LabeledContent("Config") {
                    Text("~/.new-pi/agent/providers.json")
                        .font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddSheet) {
            NewPiAddProviderSheet { template in
                showingAddSheet = false
                editingProfile = ProviderProfile.makeDefault(from: template)
            }
        }
        .sheet(item: $editingProfile) { profile in
            NewPiEditProviderSheet(viewModel: viewModel, profile: profile)
        }
    }

    private var defaultProfileBinding: Binding<String> {
        Binding(
            get: { viewModel.providerConfig.defaultProfileID ?? "" },
            set: { newValue in
                Task {
                    await viewModel.setDefaultProvider(profileID: newValue)
                }
            }
        )
    }
}

struct NewPiProviderRow: View {
    let item: NewPiProviderListItem
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.profile.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(ProviderPresetCatalog.definition(for: item.profile.preset).displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                    Text(item.profile.modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            credentialStatus
            Button("Edit", action: onEdit)
        }
    }

    @ViewBuilder
    private var credentialStatus: some View {
        let definition = ProviderPresetCatalog.definition(for: item.profile.preset)
        if definition.credentialRequired {
            if item.hasAPIKey {
                Label("Key saved", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("API key configured")
            } else {
                Label("Key missing", systemImage: "key.slash")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help("API key missing")
            }
        } else {
            Label("No key needed", systemImage: "minus.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help("No API key required")
        }
    }
}

struct NewPiAddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (ProviderPresetDefinition) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ProviderPresetCatalog.quickAddTemplates, id: \.displayName) { template in
                        Button {
                            onSelect(template)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: template.systemImage)
                                    .font(.title2)
                                Text(template.displayName)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 90)
                            .padding()
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Add Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

struct NewPiEditProviderSheet: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ProviderProfile
    @State private var apiKeyDraft = ""
    @State private var customModel = ""
    @State private var errorMessage: String?
    @State private var testMessage: String?
    @State private var isTestingConnection = false

    init(viewModel: NewPiViewModel, profile: ProviderProfile) {
        self.viewModel = viewModel
        _profile = State(initialValue: profile)
        _customModel = State(initialValue: profile.modelID)
    }

    private var definition: ProviderPresetDefinition {
        ProviderPresetCatalog.definition(for: profile.preset)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name)
                    LabeledContent("Preset") {
                        Text(definition.displayName)
                    }
                }

                if definition.credentialRequired {
                    Section("API Key") {
                        SecureField("API Key", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave blank to keep the existing key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Model") {
                    Picker("Preset models", selection: $customModel) {
                        ForEach(definition.defaultModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                        if !definition.defaultModels.contains(customModel) {
                            Text(customModel).tag(customModel)
                        }
                    }
                    TextField("Custom model ID", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                }

                if !definition.optionFields.isEmpty {
                    Section("Options") {
                        ForEach(definition.optionFields, id: \.key) { field in
                            TextField(field.label, text: optionBinding(for: field.key), prompt: Text(field.placeholder))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if let testMessage {
                    Section("Connection test") {
                        Text(testMessage)
                            .foregroundStyle(testMessage.hasPrefix("✓") ? .green : .red)
                    }
                }

                Section {
                    Button(isTestingConnection ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTestingConnection)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if viewModel.providerConfig.profiles.contains(where: { $0.id == profile.id }) {
                    Section {
                        Button("Delete Provider", role: .destructive) {
                            Task {
                                await viewModel.deleteProfile(id: profile.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Edit Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: customModel) { _, newValue in
            profile.modelID = newValue
        }
    }

    private func optionBinding(for key: ProviderOptionKey) -> Binding<String> {
        Binding(
            get: { profile.option(key) ?? "" },
            set: { profile.setOption(key, value: $0) }
        )
    }

    private func testConnection() async {
        profile.modelID = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try profile.validate()
        } catch {
            testMessage = error.localizedDescription
            return
        }

        isTestingConnection = true
        defer { isTestingConnection = false }

        let result = await viewModel.testProviderConnection(profile: profile, apiKeyDraft: apiKeyDraft)
        testMessage = result.success ? "✓ \(result.message)" : "✗ \(result.message)"
    }

    private func save() {
        profile.modelID = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try profile.validate()
            errorMessage = nil
            Task {
                await viewModel.saveProfile(profile, apiKeyDraft: apiKeyDraft)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NewPiSettingsView(viewModel: NewPiViewModel())
}
