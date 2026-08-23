# Provider Configuration Design

**Date:** 2026-08-24  
**Status:** Approved scope (v1 = Option A)  
**Phase:** 3.5 (before JSONL SessionManager integration)

## Summary

Add a persistent **Provider Profile** system so users can configure BYOK (Bring Your Own Key) parameters and create profiles quickly from built-in vendor presets. Non-sensitive settings live in `~/.new-pi/agent/providers.json`; API keys stay in Keychain. The app and CLI resolve the active profile into an `LLMProvider` at session creation.

**v1 scope (Option A):**

- Anthropic (native)
- OpenAI-compatible (DeepSeek, Groq, Moonshot, self-hosted vLLM, etc.)
- Ollama (local, no key)
- OpenRouter (OpenAI-compatible routing layer)

Azure OpenAI and Google Gemini are out of v1; catalog entries may show as “coming soon”.

---

## Goals

1. Multiple named provider profiles with persistent config across app restarts.
2. BYOK: API key + preset-specific options (base URL, org, referer, etc.).
3. Quick setup from common vendor presets with sensible defaults.
4. Single default profile used by App/CLI unless overridden per session (later).
5. Migrate existing Keychain `anthropic-api-key` into a default profile on first run.

## Non-Goals (v1)

- Azure OpenAI, Google Gemini implementations.
- Per-message provider switching in chat (Phase 6 UI polish).
- OAuth / non-API-key auth flows.
- Model discovery APIs (static preset model lists only).
- Encrypted config file (keys never in JSON).

---

## Current State

| Component | Today |
|---|---|
| `AnthropicProvider` | Implemented; supports `baseURL` override |
| `CredentialProvider` | Enum: `anthropic`, `openai`; Keychain + env |
| `NewPiSettingsView` | Single Anthropic API key field |
| `NewPiViewModel` | Hardcoded `LLMProviderFactory.anthropic` + `claude-sonnet-4-20250514` |
| Config on disk | None for providers |

---

## Architecture

```
~/.new-pi/agent/providers.json          (non-sensitive profiles)
Keychain com.new-pi.credentials         (provider:<profile-id>:apiKey)
Env vars                                (override, highest priority)

ProviderConfigStore.load()
    → ProviderConfigFile
    → default ProviderProfile
    → CredentialResolver.apiKey(for: profile)
    → LLMProviderFactory.make(profile:resolver:)
    → AgentSessionFactory.codingSession(..., model: profile.modelConfig)
```

### New Types (NewPiCore)

```
Providers/
  ProviderPreset.swift           // enum + PresetDefinition catalog
  ProviderProfile.swift          // user instance + validation
  ProviderConfigStore.swift      // JSON read/write + migration
  ProviderCredentialResolver.swift  // profile-scoped key resolution
  LLMProviderFactory+Profile.swift
  OpenAICompatible/
    OpenAICompatibleProvider.swift   // openai, openaiCompatible, openRouter, ollama
```

---

## Data Model

### ProviderConfigFile

```json
{
  "version": 1,
  "defaultProfileID": "anthropic-default",
  "profiles": [ /* ProviderProfile[] */ ]
}
```

Path: `~/.new-pi/agent/providers.json`

### ProviderProfile

| Field | Type | Notes |
|---|---|---|
| `id` | String (UUID) | Stable reference; used in Keychain account |
| `name` | String | Display name, e.g. "DeepSeek Work" |
| `preset` | ProviderPreset | Built-in template id |
| `modelID` | String | Provider-specific model string |
| `thinkingLevel` | ThinkingLevel | Reuse existing enum; Anthropic only for now |
| `maxTokens` | Int | Default 8192 |
| `options` | `[String: String]` | Non-secret BYOK params (see preset table) |

`ProviderProfile.modelConfig` returns existing `ModelConfig(provider:preset.rawValue, ...)`.

### ProviderPreset (v1)

| Preset | Provider impl | Key required | Options |
|---|---|---|---|
| `anthropic` | `AnthropicProvider` | Yes | `baseURL?`, `apiVersion?` |
| `openai` | `OpenAICompatibleProvider` | Yes | `baseURL?` (default OpenAI), `organization?` |
| `openaiCompatible` | `OpenAICompatibleProvider` | Yes | `baseURL` (required), `organization?` |
| `openRouter` | `OpenAICompatibleProvider` | Yes | `baseURL` (default openrouter.ai), `httpReferer?`, `appTitle?` |
| `ollama` | `OpenAICompatibleProvider` | No | `baseURL?` (default `http://127.0.0.1:11434`) |

### Preset Catalog (built-in constants)

Each `ProviderPresetDefinition` includes:

- `displayName`, `systemImage` (SF Symbol name for App)
- `defaultBaseURL` (where applicable)
- `defaultModels: [String]` for picker
- `requiredOptions: [OptionField]` — drives dynamic Settings form
- `credentialRequired: Bool`
- `environmentVariable: String?` — env override key (e.g. `ANTHROPIC_API_KEY`)
- `quickSetupDefaults: [String: String]` — pre-fill for quick-add buttons

**Quick-add buttons (v1):**

| Button | Preset | Pre-filled |
|---|---|---|
| Anthropic | anthropic | Sonnet 4 default model list |
| OpenAI | openai | gpt-4o, gpt-4o-mini |
| DeepSeek | openaiCompatible | `https://api.deepseek.com/v1/chat/completions`, deepseek-chat |
| OpenRouter | openRouter | openrouter default URL, example model |
| Ollama | ollama | localhost URL, llama3 |
| Custom compatible | openaiCompatible | empty baseURL |

---

## Credential Resolution

Keychain account: `provider:<profile-id>:apiKey`

Resolution order per profile:

1. **Environment** — preset’s `environmentVariable`, if set and non-empty.
2. **Keychain** — `provider:<id>:apiKey`.
3. **Error** — `AgentError.llmFailed` with actionable message pointing to Settings.

For `ollama`, skip key resolution; empty Authorization header.

### Migration

On `ProviderConfigStore.load()` when file missing:

1. If Keychain has legacy account `anthropic-api-key`, copy to `provider:anthropic-default:apiKey`.
2. Write default `providers.json` with one profile:

```json
{
  "version": 1,
  "defaultProfileID": "anthropic-default",
  "profiles": [{
    "id": "anthropic-default",
    "name": "Anthropic",
    "preset": "anthropic",
    "modelID": "claude-sonnet-4-20250514",
    "thinkingLevel": "off",
    "maxTokens": 8192,
    "options": {}
  }]
}
```

Legacy `anthropic-api-key` may remain until user clears it (no delete in v1 migration).

---

## OpenAICompatibleProvider

Single implementation for OpenAI Chat Completions streaming API, parameterized by profile options.

**Endpoints:**

- OpenAI: `https://api.openai.com/v1/chat/completions`
- OpenRouter: `https://openrouter.ai/api/v1/chat/completions`
- Ollama: `{baseURL}/v1/chat/completions` (Ollama OpenAI-compatible path)
- Custom: user `baseURL` (must end with `/chat/completions` or we normalize)

**Headers:**

- `Authorization: Bearer <key>` when credential required
- OpenRouter: optional `HTTP-Referer`, `X-Title` from options
- OpenAI: optional `OpenAI-Organization`

**Streaming:** Parse SSE `data:` lines; map `delta.content` → `textDelta`; tool calls via `delta.tool_calls` (basic v1 support mirroring Anthropic event shape).

**Message encoding:** Reuse `LLMMessageConverter` flat format initially; structured tool history is a follow-up if needed.

---

## Validation Rules

| Rule | Error |
|---|---|
| Duplicate profile `id` | reject save |
| Unknown `preset` | reject decode |
| `openaiCompatible` without `baseURL` | reject save |
| `defaultProfileID` not in profiles | fall back to first profile |
| Empty `modelID` | reject save |
| Invalid URL in options | reject save |

---

## App UI (Settings)

Replace single Anthropic section with **Providers** tab:

1. **Default provider** — Picker bound to `defaultProfileID`.
2. **Profile list** — Name, preset badge, model, key status (configured / missing / not required).
3. **Actions** — Edit, Delete (confirm), Set as default.
4. **Add provider** — Sheet with quick-add grid + “Custom OpenAI-compatible”.
5. **Edit sheet** — Dynamic form from `PresetDefinition.requiredOptions` + SecureField for API key + model picker (preset list + custom text).

Remove direct `anthropicAPIKeyDraft` from ViewModel; delegate to profile editor.

**Session wiring:** `NewPiViewModel.resetSession()` loads config, picks default profile, calls `LLMProviderFactory.make(profile:resolver:)`.

---

## CLI

Update `new-pi` to print:

- Config path
- Default profile name + preset + model
- Key status for default profile

Future: `--provider <id>` flag (not v1).

---

## Session Persistence Hook (Phase 4)

When JSONL SessionManager lands, each session header records:

```json
{ "providerProfileID": "...", "modelID": "..." }
```

Resume uses stored profile ID; if missing, fall back to default. No Phase 4 work in this phase—only reserve fields in design.

---

## Testing

| Test file | Coverage |
|---|---|
| `ProviderConfigStoreTests` | Round-trip JSON, migration from legacy keychain mock, validation |
| `ProviderProfileTests` | Option validation per preset |
| `OpenAICompatibleProviderTests` | SSE parser, request builder headers (OpenRouter, Ollama) |
| `LLMProviderFactoryProfileTests` | Factory dispatches correct type per preset |

Use `InMemoryCredentialStore` and mock `URLSession` where needed.

---

## Security

- API keys only in Keychain or env; never log or persist in JSON.
- `# SECURITY-REVIEW` on credential resolution and HTTP provider code.
- User-supplied `baseURL` validated as `https` except `ollama` allowlist (`http://127.0.0.1`, `http://localhost`).
- Generic error messages to UI; details logged server-side only (future).

---

## File Changes (expected)

| File | Change |
|---|---|
| `Providers/*.swift` | New |
| `OpenAICompatible/OpenAICompatibleProvider.swift` | New |
| `Anthropic/AnthropicProvider.swift` | Minor: accept profile options |
| `Credentials/CredentialStore.swift` | Deprecate hardcoded accounts; keep for migration |
| `NewPiSettingsView.swift` | Providers UI |
| `NewPiViewModel.swift` | Load profile-based provider |
| `NewPiCLI/main.swift` | Print provider status |
| `docs/architecture.md` | Provider config section |
| `README.md` | Settings / BYOK docs |

---

## Implementation Phases

### 3.5a — Config + Anthropic path

- `ProviderPreset`, `ProviderProfile`, `ProviderConfigStore`, migration
- `ProviderCredentialResolver`
- `LLMProviderFactory.make(profile:)`
- Wire ViewModel + minimal Settings list (no OpenAI yet)

### 3.5b — OpenAI-compatible stack

- `OpenAICompatibleProvider` + tests
- Enable openai, openaiCompatible, openRouter, ollama presets
- Full Settings UI with quick-add

### 3.5c — Polish

- Connection test button (“Test provider”)
- CLI improvements
- Docs update

---

## Open Questions (resolved)

| Question | Decision |
|---|---|
| v1 vendor scope | **Option A** — Anthropic + OpenAI-compatible + OpenRouter + Ollama |
| Config storage | Single `providers.json` + Keychain |
| Azure / Gemini | Deferred post-v1 |
