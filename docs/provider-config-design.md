# Provider 配置方案设计文档

## 概述

设计一个灵活的 Provider 配置系统，支持：
- 知名厂商预设（预填配置，减少用户输入）
- 自定义端点配置
- Token Plan 和 API Key 两种使用模式
- 模型级别的详细配置（能力、价格、context window 等）

## 核心数据结构

### ProviderProfile（用户配置）

```swift
public struct ProviderProfile: Codable, Identifiable {
    public var id: String                    // UUID
    public var name: String                  // 显示名称
    public var icon: String                  // SF Symbols 名称
    public var apiMode: APIMode              // openai-chat / anthropic-messages / responses
    public var baseUrl: String               // 基础 URL
    public var apiKeyHeader: String          // API Key Header 名称
    public var apiKey: String?               // API Key（加密存储）
    public var models: [ModelDefinition]     // 模型列表
    public var defaultModelID: String        // 默认模型
}
```

### ModelDefinition（模型定义）

```swift
public struct ModelDefinition: Codable, Identifiable {
    public var id: String                    // 模型 ID
    public var name: String                  // 显示名称
    public var contextWindow: Int            // 上下文窗口（token 数）
    public var maxOutputTokens: Int          // 最大输出 token
    public var capabilities: ModelCapabilities  // 能力标记
    public var pricing: ModelPricing?        // 价格（可选）
    public var thinkingLevels: [String: Int]? // thinking 级别映射（可选）
}

public struct ModelCapabilities: Codable {
    public var reasoning: Bool               // 支持推理/思考
    public var image: Bool                   // 支持图片输入
    public var toolUse: Bool                 // 支持工具调用
    public var streaming: Bool               // 支持流式输出
}

public struct ModelPricing: Codable {
    public var input: Double                 // 输入价格（每 1M token）
    public var output: Double                // 输出价格
    public var cacheRead: Double?            // 缓存读取价格
    public var cacheWrite: Double?           // 缓存写入价格
    public var currency: Currency            // USD / CNY
}

public enum Currency: String, Codable {
    case usd = "USD"
    case cny = "CNY"
}
```

### VendorPreset（厂商预设）

```swift
public struct VendorPreset: Identifiable {
    public var id: String                    // 预设 ID
    public var displayName: String           // 显示名称
    public var icon: String                  // SF Symbols
    public var apiMode: APIMode
    public var baseUrl: String
    public var apiKeyHeader: String
    public var apiKeyPlaceholder: String?
    public var defaultModels: [ModelDefinition]
    public var description: String?
}
```

## 知名厂商预设列表

| 厂商 | 预设 ID | Base URL | API 类型 | Key Header | 预填模型 |
|------|---------|----------|----------|------------|----------|
| 小米 MiMo (Token Plan) | xiaomi-mimo-token-plan | api.xiaomimimo.com/v1/chat/completions | openai-chat | api-key | mimo-v2.5-pro, mimo-v2.5-flash |
| 小米 MiMo (API Key) | xiaomi-mimo-api-key | api.xiaomimimo.com/v1/chat/completions | openai-chat | api-key | 同上 |
| Kimi (Token Plan) | kimi-token-plan | api.moonshot.cn/v1/chat/completions | openai-chat | Authorization | moonshot-v1-8k/32k/128k, kimi-k2 |
| Kimi (API Key) | kimi-api-key | api.moonshot.cn/v1/chat/completions | openai-chat | Authorization | 同上 |
| 阿里云百炼 | aliyun-dashscope | dashscope.aliyuncs.com/compatible-mode/v1/chat/completions | openai-chat | Authorization | qwen-turbo/plus/max/long |
| 硅基流动 | siliconflow | api.siliconflow.cn/v1/chat/completions | openai-chat | Authorization | Qwen2.5, DeepSeek-V2.5 等 |
| 火山引擎 | volcengine | ark.cn-beijing.volces.com/api/v3/chat/completions | openai-chat | Authorization | 需配置 endpoint_id |
| DeepSeek | deepseek | api.deepseek.com/v1/chat/completions | openai-chat | Authorization | deepseek-chat, deepseek-reasoner |
| GLM (Token Plan) | glm-token-plan | open.bigmodel.cn/api/paas/v4/chat/completions | openai-chat | Authorization | glm-4, glm-4-flash, glm-4v |
| GLM (API Key) | glm-api-key | open.bigmodel.cn/api/paas/v4/chat/completions | openai-chat | Authorization | 同上 |
| OpenRouter | openrouter | openrouter.ai/api/v1/chat/completions | openai-chat | Authorization | 各厂商聚合 |
| Ollama (本地) | ollama | 127.0.0.1:11434/v1/chat/completions | openai-chat | Authorization | llama3, qwen2, deepseek-coder |

## 功能清单

| 功能 | 说明 |
|------|------|
| 添加入口 | 知名厂商列表 / 自定义端点 |
| API 类型 | OpenAI Chat / Anthropic Messages / Responses |
| 认证 | API Key，Header 名称可配置 |
| Base URL | 用户填前缀，后缀从下拉选择 |
| 模型发现 | 手动点击"刷新模型列表"按钮 |
| 模型能力 | reasoning / image / tool_use / streaming |
| 价格 | 输入/输出/缓存读/缓存写，USD/CNY |
| Context Window | 用于状态栏显示占用百分比 |
| Thinking 级别 | 可配置级别映射 |
| 多实例 | 允许多个相同厂商的 provider |
| 排序 | 按厂商名排序 |
| 默认 | 全局一个默认 provider + 默认模型 |
| 编辑 | 所有字段可修改 |
| 删除 | 需要确认 |
| 图标 | SF Symbols 名称 |

## 配置文件格式

```json
{
  "version": 2,
  "defaultProviderID": "xiaomi-mimo-token-plan",
  "defaultModelID": "mimo-v2.5-pro",
  "profiles": [
    {
      "id": "xiaomi-mimo-token-plan",
      "name": "小米 MiMo (Token Plan)",
      "icon": "bolt.horizontal.circle.fill",
      "apiMode": "openai-chat",
      "baseUrl": "https://api.xiaomimimo.com/v1/chat/completions",
      "apiKeyHeader": "api-key",
      "apiKey": "encrypted_xxx",
      "defaultModelID": "mimo-v2.5-pro",
      "models": [
        {
          "id": "mimo-v2.5-pro",
          "name": "MiMo v2.5 Pro",
          "contextWindow": 131072,
          "maxOutputTokens": 8192,
          "capabilities": {
            "reasoning": true,
            "image": true,
            "toolUse": true,
            "streaming": true
          },
          "pricing": {
            "input": 2,
            "output": 8,
            "cacheRead": 0.5,
            "cacheWrite": 0,
            "currency": "CNY"
          }
        }
      ]
    }
  ]
}
```

## UI 流程

### 添加知名厂商

```
┌─────────────────────────────────────┐
│         添加 Provider               │
├─────────────────────────────────────┤
│  知名厂商                            │
│  ┌─────────────────────────────┐    │
│  │ 小米 MiMo (Token Plan)      │    │
│  │ 小米 MiMo (API Key)         │    │
│  │ Kimi (Token Plan)           │    │
│  │ Kimi (API Key)              │    │
│  │ 阿里云百炼                  │    │
│  │ ...                         │    │
│  └─────────────────────────────┘    │
│                                     │
│  [自定义端点]                        │
└─────────────────────────────────────┘
```

### 配置详情

```
┌─────────────────────────────────────┐
│  小米 MiMo (Token Plan)             │
├─────────────────────────────────────┤
│  API Key: [____________________]    │
│  提示: 输入小米 API Key              │
│                                     │
│  预填配置:                           │
│  • API 类型: OpenAI Chat             │
│  • Base URL: api.xiaomimimo.com/... │
│  • 模型: mimo-v2.5-pro/flash        │
│                                     │
│           [取消]    [添加]           │
└─────────────────────────────────────┘
```
