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

        let parser = OpenAIStreamParser()
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
