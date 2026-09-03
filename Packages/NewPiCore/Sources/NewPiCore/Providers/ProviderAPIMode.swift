import Foundation

public enum ProviderAPIMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case chatCompletions
    case responses

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatCompletions:
            "Chat Completions"
        case .responses:
            "Responses API"
        }
    }
}

extension ProviderProfile {
    public var apiMode: ProviderAPIMode {
        guard let raw = option(.apiMode) else { return .chatCompletions }
        return ProviderAPIMode(rawValue: raw) ?? .chatCompletions
    }

    public mutating func setAPIMode(_ mode: ProviderAPIMode) {
        if mode == .chatCompletions {
            options.removeValue(forKey: ProviderOptionKey.apiMode.rawValue)
        } else {
            setOption(.apiMode, value: mode.rawValue)
        }
    }

    public var supportsAPIModeSelection: Bool {
        preset.supportsResponses
    }
}
