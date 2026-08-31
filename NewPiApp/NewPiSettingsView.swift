import AppKit
import NewPiCore
import SwiftUI

struct NewPiSettingsView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @StateObject private var mcpBridge = MCPPluginManagerBridge()
    @StateObject private var approvalBridge = ApprovalPolicySettingsBridge()
    @State private var showingAddSheet = false
    @State private var editingProfile: ProviderProfile?
    @State private var showLogs = false

    var body: some View {
        Form {
            Section("Default Provider") {
                Picker("Default for new sessions", selection: defaultProfileBinding) {
                    ForEach(viewModel.providerConfig.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                Text("只影响之后新建的会话；已有会话保持各自选择的模型（会话内可在状态栏的模型菜单中切换，选择会随会话记住）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Providers") {
                if viewModel.providerListItems.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.providerListItems) { item in
                        NewPiProviderRow(
                            item: item,
                            onEdit: { editingProfile = item.profile },
                            onDelete: {
                                Task { await viewModel.deleteProfile(id: item.profile.id) }
                            },
                            canDelete: viewModel.providerListItems.count > 1
                        )
                    }
                }

                Button("Add Provider…") {
                    showingAddSheet = true
                }
            }

            Section("Credentials") {
                Toggle("Store API keys in Keychain", isOn: useKeychainBinding)
                Text("Off by default for Xcode debugging (UserDefaults + optional .env). When on, saved keys are also written to Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.useKeychainForCredentials {
                    Text("If macOS still asks for your login password, open each provider → paste API key → Save once (stored locally, no Keychain).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Paths") {
                LabeledContent("Providers") {
                    Text("~/.new-pi/agent/providers.json")
                        .font(.caption.monospaced())
                }
                LabeledContent("MCP") {
                    Text("~/.new-pi/agent/mcp.json")
                        .font(.caption.monospaced())
                }
            }

            Section("危险评估") {
                Toggle("LLM 补充评估（消耗 token）", isOn: $approvalBridge.llmSupplementEnabled)
                Text("LLM 评估失败时降级为工具基线等级，绝不降为低风险。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重置为默认规则") {
                    approvalBridge.resetToDefaults()
                }
            }

            NewPiMCPSettingsView(bridge: mcpBridge)

            Section("Debug") {
                Button("View Logs") {
                    showLogs = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddSheet) {
            NewPiAddProviderSheet(
                onVendorSelect: { preset in
                    showingAddSheet = false
                    let profile = VendorPresets.makeProfile(from: preset)
                    editingProfile = profile
                },
                onCustomSelect: {
                    showingAddSheet = false
                    // 使用默认的 OpenAI Compatible 配置
                    let template = ProviderPresetCatalog.openaiCompatible
                    editingProfile = ProviderProfile.makeDefault(from: template)
                }
            )
        }
        .sheet(item: $editingProfile) { profile in
            NewPiEditProviderSheet(viewModel: viewModel, profile: profile)
        }
        .sheet(isPresented: $showLogs) {
            NewPiLogsView(store: NewPiLogStore.shared)
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

    private var useKeychainBinding: Binding<Bool> {
        Binding(
            get: { viewModel.useKeychainForCredentials },
            set: { viewModel.setUseKeychainForCredentials($0) }
        )
    }
}

struct NewPiProviderRow: View {
    let item: NewPiProviderListItem
    let onEdit: () -> Void
    let onDelete: () -> Void
    var canDelete: Bool = true
    @State private var confirmDelete = false

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
                    if item.profile.supportsAPIModeSelection, item.profile.apiMode == .responses {
                        Text("Responses")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(item.profile.modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(item.profile.models.count) 个模型")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            credentialStatus
            Button("Edit", action: onEdit)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "Delete this provider" : "Cannot delete the last provider")
            .confirmationDialog(
                "Delete provider “\(item.profile.name)”?",
                isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the profile and its saved API key. This cannot be undone.")
            }
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
    /// 选择知名厂商预设
    let onVendorSelect: (VendorPreset) -> Void
    /// 选择自定义端点（使用默认配置）
    let onCustomSelect: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 知名厂商列表
                    Section {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(VendorPresets.all) { preset in
                                Button {
                                    onVendorSelect(preset)
                                    dismiss()
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: preset.icon)
                                            .font(.title2)
                                        Text(preset.displayName)
                                            .font(.subheadline)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 90)
                                    .padding()
                                    .background(.quaternary.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("知名厂商")
                            .font(.headline)
                    }
                    
                    // 分隔线
                    Divider()
                    
                    // 自定义端点
                    Section {
                        Button {
                            onCustomSelect()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text("自定义端点")
                                        .font(.headline)
                                    Text("手动配置 API 类型、Base URL 等参数")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
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
        .frame(minWidth: 480, minHeight: 420)
    }
}

struct NewPiEditProviderSheet: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ProviderProfile
    @State private var apiKeyDraft = ""
    @State private var newModelDraft = ""
    @State private var errorMessage: String?
    @State private var testMessage: String?
    @State private var isTestingConnection = false

    init(viewModel: NewPiViewModel, profile: ProviderProfile) {
        self.viewModel = viewModel
        _profile = State(initialValue: profile)
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
                        Text("Keys are saved to UserDefaults by default. Enable Keychain in Settings if you want Keychain storage too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 多模型管理：模型列表任意增删，星标为该 provider 的默认模型
                //（新建会话/连接测试用它；会话内可在状态栏模型菜单临时切换）。
                Section("Models") {
                    ForEach(profile.models, id: \.self) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                Spacer()
                                // 图片能力标注
                                Button {
                                    profile.toggleImageSupport(model)
                                } label: {
                                    Image(systemName: profile.supportsImages(modelID: model) ? "photo.fill" : "photo")
                                        .foregroundStyle(profile.supportsImages(modelID: model) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(
                                    profile.supportsImages(modelID: model)
                                        ? "支持图片识别（点击关闭）"
                                        : "不支持图片识别（点击开启）"
                                )
                                Button {
                                    profile.modelID = model
                                } label: {
                                    Image(systemName: profile.modelID == model ? "star.fill" : "star")
                                        .foregroundStyle(profile.modelID == model ? Color.yellow : Color.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(profile.modelID == model ? "默认模型" : "设为默认模型")
                                Button(role: .destructive) {
                                    profile.removeModel(model)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(profile.models.count <= 1)
                                .help(profile.models.count <= 1 ? "至少保留一个模型" : "移除该模型")
                            }
                            
                            // 模型详细信息（如果从 VendorPreset 加载）
                            if let modelDef = findModelDefinition(modelID: model) {
                                HStack(spacing: 12) {
                                    // Context Window
                                    Label(formatTokenCount(modelDef.contextWindow), systemImage: "doc.text")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    
                                    // 价格
                                    if let pricing = modelDef.pricing {
                                        Label(formatPricing(pricing), systemImage: "yensign.circle")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // 能力标记
                                    HStack(spacing: 4) {
                                        if modelDef.capabilities.reasoning {
                                            Image(systemName: "brain")
                                                .help("推理")
                                        }
                                        if modelDef.capabilities.image {
                                            Image(systemName: "photo")
                                                .help("图片")
                                        }
                                        if modelDef.capabilities.toolUse {
                                            Image(systemName: "wrench")
                                                .help("工具")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 8) {
                        TextField("Add model ID", text: $newModelDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addDraftedModel)
                        Button("Add", action: addDraftedModel)
                            .disabled(newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    let unusedPresets = definition.defaultModels.filter { !profile.models.contains($0) }
                    if !unusedPresets.isEmpty {
                        Menu("从内置模型添加…") {
                            ForEach(unusedPresets, id: \.self) { model in
                                Button(model) {
                                    profile.addModel(model)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                if profile.supportsAPIModeSelection {
                    Section("API") {
                        Picker("API Mode", selection: apiModeBinding) {
                            ForEach(ProviderAPIMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(apiModeHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !definition.optionFields.isEmpty {
                    Section("Options") {
                        ForEach(definition.optionFields, id: \.key) { field in
                            TextField(
                                field.label,
                                text: optionBinding(for: field.key),
                                prompt: Text(baseURLPlaceholder(for: field.key))
                            )
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
    }

    private func addDraftedModel() {
        let draft = newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        profile.addModel(draft)
        newModelDraft = ""
    }

    private func optionBinding(for key: ProviderOptionKey) -> Binding<String> {
        Binding(
            get: { profile.option(key) ?? "" },
            set: { profile.setOption(key, value: $0) }
        )
    }

    private var apiModeBinding: Binding<ProviderAPIMode> {
        Binding(
            get: { profile.apiMode },
            set: { newMode in
                profile.setAPIMode(newMode)
                normalizeBaseURLForAPIMode(newMode)
            }
        )
    }

    private var apiModeHelpText: String {
        switch profile.apiMode {
        case .chatCompletions:
            "Uses POST /v1/chat/completions (OpenAI-compatible chat format)."
        case .responses:
            "Uses POST /responses (OpenAI Responses format). Required for DeepSeek V4 Codex-style models."
        }
    }

    private func baseURLPlaceholder(for key: ProviderOptionKey) -> String {
        if key == .baseURL, profile.supportsAPIModeSelection {
            return ResponsesEndpoint.defaultBaseURLPlaceholder(for: profile.apiMode)
        }
        return definition.optionFields.first(where: { $0.key == key })?.placeholder ?? ""
    }

    private func normalizeBaseURLForAPIMode(_ mode: ProviderAPIMode) {
        let current = profile.option(.baseURL) ?? ""
        switch mode {
        case .responses:
            if current.contains("/chat/completions") || current.isEmpty {
                profile.setOption(.baseURL, value: "https://api.deepseek.com")
            }
        case .chatCompletions:
            if current.contains("deepseek.com"), !current.contains("/chat/completions") {
                profile.setOption(.baseURL, value: "https://api.deepseek.com/v1/chat/completions")
            }
        }
    }

    private func testConnection() async {
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

// MARK: - 模型信息辅助函数

private func findModelDefinition(modelID: String) -> ModelDefinition? {
    // 从 VendorPresets 中查找模型定义
    for preset in VendorPresets.all {
        if let model = preset.defaultModels.first(where: { $0.id == modelID }) {
            return model
        }
    }
    return nil
}

private func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.0fK", Double(count) / 1_000)
    }
    return "\(count)"
}

private func formatPricing(_ pricing: ModelPricing) -> String {
    let symbol = pricing.currency == .cny ? "¥" : "$"
    return "\(symbol)\(pricing.input)/\(pricing.output) per 1M"
}


#Preview {
    NewPiSettingsView(viewModel: NewPiViewModel())
}
