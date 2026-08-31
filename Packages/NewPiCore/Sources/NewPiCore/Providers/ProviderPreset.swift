import Foundation

public enum ProviderPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case openaiCompatible
    case openRouter
    case ollama
    case xiaomiMiMo

    public var id: String { rawValue }
}

public enum ProviderOptionKey: String, Sendable, Codable, CaseIterable {
    case baseURL
    case apiVersion
    case apiMode
    case organization
    case httpReferer
    case appTitle
}

public struct ProviderOptionField: Sendable, Equatable {
    public var key: ProviderOptionKey
    public var label: String
    public var placeholder: String
    public var required: Bool

    public init(key: ProviderOptionKey, label: String, placeholder: String = "", required: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.required = required
    }
}

public struct ProviderPresetDefinition: Sendable, Equatable {
    public var preset: ProviderPreset
    public var displayName: String
    public var systemImage: String
    public var defaultBaseURL: String?
    public var defaultModels: [String]
    /// 预设中已知支持图片识别的模型（新建 provider 时预填进 profile 的 imageCapableModels）。
    public var imageCapableModels: Set<String>
    public var optionFields: [ProviderOptionField]
    public var credentialRequired: Bool
    public var environmentVariable: String?
    public var quickSetupDefaults: [ProviderOptionKey: String]

    public init(
        preset: ProviderPreset,
        displayName: String,
        systemImage: String,
        defaultBaseURL: String? = nil,
        defaultModels: [String] = [],
        imageCapableModels: Set<String> = [],
        optionFields: [ProviderOptionField] = [],
        credentialRequired: Bool = true,
        environmentVariable: String? = nil,
        quickSetupDefaults: [ProviderOptionKey: String] = [:]
    ) {
        self.preset = preset
        self.displayName = displayName
        self.systemImage = systemImage
        self.defaultBaseURL = defaultBaseURL
        self.defaultModels = defaultModels
        self.imageCapableModels = imageCapableModels
        self.optionFields = optionFields
        self.credentialRequired = credentialRequired
        self.environmentVariable = environmentVariable
        self.quickSetupDefaults = quickSetupDefaults
    }
}

public enum ProviderPresetCatalog {
    public static let anthropic = ProviderPresetDefinition(
        preset: .anthropic,
        displayName: "Anthropic",
        systemImage: "sparkles",
        defaultBaseURL: "https://api.anthropic.com/v1/messages",
        defaultModels: [
            "claude-sonnet-4-5",
            "claude-opus-4-1",
            "claude-sonnet-4-20250514",
            "claude-opus-4-20250514",
            "claude-3-5-haiku-20241022",
        ],
        imageCapableModels: [
            "claude-sonnet-4-5",
            "claude-opus-4-1",
            "claude-sonnet-4-20250514",
            "claude-opus-4-20250514",
            "claude-3-5-haiku-20241022",
        ],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.anthropic.com/v1/messages"),
            ProviderOptionField(key: .apiVersion, label: "API Version", placeholder: "2023-06-01"),
        ],
        credentialRequired: true,
        environmentVariable: "ANTHROPIC_API_KEY"
    )

    public static let openai = ProviderPresetDefinition(
        preset: .openai,
        displayName: "OpenAI",
        systemImage: "brain.head.profile",
        defaultBaseURL: "https://api.openai.com/v1/chat/completions",
        defaultModels: ["gpt-5", "gpt-5-mini", "gpt-4o", "gpt-4o-mini", "gpt-4.1-mini"],
        imageCapableModels: ["gpt-5", "gpt-5-mini", "gpt-4o", "gpt-4o-mini", "gpt-4.1-mini"],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.openai.com/v1/chat/completions"),
            ProviderOptionField(key: .organization, label: "Organization ID", placeholder: "org-…"),
        ],
        credentialRequired: true,
        environmentVariable: "OPENAI_API_KEY"
    )

    public static let openaiCompatible = ProviderPresetDefinition(
        preset: .openaiCompatible,
        displayName: "OpenAI Compatible",
        systemImage: "server.rack",
        defaultModels: ["deepseek-chat", "llama3", "qwen2.5-coder"],
        optionFields: [
            ProviderOptionField(
                key: .baseURL,
                label: "Base URL",
                placeholder: "https://api.example.com/v1/chat/completions",
                required: true
            ),
            ProviderOptionField(key: .organization, label: "Organization ID", placeholder: "Optional"),
        ],
        credentialRequired: true,
        environmentVariable: "OPENAI_API_KEY"
    )

    public static let openRouter = ProviderPresetDefinition(
        preset: .openRouter,
        displayName: "OpenRouter",
        systemImage: "arrow.triangle.branch",
        defaultBaseURL: "https://openrouter.ai/api/v1/chat/completions",
        defaultModels: [
            "anthropic/claude-sonnet-4.5",
            "anthropic/claude-sonnet-4",
            "openai/gpt-5",
            "openai/gpt-4o",
            "google/gemini-2.5-pro",
            "deepseek/deepseek-chat",
        ],
        imageCapableModels: [
            "anthropic/claude-sonnet-4.5",
            "anthropic/claude-sonnet-4",
            "openai/gpt-5",
            "openai/gpt-4o",
            "google/gemini-2.5-pro",
        ],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://openrouter.ai/api/v1/chat/completions"),
            ProviderOptionField(key: .httpReferer, label: "HTTP Referer", placeholder: "https://your-app.example"),
            ProviderOptionField(key: .appTitle, label: "App Title", placeholder: "NewPi"),
        ],
        credentialRequired: true,
        environmentVariable: "OPENROUTER_API_KEY",
        quickSetupDefaults: [
            .baseURL: "https://openrouter.ai/api/v1/chat/completions",
        ]
    )

    public static let ollama = ProviderPresetDefinition(
        preset: .ollama,
        displayName: "Ollama",
        systemImage: "desktopcomputer",
        defaultBaseURL: "http://127.0.0.1:11434",
        defaultModels: ["llama3", "qwen2.5-coder", "codellama", "deepseek-r1", "mistral"],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "http://127.0.0.1:11434"),
        ],
        credentialRequired: false,
        quickSetupDefaults: [
            .baseURL: "http://127.0.0.1:11434",
        ]
    )

    public static let xiaomiMiMo = ProviderPresetDefinition(
        preset: .xiaomiMiMo,
        displayName: "Xiaomi MiMo",
        systemImage: "bolt.horizontal.circle.fill",
        defaultBaseURL: "https://api.xiaomimimo.com/v1/chat/completions",
        defaultModels: [
            "mimo-v2.5-pro",
            "mimo-v2.5-flash",
        ],
        imageCapableModels: [
            "mimo-v2.5-pro",
        ],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.xiaomimimo.com/v1/chat/completions"),
        ],
        credentialRequired: true,
        environmentVariable: "MIMO_API_KEY",
        quickSetupDefaults: [
            .baseURL: "https://api.xiaomimimo.com/v1/chat/completions",
            .apiMode: ProviderAPIMode.chatCompletions.rawValue,
        ]
    )

    /// MiMo Anthropic 兼容接口（支持 extended thinking）。
    public static let xiaomiMiMoAnthropic = ProviderPresetDefinition(
        preset: .anthropic,
        displayName: "Xiaomi MiMo (Anthropic)",
        systemImage: "bolt.circle.fill",
        defaultBaseURL: "https://api.xiaomimimo.com/anthropic/v1/messages",
        defaultModels: [
            "mimo-v2.5-pro",
            "mimo-v2.5-flash",
        ],
        imageCapableModels: [
            "mimo-v2.5-pro",
        ],
        optionFields: [
            ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.xiaomimimo.com/anthropic/v1/messages"),
            ProviderOptionField(key: .apiVersion, label: "API Version", placeholder: "2023-06-01"),
        ],
        credentialRequired: true,
        environmentVariable: "MIMO_API_KEY",
        quickSetupDefaults: [
            .baseURL: "https://api.xiaomimimo.com/anthropic/v1/messages",
        ]
    )

    public static let deepSeekQuickSetup = ProviderPresetDefinition(
        preset: .openaiCompatible,
        displayName: "DeepSeek",
        systemImage: "bolt.fill",
        defaultBaseURL: "https://api.deepseek.com/v1/chat/completions",
        defaultModels: ["deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"],
        optionFields: openaiCompatible.optionFields,
        credentialRequired: true,
        environmentVariable: "OPENAI_API_KEY",
        quickSetupDefaults: [
            .baseURL: "https://api.deepseek.com/v1/chat/completions",
            .apiMode: ProviderAPIMode.chatCompletions.rawValue,
        ]
    )

    public static let deepSeekResponsesQuickSetup = ProviderPresetDefinition(
        preset: .openaiCompatible,
        displayName: "DeepSeek (Responses)",
        systemImage: "bolt.circle.fill",
        defaultBaseURL: "https://api.deepseek.com",
        defaultModels: [
            "deepseek-v4-flash",
            "deepseek-v4-pro",
            "deepseek-v4-flash-vision-exp",
        ],
        imageCapableModels: ["deepseek-v4-flash-vision-exp"],
        optionFields: openaiCompatible.optionFields,
        credentialRequired: true,
        environmentVariable: "OPENAI_API_KEY",
        quickSetupDefaults: [
            .baseURL: "https://api.deepseek.com",
            .apiMode: ProviderAPIMode.responses.rawValue,
        ]
    )

    public static func definition(for preset: ProviderPreset) -> ProviderPresetDefinition {
        switch preset {
        case .anthropic: anthropic
        case .openai: openai
        case .openaiCompatible: openaiCompatible
        case .openRouter: openRouter
        case .ollama: ollama
        case .xiaomiMiMo: xiaomiMiMo
        }
    }

    /// 所有 MiMo 相关预设（OpenAI 兼容 + Anthropic 兼容）。
    public static var xiaomiMiMoPresets: [ProviderPresetDefinition] {
        [xiaomiMiMo, xiaomiMiMoAnthropic]
    }

    public static var quickAddTemplates: [ProviderPresetDefinition] {
        [
            anthropic,
            openai,
            deepSeekQuickSetup,
            deepSeekResponsesQuickSetup,
            openRouter,
            xiaomiMiMo,
            xiaomiMiMoAnthropic,
            ollama,
            openaiCompatible,
        ]
    }
}
