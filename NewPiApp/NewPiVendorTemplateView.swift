import NewPiCore
import SwiftUI

// MARK: - 模板管理

/// 厂商模板管理：列表展示（内置 + 自定义），支持编辑、恢复默认、删除、新增。
struct NewPiVendorTemplateManagerView: View {
    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingTemplate: VendorPreset?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.vendorTemplates) { template in
                    row(for: template)
                }
            }
            .navigationTitle("Manage Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreating) {
                NewPiVendorTemplateEditorView(
                    viewModel: viewModel,
                    template: VendorPresets.makeBlank(),
                    onSave: { newTemplate in
                        var list = viewModel.vendorTemplates
                        list.append(newTemplate)
                        Task { await viewModel.saveVendorTemplates(list) }
                    }
                )
            }
            .sheet(item: $editingTemplate) { template in
                NewPiVendorTemplateEditorView(
                    viewModel: viewModel,
                    template: template,
                    onSave: { edited in
                        var list = viewModel.vendorTemplates
                        if let index = list.firstIndex(where: { $0.id == edited.id }) {
                            list[index] = edited
                        }
                        Task { await viewModel.saveVendorTemplates(list) }
                    }
                )
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    @ViewBuilder
    private func row(for template: VendorPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.displayName)
                        .font(.headline)
                    if isOverridden(template) {
                        Text("已修改")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(template.preset.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(template.defaultModels.count) 个模型")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Edit") {
                editingTemplate = template
            }
            if let builtin = VendorPresets.all.first(where: { $0.id == template.id }) {
                if builtin != template {
                    Button("恢复默认", role: .destructive) {
                        Task { await viewModel.resetVendorTemplate(id: template.id) }
                    }
                }
            } else {
                Button("删除", role: .destructive) {
                    Task {
                        var list = viewModel.vendorTemplates
                        list.removeAll { $0.id == template.id }
                        await viewModel.saveVendorTemplates(list)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 是否相对内置模板有改动（自定义模板视为已修改）。
    private func isOverridden(_ template: VendorPreset) -> Bool {
        guard let builtin = VendorPresets.all.first(where: { $0.id == template.id }) else {
            return true
        }
        return builtin != template
    }
}

// MARK: - 模板编辑

/// 编辑单个模板的全部字段（含模型列表）。
struct NewPiVendorTemplateEditorView: View {
    let template: VendorPreset
    let onSave: (VendorPreset) -> Void

    @ObservedObject var viewModel: NewPiViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VendorPreset
    @State private var editingModel: ModelDefinition?
    @State private var newModelDraft = ""
    /// 模板无持久化凭据，拉取模型列表时临时输入的 API Key（不保存）。
    @State private var templateAPIKeyDraft = ""
    @State private var isRefreshingModels = false
    @State private var refreshMessage: String?

    init(viewModel: NewPiViewModel, template: VendorPreset, onSave: @escaping (VendorPreset) -> Void) {
        self.viewModel = viewModel
        self.template = template
        self.onSave = onSave
        _draft = State(initialValue: template)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("显示名称", text: $draft.displayName)
                    TextField("图标（SF Symbols）", text: $draft.icon)
                    TextField("描述", text: Binding(
                        get: { draft.description ?? "" },
                        set: { draft.description = $0.isEmpty ? nil : $0 }
                    ))
                }

                Section("协议") {
                    Picker("API 类型", selection: $draft.preset) {
                        ForEach(ProviderPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .onChange(of: draft.preset) { _, newPreset in
                        // 切到不支持 Responses 的协议时重置 API Mode，避免脏数据。
                        if !newPreset.supportsResponses, draft.apiMode == .responses {
                            draft.apiMode = .chatCompletions
                        }
                    }
                    if draft.preset.supportsResponses {
                        Picker("API Mode", selection: $draft.apiMode) {
                            ForEach(ProviderAPIMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("连接") {
                    TextField("Base URL", text: $draft.baseUrl)
                    TextField("API Key Header", text: $draft.apiKeyHeader)
                    TextField("API Key 占位提示", text: Binding(
                        get: { draft.apiKeyPlaceholder ?? "" },
                        set: { draft.apiKeyPlaceholder = $0.isEmpty ? nil : $0 }
                    ))
                }

                Section("模型") {
                    ForEach(draft.defaultModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                Text(model.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑") {
                                editingModel = model
                            }
                            Button(role: .destructive) {
                                draft.defaultModels.removeAll { $0.id == model.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("添加模型 ID", text: $newModelDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addModel)
                        Button("添加", action: addModel)
                            .disabled(newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // 模型发现：从模板端点拉取可用模型并合并进模型列表。
                    if draft.preset.credentialRequired {
                        SecureField("API Key（仅用于拉取模型，不保存）", text: $templateAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button {
                            Task { await refreshModels() }
                        } label: {
                            if isRefreshingModels {
                                ProgressView().controlSize(.small)
                                Text("刷新中…")
                            } else {
                                Label("刷新模型列表", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshingModels)
                        Spacer()
                    }
                    if let refreshMessage {
                        Text(refreshMessage)
                            .font(.caption)
                            .foregroundStyle(refreshMessage.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.displayName.isEmpty ? "编辑模板" : draft.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .sheet(item: $editingModel) { model in
                NewPiModelDefinitionEditorView(model: model) { edited in
                    guard let index = draft.defaultModels.firstIndex(where: { $0.id == model.id }) else { return }
                    // 去重：新 id 不能与其他模型冲突（否则 ForEach 的 Identifiable 会重复崩溃）。
                    let conflicts = draft.defaultModels.enumerated().contains { $0.offset != index && $0.element.id == edited.id }
                    if conflicts { return }
                    draft.defaultModels[index] = edited
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private func addModel() {
        let id = newModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !draft.defaultModels.contains(where: { $0.id == id }) else { return }
        draft.defaultModels.append(ModelDefinition(id: id))
        newModelDraft = ""
    }

    /// 模型发现：从模板端点拉取可用模型（用临时 API Key），合并进 defaultModels。
    private func refreshModels() async {
        // 自定义端点无默认 Base URL，空值会回落请求 api.openai.com（误导），先拦截。
        if draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           draft.preset.defaultBaseURL == nil {
            refreshMessage = "✗ 请先填写 Base URL"
            return
        }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        let key = templateAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await viewModel.fetchModelsForTemplate(draft, apiKey: key)
        switch result {
        case .success(let models):
            var added = 0
            for modelID in models {
                let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !draft.defaultModels.contains(where: { $0.id == trimmed }) {
                    draft.defaultModels.append(ModelDefinition(id: trimmed))
                    added += 1
                }
            }
            refreshMessage = added > 0
                ? "✓ 发现 \(models.count) 个模型，新增 \(added) 个"
                : "✓ 已是最新（\(draft.defaultModels.count) 个模型）"
        case .failure(let error):
            refreshMessage = "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - 模型编辑

/// 编辑单个模型定义的完整字段（context window / 输出 token / 能力 / 价格）。
struct NewPiModelDefinitionEditorView: View {
    let model: ModelDefinition
    let onSave: (ModelDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelDefinition
    @State private var hasPricing: Bool
    @State private var pricingDraft: ModelPricing

    init(model: ModelDefinition, onSave: @escaping (ModelDefinition) -> Void) {
        self.model = model
        self.onSave = onSave
        _draft = State(initialValue: model)
        _hasPricing = State(initialValue: model.pricing != nil)
        _pricingDraft = State(initialValue: model.pricing ?? ModelPricing(input: 0, output: 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    TextField("模型 ID", text: $draft.id)
                    TextField("显示名称", text: $draft.name)
                    TextField("Context Window（token）", value: $draft.contextWindow, format: .number)
                    TextField("最大输出 token", value: $draft.maxOutputTokens, format: .number)
                }

                Section("能力") {
                    Toggle("推理", isOn: $draft.capabilities.reasoning)
                    Toggle("图片输入", isOn: $draft.capabilities.image)
                    Toggle("工具调用", isOn: $draft.capabilities.toolUse)
                    Toggle("流式输出", isOn: $draft.capabilities.streaming)
                }

                Section("价格") {
                    Toggle("配置价格", isOn: $hasPricing)
                    if hasPricing {
                        Picker("货币", selection: $pricingDraft.currency) {
                            Text("USD").tag(Currency.usd)
                            Text("CNY").tag(Currency.cny)
                        }
                        TextField("输入（每 1M token）", value: $pricingDraft.input, format: .number)
                        TextField("输出（每 1M token）", value: $pricingDraft.output, format: .number)
                        TextField("缓存读（每 1M token，可选）", value: Binding(
                            get: { pricingDraft.cacheRead ?? 0 },
                            set: { pricingDraft.cacheRead = $0 == 0 ? nil : $0 }
                        ), format: .number)
                        TextField("缓存写（每 1M token，可选）", value: Binding(
                            get: { pricingDraft.cacheWrite ?? 0 },
                            set: { pricingDraft.cacheWrite = $0 == 0 ? nil : $0 }
                        ), format: .number)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        draft.pricing = hasPricing ? pricingDraft : nil
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }
}

// MARK: - 辅助

extension VendorPresets {
    /// 创建一个空白模板（用户新增厂商的起点）。
    static func makeBlank() -> VendorPreset {
        VendorPreset(
            id: UUID().uuidString,
            displayName: "新厂商",
            icon: "server.rack",
            apiMode: .chatCompletions,
            preset: .openaiCompatible,
            baseUrl: "",
            apiKeyHeader: "Authorization",
            apiKeyPlaceholder: nil,
            defaultModels: [],
            description: nil
        )
    }
}
