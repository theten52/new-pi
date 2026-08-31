import Foundation

// MARK: - 模型定义

/// 模型能力标记
public struct ModelCapabilities: Codable, Equatable, Sendable {
    public var reasoning: Bool    // 支持推理/思考
    public var image: Bool        // 支持图片输入
    public var toolUse: Bool      // 支持工具调用
    public var streaming: Bool    // 支持流式输出
    
    public init(
        reasoning: Bool = false,
        image: Bool = false,
        toolUse: Bool = true,
        streaming: Bool = true
    ) {
        self.reasoning = reasoning
        self.image = image
        self.toolUse = toolUse
        self.streaming = streaming
    }
}

/// 货币类型
public enum Currency: String, Codable, Sendable {
    case usd = "USD"
    case cny = "CNY"
}

/// 模型价格（每 1M token）
public struct ModelPricing: Codable, Equatable, Sendable {
    public var input: Double      // 输入价格
    public var output: Double     // 输出价格
    public var cacheRead: Double? // 缓存读取价格
    public var cacheWrite: Double? // 缓存写入价格
    public var currency: Currency
    
    public init(
        input: Double,
        output: Double,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil,
        currency: Currency = .usd
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.currency = currency
    }
}

/// Thinking 级别配置
public struct ThinkingLevelConfig: Codable, Equatable, Sendable {
    /// 级别名称到 budget_tokens 的映射
    public var levels: [String: Int]
    
    public init(levels: [String: Int] = [:]) {
        self.levels = levels
    }
}

/// 模型定义
public struct ModelDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String                    // 模型 ID
    public var name: String                  // 显示名称
    public var contextWindow: Int            // 上下文窗口（token 数）
    public var maxOutputTokens: Int          // 最大输出 token
    public var capabilities: ModelCapabilities
    public var pricing: ModelPricing?
    public var thinkingLevels: ThinkingLevelConfig?
    
    public init(
        id: String,
        name: String? = nil,
        contextWindow: Int = 128000,
        maxOutputTokens: Int = 8192,
        capabilities: ModelCapabilities = ModelCapabilities(),
        pricing: ModelPricing? = nil,
        thinkingLevels: ThinkingLevelConfig? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.pricing = pricing
        self.thinkingLevels = thinkingLevels
    }
}

// MARK: - 厂商预设

/// 厂商预设配置
public struct VendorPreset: Identifiable, Sendable {
    public var id: String                    // 预设 ID
    public var displayName: String           // 显示名称
    public var icon: String                  // SF Symbols 名称
    public var apiMode: ProviderAPIMode      // chatCompletions / responses
    public var preset: ProviderPreset        // 使用哪个 provider 实现
    public var baseUrl: String
    public var apiKeyHeader: String
    public var apiKeyPlaceholder: String?
    public var defaultModels: [ModelDefinition]
    public var description: String?
    
    public init(
        id: String,
        displayName: String,
        icon: String,
        apiMode: ProviderAPIMode = .chatCompletions,
        preset: ProviderPreset = .openaiCompatible,
        baseUrl: String,
        apiKeyHeader: String,
        apiKeyPlaceholder: String? = nil,
        defaultModels: [ModelDefinition],
        description: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.apiMode = apiMode
        self.preset = preset
        self.baseUrl = baseUrl
        self.apiKeyHeader = apiKeyHeader
        self.apiKeyPlaceholder = apiKeyPlaceholder
        self.defaultModels = defaultModels
        self.description = description
    }
}

// MARK: - 知名厂商预设列表

public enum VendorPresets {
    
    /// 所有内置厂商预设
    public static let all: [VendorPreset] = [
        xiaomiMiMoTokenPlan,
        xiaomiMiMoApiKey,
        xiaomiMiMoAnthropic,
        kimiTokenPlan,
        kimiApiKey,
        aliyunDashscope,
        siliconflow,
        volcengine,
        deepseek,
        glmTokenPlan,
        glmApiKey,
        openRouter,
        ollama,
    ]
    
    /// 根据 ID 查找预设
    public static func find(by id: String) -> VendorPreset? {
        all.first { $0.id == id }
    }
    
    /// 将 VendorPreset 转换为 ProviderProfile
    public static func makeProfile(from preset: VendorPreset) -> ProviderProfile {
        let models = preset.defaultModels.map { $0.id }
        return ProviderProfile(
            id: preset.id,
            name: preset.displayName,
            preset: preset.preset,
            modelID: models.first ?? "default",
            models: models,
            imageCapableModels: Set(preset.defaultModels.filter { $0.capabilities.image }.map { $0.id }),
            maxTokens: preset.defaultModels.first?.maxOutputTokens ?? 8192,
            options: [
                ProviderOptionKey.baseURL.rawValue: preset.baseUrl,
                ProviderOptionKey.apiMode.rawValue: preset.apiMode.rawValue,
            ]
        )
    }
    
    // MARK: - 小米 MiMo
    
    /// 小米 MiMo (Token Plan)
    public static let xiaomiMiMoTokenPlan = VendorPreset(
        id: "xiaomi-mimo-token-plan",
        displayName: "小米 MiMo (Token Plan)",
        icon: "bolt.horizontal.circle.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.xiaomimimo.com/v1/chat/completions",
        apiKeyHeader: "api-key",
        apiKeyPlaceholder: "输入小米 API Key",
        defaultModels: [
            ModelDefinition(
                id: "mimo-v2.5-pro",
                name: "MiMo v2.5 Pro",
                contextWindow: 131072,
                maxOutputTokens: 8192,
                capabilities: ModelCapabilities(reasoning: true, image: true, toolUse: true, streaming: true),
                pricing: ModelPricing(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 0, currency: .cny)
            ),
            ModelDefinition(
                id: "mimo-v2.5-flash",
                name: "MiMo v2.5 Flash",
                contextWindow: 131072,
                maxOutputTokens: 8192,
                capabilities: ModelCapabilities(reasoning: false, image: false, toolUse: true, streaming: true),
                pricing: ModelPricing(input: 0.5, output: 2, cacheRead: 0.1, cacheWrite: 0, currency: .cny)
            ),
        ],
        description: "使用小米 Token Plan"
    )
    
    /// 小米 MiMo (API Key)
    public static let xiaomiMiMoApiKey = VendorPreset(
        id: "xiaomi-mimo-api-key",
        displayName: "小米 MiMo (API Key)",
        icon: "bolt.horizontal.circle.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.xiaomimimo.com/v1/chat/completions",
        apiKeyHeader: "api-key",
        apiKeyPlaceholder: "输入小米 API Key",
        defaultModels: xiaomiMiMoTokenPlan.defaultModels,
        description: "使用小米 API Key"
    )
    
    /// 小米 MiMo (Anthropic 兼容)
    public static let xiaomiMiMoAnthropic = VendorPreset(
        id: "xiaomi-mimo-anthropic",
        displayName: "小米 MiMo (Anthropic)",
        icon: "bolt.circle.fill",
        apiMode: .chatCompletions,
        preset: .anthropic,
        baseUrl: "https://api.xiaomimimo.com/anthropic/v1/messages",
        apiKeyHeader: "x-api-key",
        apiKeyPlaceholder: "输入小米 API Key",
        defaultModels: xiaomiMiMoTokenPlan.defaultModels,
        description: "使用 Anthropic 兼容接口"
    )
    
    // MARK: - Kimi
    
    /// Kimi (Token Plan)
    public static let kimiTokenPlan = VendorPreset(
        id: "kimi-token-plan",
        displayName: "Kimi (Token Plan)",
        icon: "moon.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.moonshot.cn/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-...",
        defaultModels: [
            ModelDefinition(id: "moonshot-v1-8k", name: "Moonshot v1 8K", contextWindow: 8192, maxOutputTokens: 4096),
            ModelDefinition(id: "moonshot-v1-32k", name: "Moonshot v1 32K", contextWindow: 32768, maxOutputTokens: 8192),
            ModelDefinition(id: "moonshot-v1-128k", name: "Moonshot v1 128K", contextWindow: 131072, maxOutputTokens: 8192),
            ModelDefinition(
                id: "kimi-k2",
                name: "Kimi K2",
                contextWindow: 131072,
                maxOutputTokens: 16384,
                capabilities: ModelCapabilities(reasoning: true, image: true, toolUse: true, streaming: true)
            ),
        ],
        description: "使用 Kimi Token Plan"
    )
    
    /// Kimi (API Key)
    public static let kimiApiKey = VendorPreset(
        id: "kimi-api-key",
        displayName: "Kimi (API Key)",
        icon: "moon.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.moonshot.cn/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-...",
        defaultModels: kimiTokenPlan.defaultModels,
        description: "使用 Kimi API Key"
    )
    
    // MARK: - 阿里云百炼
    
    /// 阿里云百炼 (DashScope)
    public static let aliyunDashscope = VendorPreset(
        id: "aliyun-dashscope",
        displayName: "阿里云百炼",
        icon: "cloud.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-...",
        defaultModels: [
            ModelDefinition(id: "qwen-turbo", name: "Qwen Turbo", contextWindow: 131072, maxOutputTokens: 8192),
            ModelDefinition(id: "qwen-plus", name: "Qwen Plus", contextWindow: 131072, maxOutputTokens: 8192),
            ModelDefinition(id: "qwen-max", name: "Qwen Max", contextWindow: 131072, maxOutputTokens: 8192),
            ModelDefinition(id: "qwen-long", name: "Qwen Long", contextWindow: 10000000, maxOutputTokens: 8192),
        ]
    )
    
    // MARK: - 硅基流动
    
    /// 硅基流动 (SiliconFlow)
    public static let siliconflow = VendorPreset(
        id: "siliconflow",
        displayName: "硅基流动",
        icon: "cpu.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.siliconflow.cn/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-...",
        defaultModels: [
            ModelDefinition(id: "Qwen/Qwen2.5-7B-Instruct", name: "Qwen2.5 7B", contextWindow: 131072, maxOutputTokens: 8192),
            ModelDefinition(id: "deepseek-ai/DeepSeek-V2.5", name: "DeepSeek V2.5", contextWindow: 131072, maxOutputTokens: 8192),
        ]
    )
    
    // MARK: - 火山引擎
    
    /// 火山引擎 (豆包)
    public static let volcengine = VendorPreset(
        id: "volcengine",
        displayName: "火山引擎 (豆包)",
        icon: "flame.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer xxx",
        defaultModels: [
            ModelDefinition(id: "endpoint-id", name: "推理接入点 (需在控制台创建)", contextWindow: 131072, maxOutputTokens: 8192),
        ],
        description: "需要在火山引擎控制台创建推理接入点"
    )
    
    // MARK: - DeepSeek
    
    /// DeepSeek
    public static let deepseek = VendorPreset(
        id: "deepseek",
        displayName: "DeepSeek",
        icon: "bolt.fill",
        apiMode: .chatCompletions,
        baseUrl: "https://api.deepseek.com/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-...",
        defaultModels: [
            ModelDefinition(
                id: "deepseek-chat",
                name: "DeepSeek Chat",
                contextWindow: 65536,
                maxOutputTokens: 8192,
                capabilities: ModelCapabilities(reasoning: false, image: false, toolUse: true, streaming: true)
            ),
            ModelDefinition(
                id: "deepseek-reasoner",
                name: "DeepSeek Reasoner",
                contextWindow: 65536,
                maxOutputTokens: 8192,
                capabilities: ModelCapabilities(reasoning: true, image: false, toolUse: true, streaming: true)
            ),
        ]
    )
    
    // MARK: - GLM (智谱)
    
    /// GLM (Token Plan)
    public static let glmTokenPlan = VendorPreset(
        id: "glm-token-plan",
        displayName: "GLM 智谱 (Token Plan)",
        icon: "sparkles",
        apiMode: .chatCompletions,
        baseUrl: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer xxx",
        defaultModels: [
            ModelDefinition(id: "glm-4", name: "GLM-4", contextWindow: 128000, maxOutputTokens: 8192),
            ModelDefinition(id: "glm-4-flash", name: "GLM-4 Flash", contextWindow: 128000, maxOutputTokens: 8192),
            ModelDefinition(
                id: "glm-4v",
                name: "GLM-4V",
                contextWindow: 2000,
                maxOutputTokens: 1024,
                capabilities: ModelCapabilities(image: true)
            ),
        ],
        description: "使用智谱 Token Plan"
    )
    
    /// GLM (API Key)
    public static let glmApiKey = VendorPreset(
        id: "glm-api-key",
        displayName: "GLM 智谱 (API Key)",
        icon: "sparkles",
        apiMode: .chatCompletions,
        baseUrl: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer xxx",
        defaultModels: glmTokenPlan.defaultModels,
        description: "使用智谱 API Key"
    )
    
    // MARK: - OpenRouter
    
    /// OpenRouter
    public static let openRouter = VendorPreset(
        id: "openrouter",
        displayName: "OpenRouter",
        icon: "arrow.triangle.branch",
        apiMode: .chatCompletions,
        baseUrl: "https://openrouter.ai/api/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "Bearer sk-or-...",
        defaultModels: [
            ModelDefinition(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4", contextWindow: 200000, maxOutputTokens: 8192),
            ModelDefinition(id: "openai/gpt-4o", name: "GPT-4o", contextWindow: 128000, maxOutputTokens: 16384),
            ModelDefinition(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro", contextWindow: 1000000, maxOutputTokens: 65536),
        ]
    )
    
    // MARK: - Ollama
    
    /// Ollama (本地部署)
    public static let ollama = VendorPreset(
        id: "ollama",
        displayName: "Ollama (本地)",
        icon: "desktopcomputer",
        apiMode: .chatCompletions,
        baseUrl: "http://127.0.0.1:11434/v1/chat/completions",
        apiKeyHeader: "Authorization",
        apiKeyPlaceholder: "可留空",
        defaultModels: [
            ModelDefinition(
                id: "llama3",
                name: "Llama 3",
                contextWindow: 8192,
                maxOutputTokens: 4096,
                pricing: ModelPricing(input: 0, output: 0, currency: .usd)
            ),
            ModelDefinition(
                id: "qwen2.5",
                name: "Qwen 2.5",
                contextWindow: 32768,
                maxOutputTokens: 8192,
                pricing: ModelPricing(input: 0, output: 0, currency: .usd)
            ),
            ModelDefinition(
                id: "deepseek-coder",
                name: "DeepSeek Coder",
                contextWindow: 16384,
                maxOutputTokens: 4096,
                pricing: ModelPricing(input: 0, output: 0, currency: .usd)
            ),
        ],
        description: "本地部署，无需 API Key"
    )
}
