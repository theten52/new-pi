import Foundation

/// Provider 协议实现分类。决定用哪个请求构造器（Anthropic / OpenAI 兼容 / Responses）
/// 以及该协议的固有元数据（是否需要 API Key、支持的 Options 字段、兜底 URL 等）。
///
/// 注意：这是「协议实现」的分类器，不是用户可编辑的模板。用户自定义厂商模板时，
/// 只能从这些协议里选一个（不能发明新协议，因为请求构造器是硬编码的）。
public enum ProviderPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case openaiCompatible
    case openRouter
    case ollama
    case xiaomiMiMo

    public var id: String { rawValue }
}

/// Provider 可配置项（存进 `ProviderProfile.options`）。
public enum ProviderOptionKey: String, Sendable, Codable, CaseIterable {
    case baseURL
    case apiVersion
    case apiMode
    case organization
    case httpReferer
    case appTitle
}

/// Options 表单字段描述（决定 Settings 里显示哪些输入框）。
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

// MARK: - 协议固有元数据

extension ProviderPreset {
    /// 是否需要 API Key（Ollama 本地无需）。
    public var credentialRequired: Bool {
        self != .ollama
    }

    /// 该协议是否支持 API Mode（Responses）选择。
    public var supportsResponses: Bool {
        switch self {
        case .openai, .openaiCompatible, .openRouter, .xiaomiMiMo:
            true
        case .anthropic, .ollama:
            false
        }
    }

    /// 环境变量名（用于从环境读取 API Key 兜底）。
    public var environmentVariable: String? {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai, .openaiCompatible: "OPENAI_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        case .ollama: nil
        case .xiaomiMiMo: "MIMO_API_KEY"
        }
    }

    /// 协议显示名。
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .openaiCompatible: "OpenAI Compatible"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .xiaomiMiMo: "Xiaomi MiMo"
        }
    }

    /// 协议图标（SF Symbols）。
    public var systemImage: String {
        switch self {
        case .anthropic: "sparkles"
        case .openai: "brain.head.profile"
        case .openaiCompatible: "server.rack"
        case .openRouter: "arrow.triangle.branch"
        case .ollama: "desktopcomputer"
        case .xiaomiMiMo: "bolt.horizontal.circle.fill"
        }
    }

    /// 兜底 Base URL（profile.options 缺 baseURL 时使用；自定义端点无默认）。
    public var defaultBaseURL: String? {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .openai: "https://api.openai.com/v1/chat/completions"
        case .openaiCompatible: nil
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .ollama: "http://127.0.0.1:11434"
        case .xiaomiMiMo: "https://api.xiaomimimo.com/v1/chat/completions"
        }
    }

    /// 该协议支持的 Options 表单字段。
    public var optionFields: [ProviderOptionField] {
        switch self {
        case .anthropic:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.anthropic.com/v1/messages"),
                ProviderOptionField(key: .apiVersion, label: "API Version", placeholder: "2023-06-01"),
            ]
        case .openai:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.openai.com/v1/chat/completions"),
                ProviderOptionField(key: .organization, label: "Organization ID", placeholder: "org-…"),
            ]
        case .openaiCompatible:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.example.com/v1/chat/completions", required: true),
                ProviderOptionField(key: .organization, label: "Organization ID", placeholder: "Optional"),
            ]
        case .openRouter:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://openrouter.ai/api/v1/chat/completions"),
                ProviderOptionField(key: .httpReferer, label: "HTTP Referer", placeholder: "https://your-app.example"),
                ProviderOptionField(key: .appTitle, label: "App Title", placeholder: "NewPi"),
            ]
        case .ollama:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "http://127.0.0.1:11434"),
            ]
        case .xiaomiMiMo:
            [
                ProviderOptionField(key: .baseURL, label: "Base URL", placeholder: "https://api.xiaomimimo.com/v1/chat/completions"),
            ]
        }
    }
}
