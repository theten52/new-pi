import Foundation

public enum ProviderConfigError: Error, Sendable, Equatable {
    case duplicateProfileID(String)
    case emptyModelID
    case missingRequiredOption(ProviderOptionKey)
    case invalidURL(String)
    case unknownPreset(String)
    case profileNotFound(String)
    case noProfiles
}

extension ProviderConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicateProfileID(id):
            "Duplicate provider profile id: \(id)"
        case .emptyModelID:
            "Model ID cannot be empty."
        case let .missingRequiredOption(key):
            "Missing required option: \(key.rawValue)"
        case let .invalidURL(value):
            "Invalid URL: \(value)"
        case let .unknownPreset(value):
            "Unknown provider preset: \(value)"
        case let .profileNotFound(id):
            "Provider profile not found: \(id)"
        case .noProfiles:
            "No provider profiles configured."
        }
    }
}

public struct ProviderProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var preset: ProviderPreset
    /// 当前选用/默认模型（新建会话时的默认值；会话内切换记进 session header）。
    /// 不变量：始终属于 `models`（init/解码时自动归一化）。
    public var modelID: String
    /// 该 provider 下可供选择的模型列表（内置预设模型 + 用户自增）。
    public var models: [String]
    /// 支持图片识别的模型集合（BACKLOG-IMAGE-INPUT）。缺省空 = 都不支持图片。
    /// 旧配置解码时缺省为空（语义「不支持」）；preset 已知 vision 模型预填默认值。
    public var imageCapableModels: Set<String>
    public var thinkingLevel: ThinkingLevel
    public var maxTokens: Int
    public var options: [String: String]
    /// 模型详细定义（新增）：保存模型的完整信息，包括价格、能力、context window 等。
    /// 旧配置解码时缺省为空字典；从 VendorPreset 创建时会填充。
    public var modelDefinitions: [String: ModelDefinition]

    public init(
        id: String = UUID().uuidString,
        name: String,
        preset: ProviderPreset,
        modelID: String,
        models: [String]? = nil,
        imageCapableModels: Set<String> = [],
        thinkingLevel: ThinkingLevel = .off,
        maxTokens: Int = 8192,
        options: [String: String] = [:],
        modelDefinitions: [String: ModelDefinition] = [:]
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.modelID = modelID
        self.models = Self.normalizedModels(models ?? [modelID], ensuring: modelID)
        self.imageCapableModels = imageCapableModels
        self.thinkingLevel = thinkingLevel
        self.maxTokens = maxTokens
        self.options = options
        self.modelDefinitions = modelDefinitions
    }

    // 自定义解码：旧版 providers.json 没有 `models` 字段，回退为 [modelID]，
    // 实现无损迁移（BACKLOG-PROVIDER-MULTI-MODEL）；`imageCapableModels` 缺省空。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        preset = try container.decode(ProviderPreset.self, forKey: .preset)
        modelID = try container.decode(String.self, forKey: .modelID)
        let decodedModels = try container.decodeIfPresent([String].self, forKey: .models)
        models = Self.normalizedModels(decodedModels ?? [modelID], ensuring: modelID)
        imageCapableModels = Set(
            try container.decodeIfPresent([String].self, forKey: .imageCapableModels) ?? []
        )
        thinkingLevel = try container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel) ?? .off
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 8192
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        modelDefinitions = try container.decodeIfPresent([String: ModelDefinition].self, forKey: .modelDefinitions) ?? [:]
    }

    /// 判断某个模型是否支持图片输入。
    public func supportsImages(modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return imageCapableModels.contains(normalized)
    }
    
    /// 获取模型的详细定义（如果存在）。
    public func modelDefinition(for modelID: String) -> ModelDefinition? {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelDefinitions[normalized]
    }
    
    /// 获取模型的 Context Window 大小：优先 modelDefinitions 中的精确值，
    /// 否则回落静态目录表（ContextWindowCatalog），再回落 provider 兜底。
    /// 避免两套数据（preset 预设 vs 目录表）不一致。
    public func contextWindow(for modelID: String) -> Int {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let def = modelDefinitions[normalized], def.contextWindow > 0 {
            return def.contextWindow
        }
        return ContextWindowCatalog.windowTokens(for: normalized, preset: preset)
    }

    /// 认证 header 名称（厂商预设可覆盖）。
    /// 从 options["apiKeyHeader"] 读取；缺省时 Anthropic 协议用 `x-api-key`，其余默认 `Authorization`。
    /// 如小米 MiMo 用 `api-key`、Anthropic 兼容用 `x-api-key`。
    public var apiKeyHeader: String {
        if let configured = options["apiKeyHeader"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        return preset == .anthropic ? "x-api-key" : "Authorization"
    }

    /// 认证 header 值：Authorization 头需带 `Bearer ` 前缀，其余头（api-key / x-api-key）直接放 key。
    /// header 名比较大小写不敏感（HTTP header 名本身大小写不敏感）。
    public func apiKeyHeaderValue(_ apiKey: String) -> String {
        apiKeyHeader.caseInsensitiveCompare("Authorization") == .orderedSame
            ? "Bearer \(apiKey)" : apiKey
    }

    /// 切换某模型的图片能力标注（与 `supportsImages` 同一 normalize 口径）。
    /// preset 预填之外的自定义模型（如 OpenRouter 渠道）由用户在 Settings 手动标注。
    public mutating func toggleImageSupport(_ modelID: String) {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if imageCapableModels.contains(normalized) {
            imageCapableModels.remove(normalized)
        } else {
            imageCapableModels.insert(normalized)
        }
    }

    /// 归一化模型列表：去空白、去重（保序），并保证当前 modelID 在列表中。
    static func normalizedModels(_ models: [String], ensuring modelID: String) -> [String] {
        var result: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        let trimmedCurrent = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrent.isEmpty, !result.contains(trimmedCurrent) {
            result.append(trimmedCurrent)
        }
        return result
    }

    /// 添加一个模型（去重；空串忽略）。
    public mutating func addModel(_ modelID: String) {
        models = Self.normalizedModels(models + [modelID], ensuring: self.modelID)
    }

    /// 移除一个模型；不允许删空列表，删掉的若是当前模型则回落到首个。
    public mutating func removeModel(_ modelID: String) {
        guard models.count > 1 else { return }
        models.removeAll { $0 == modelID }
        modelDefinitions.removeValue(forKey: modelID)  // 同步清理
        if self.modelID == modelID, let first = models.first {
            self.modelID = first
        }
    }

    /// 获取当前模型的 maxTokens（优先使用 modelDefinitions 中的值）。
    public var effectiveMaxTokens: Int {
        modelDefinition(for: modelID)?.maxOutputTokens ?? maxTokens
    }
    
    public var modelConfig: ModelConfig {
        ModelConfig(
            provider: preset.rawValue,
            modelID: modelID,
            thinkingLevel: thinkingLevel,
            maxTokens: effectiveMaxTokens
        )
    }

    public func option(_ key: ProviderOptionKey) -> String? {
        options[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public mutating func setOption(_ key: ProviderOptionKey, value: String?) {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            options[key.rawValue] = value
        } else {
            options.removeValue(forKey: key.rawValue)
        }
    }

    /// 验证并同步配置。返回是否发生了变更。
    @discardableResult
    public mutating func validateAndSync() throws -> Bool {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConfigError.emptyModelID
        }
        guard !models.isEmpty else {
            throw ProviderConfigError.emptyModelID
        }

        for field in preset.optionFields where field.required {
            guard option(field.key) != nil else {
                throw ProviderConfigError.missingRequiredOption(field.key)
            }
        }

        for field in preset.optionFields {
            guard let value = option(field.key) else { continue }
            if field.key == .baseURL {
                try ProviderURLValidator.validate(value, preset: preset)
            }
        }
        
        // 同步 modelDefinitions：清理不在 models 列表中的条目
        var changed = false
        let modelSet = Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for key in modelDefinitions.keys {
            if !modelSet.contains(key) {
                modelDefinitions.removeValue(forKey: key)
                changed = true
            }
        }
        
        return changed
    }
    
    public func validate() throws {
        var copy = self
        try copy.validateAndSync()
    }
}

public struct ProviderConfigFile: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public static let defaultAnthropicProfileID = "anthropic-default"

    public var version: Int
    public var defaultProfileID: String?
    public var profiles: [ProviderProfile]

    public init(version: Int = currentVersion, defaultProfileID: String? = nil, profiles: [ProviderProfile] = []) {
        self.version = version
        self.defaultProfileID = defaultProfileID
        self.profiles = profiles
    }

    public func defaultProfile() throws -> ProviderProfile {
        if let id = defaultProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        if let first = profiles.first {
            return first
        }
        throw ProviderConfigError.noProfiles
    }

    public mutating func validate() throws {
        var seen = Set<String>()
        for i in profiles.indices {
            if seen.contains(profiles[i].id) {
                throw ProviderConfigError.duplicateProfileID(profiles[i].id)
            }
            seen.insert(profiles[i].id)
            try profiles[i].validateAndSync()
        }
    }
}

enum ProviderURLValidator {
    static func validate(_ urlString: String, preset: ProviderPreset) throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw ProviderConfigError.invalidURL(urlString)
        }

        if preset == .ollama {
            let host = url.host?.lowercased() ?? ""
            guard scheme == "http", host == "127.0.0.1" || host == "localhost" else {
                throw ProviderConfigError.invalidURL("Ollama base URL must use http://127.0.0.1 or http://localhost")
            }
            return
        }

        guard scheme == "https" else {
            throw ProviderConfigError.invalidURL("Provider base URL must use HTTPS")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
