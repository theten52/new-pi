import Foundation
import Testing
@testable import NewPiCore

@Suite("ProviderProfile")
struct ProviderProfileTests {
    @Test("validates openaiCompatible requires baseURL")
    func openaiCompatibleRequiresBaseURL() throws {
        var profile = ProviderProfile(
            name: "Custom",
            preset: .openaiCompatible,
            modelID: "test-model",
            options: [:]
        )
        #expect(throws: ProviderConfigError.self) {
            try profile.validate()
        }

        profile.setOption(.baseURL, value: "https://api.example.com/v1/chat/completions")
        try profile.validate()
    }

    @Test("ollama allows localhost http URL")
    func ollamaLocalhost() throws {
        let profile = ProviderProfile(
            name: "Ollama",
            preset: .ollama,
            modelID: "llama3",
            options: ["baseURL": "http://127.0.0.1:11434"]
        )
        try profile.validate()
    }

    @Test("modelConfig uses preset raw value")
    func modelConfigProvider() {
        let profile = ProviderProfile(
            name: "Anthropic",
            preset: .anthropic,
            modelID: "claude-sonnet-4-20250514"
        )
        #expect(profile.modelConfig.provider == "anthropic")
        #expect(profile.modelConfig.modelID == "claude-sonnet-4-20250514")
    }
}

@Suite("ProviderConfigStore")
struct ProviderConfigStoreTests {
    @Test("round-trips config JSON")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = directory.appendingPathComponent("providers.json")
        let store = ProviderConfigStore(
            configURL: configURL,
            credentialResolver: ProviderCredentialResolver(store: InMemoryCredentialStore())
        )

        var config = ProviderConfigStore.bootstrapDefaultConfig()
        let deepSeek = ProviderProfile.makeDefault(from: ProviderPresetCatalog.deepSeekQuickSetup, name: "DeepSeek")
        config.profiles.append(deepSeek)
        try store.save(config)

        let loaded = try store.load()
        #expect(loaded.profiles.count == 2)
        #expect(loaded.defaultProfileID == ProviderConfigFile.defaultAnthropicProfileID)
    }

    @Test("delete profile removes it and re-points default")
    func deleteProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = directory.appendingPathComponent("providers.json")
        let resolver = ProviderCredentialResolver(store: InMemoryCredentialStore())
        let store = ProviderConfigStore(configURL: configURL, credentialResolver: resolver)

        var config = ProviderConfigStore.bootstrapDefaultConfig()
        let deepSeek = ProviderProfile.makeDefault(from: ProviderPresetCatalog.deepSeekQuickSetup, name: "DeepSeek")
        config.profiles.append(deepSeek)
        try store.save(config)

        // 删除非默认的 DeepSeek：只移除该 profile，default 保持不变
        try store.deleteProfile(id: deepSeek.id, from: &config)
        #expect(config.profiles.count == 1)
        #expect(config.profiles.first?.id == ProviderConfigFile.defaultAnthropicProfileID)
        #expect(config.defaultProfileID == ProviderConfigFile.defaultAnthropicProfileID)

        // 删除默认的 Anthropic：default 重设为剩余第一个（此时只剩 DeepSeek 之外没有，回到 0 个）
        var single = config
        let defaultID = single.defaultProfileID
        try store.deleteProfile(id: defaultID!, from: &single)
        #expect(single.profiles.isEmpty)
        #expect(single.defaultProfileID == nil)

        // 持久化验证：重新 load 也应一致
        let reloaded = try store.load()
        #expect(reloaded.profiles.count == 0)
        #expect(reloaded.defaultProfileID == nil)
    }

    @Test("new profile becomes default")
    func newProfileDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = directory.appendingPathComponent("providers.json")
        let store = ProviderConfigStore(
            configURL: configURL,
            credentialResolver: ProviderCredentialResolver(store: InMemoryCredentialStore())
        )

        var config = ProviderConfigStore.bootstrapDefaultConfig()
        let deepSeek = ProviderProfile.makeDefault(from: ProviderPresetCatalog.deepSeekQuickSetup, name: "DeepSeek")
        try store.upsertProfile(deepSeek, in: &config)
        #expect(config.defaultProfileID == deepSeek.id)
    }

    @Test("migrates legacy anthropic keychain account")
    func legacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = directory.appendingPathComponent("providers.json")
        let memoryStore = InMemoryCredentialStore(secrets: [
            ProviderCredentialResolver.legacyAnthropicAccount: "sk-test-legacy",
        ])
        let store = ProviderConfigStore(
            configURL: configURL,
            credentialResolver: ProviderCredentialResolver(store: memoryStore)
        )

        let loaded = try store.load()
        #expect(loaded.profiles.count == 1)
        let migrated = try memoryStore.load(
            account: ProviderCredentialResolver.keychainAccount(for: ProviderConfigFile.defaultAnthropicProfileID)
        )
        #expect(migrated == "sk-test-legacy")
    }
}

@Suite("OpenAICompatibleEndpoint")
struct OpenAICompatibleEndpointTests {
    @Test("normalizes ollama chat completions URL")
    func ollamaURL() throws {
        let profile = ProviderProfile(
            name: "Ollama",
            preset: .ollama,
            modelID: "llama3",
            options: ["baseURL": "http://127.0.0.1:11434"]
        )
        let url = try OpenAICompatibleEndpoint.resolveURL(for: profile)
        #expect(url.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
    }

    @Test("uses explicit chat completions URL")
    func explicitURL() throws {
        let profile = ProviderProfile(
            name: "DeepSeek",
            preset: .openaiCompatible,
            modelID: "deepseek-chat",
            options: ["baseURL": "https://api.deepseek.com/v1/chat/completions"]
        )
        let url = try OpenAICompatibleEndpoint.resolveURL(for: profile)
        #expect(url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }
}

@Suite("SSEByteStreamParser")
struct SSEByteStreamParserTests {
    @Test("decodes UTF-8 CJK split across byte boundaries")
    func utf8CJK() {
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n"
        let bytes = Array(payload.utf8)

        var parser = SSEByteStreamParser()
        var blocks: [[String]] = []
        for byte in bytes {
            blocks.append(contentsOf: parser.feed(byte))
        }
        blocks.append(contentsOf: parser.finish())

        let joined = blocks.flatMap { $0 }.joined()
        #expect(joined.contains("你好"))
        #expect(!joined.contains("\u{FFFD}"))
    }

    @Test("handles newline at end of buffer without crashing")
    func newlineAtEnd() throws {
        var parser = SSEByteStreamParser()
        for byte in Array("data: ok\n".utf8) {
            _ = parser.feed(byte)
        }
        _ = parser.finish()
    }

    @Test("preserves partial lines across feed calls")
    func partialLinesAcrossFeeds() {
        let payload = "data: {\"content\":\"hi\"}\n\n"
        let bytes = Array(payload.utf8)
        let splitIndex = bytes.count / 2

        var parser = SSEByteStreamParser()
        var blocks: [[String]] = []
        for byte in bytes[..<splitIndex] {
            blocks.append(contentsOf: parser.feed(byte))
        }
        for byte in bytes[splitIndex...] {
            blocks.append(contentsOf: parser.feed(byte))
        }
        blocks.append(contentsOf: parser.finish())

        #expect(!blocks.isEmpty)
        #expect(blocks.flatMap { $0 }.joined().contains("data:"))
    }
}

@Suite("OpenAIStreamParser")
struct OpenAIStreamParserTests {
    @Test("parses text and tool call completion")
    func textAndTool() {
        let decoder = OpenAISSEDecoder()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}]}",
            "",
            "data: {\"choices\":[{\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}",
            "",
        ]

        var parser = OpenAIStreamParser()
        let events = parser.parse(events: decoder.decodeLines(lines))
        #expect(events.contains { if case let .textDelta(text) = $0 { text == "Hi" } else { false } })
        #expect(events.contains {
            if case let .toolCall(call) = $0 {
                call.id == "call_1" && call.name == "read"
            } else {
                false
            }
        })
    }
}

@Suite("OpenAICompatibleRequestPolicy")
struct OpenAICompatibleRequestPolicyTests {
    @Test("raises DeepSeek max tokens floor")
    func deepSeekMaxTokens() {
        let profile = ProviderProfile(
            name: "DeepSeek",
            preset: .openaiCompatible,
            modelID: "deepseek-v4-flash-vision-exp",
            maxTokens: 8192,
            options: ["baseURL": "https://api.deepseek.com/v1/chat/completions"]
        )
        let model = profile.modelConfig
        #expect(OpenAICompatibleRequestPolicy.effectiveMaxTokens(model: model, profile: profile) == 16_384)
    }

    @Test("disables DeepSeek thinking when tools are present")
    func disableThinkingForTools() {
        var body: [String: Any] = ["model": "deepseek-v4-flash"]
        let profile = ProviderProfile(
            name: "DeepSeek",
            preset: .openaiCompatible,
            modelID: "deepseek-v4-flash",
            options: ["baseURL": "https://api.deepseek.com/v1/chat/completions"]
        )
        OpenAICompatibleRequestPolicy.applyDeepSeekThinkingPolicy(
            body: &body,
            model: profile.modelConfig,
            profile: profile,
            hasTools: true
        )
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    }

    @Test("DeepSeek quick setup defaults to higher max tokens")
    func deepSeekProfileDefaults() {
        let profile = ProviderProfile.makeDefault(from: ProviderPresetCatalog.deepSeekQuickSetup, name: "DeepSeek")
        #expect(profile.maxTokens == 16_384)
    }
}

@Suite("LLMProviderFactory profile")
struct LLMProviderFactoryProfileTests {
    @Test("anthropic preset builds AnthropicProvider")
    func anthropicFactory() throws {
        let profile = ProviderProfile.makeDefault(from: ProviderPresetCatalog.anthropic)
        let resolver = ProviderCredentialResolver(store: InMemoryCredentialStore(secrets: [
            ProviderCredentialResolver.keychainAccount(for: profile.id): "sk-test",
        ]))
        let provider = try LLMProviderFactory.make(profile: profile, credentialResolver: resolver)
        #expect(provider is AnthropicProvider)
    }

    @Test("openai preset builds OpenAICompatibleProvider")
    func openaiFactory() throws {
        let profile = ProviderProfile.makeDefault(from: ProviderPresetCatalog.openai)
        let resolver = ProviderCredentialResolver(store: InMemoryCredentialStore(secrets: [
            ProviderCredentialResolver.keychainAccount(for: profile.id): "sk-test",
        ]))
        let provider = try LLMProviderFactory.make(profile: profile, credentialResolver: resolver)
        #expect(provider is OpenAICompatibleProvider)
    }
}

@Suite("ProviderNetworking")
struct ProviderNetworkingTests {
    /// 回归：三个 provider 的默认 session 曾用 URLSession.shared（resource
    /// timeout 7 天），SSE 服务端挂起时流式请求永久卡住。
    @Test func defaultSessionHasBoundedTimeouts() {
        let configuration = URLSession.newPiDefault.configuration
        #expect(configuration.timeoutIntervalForRequest <= 60)
        #expect(configuration.timeoutIntervalForResource <= 600)
        #expect(configuration.timeoutIntervalForResource > 0)
    }

    @Test func providersDefaultToBoundedSession() {
        let anthropic = AnthropicProvider(apiKeyProvider: { "k" })
        #expect(anthropic.session.configuration.timeoutIntervalForResource <= 600)

        let profile = ProviderProfile(
            name: "t", preset: .openaiCompatible, modelID: "m"
        )
        let openai = OpenAICompatibleProvider(profile: profile, apiKeyProvider: { "k" })
        #expect(openai.session.configuration.timeoutIntervalForResource <= 600)

        let responses = ResponsesAPIProvider(profile: profile, apiKeyProvider: { "k" })
        #expect(responses.session.configuration.timeoutIntervalForResource <= 600)
    }
}
