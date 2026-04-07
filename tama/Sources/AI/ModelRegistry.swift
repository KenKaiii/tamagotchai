import Foundation

/// Supported AI providers.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openai
    case moonshot
    case xiaomi
    case minimax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moonshot: "Moonshot"
        case .xiaomi: "Xiaomi"
        case .openai: "OpenAI"
        case .minimax: "MiniMax"
        }
    }

    var description: String {
        switch self {
        case .moonshot: "Kimi K2.5"
        case .xiaomi: "MiMo-V2-Pro (Token Plan)"
        case .openai: "GPT-5.4, Codex"
        case .minimax: "MiniMax M2.7"
        }
    }

    /// Base URL for the provider's API.
    var baseURL: String {
        switch self {
        case .moonshot: "https://api.moonshot.ai/v1/chat/completions"
        case .xiaomi: "https://token-plan-sgp.xiaomimimo.com/v1"
        case .openai: "https://chatgpt.com/backend-api/codex/responses"
        case .minimax: "https://api.minimax.io/anthropic/v1/messages"
        }
    }

    /// URL for the models list endpoint, used for API key validation.
    /// Not used for OAuth providers.
    var modelsURL: String {
        switch self {
        case .moonshot: "https://api.moonshot.ai/v1/models"
        case .xiaomi: "https://token-plan-sgp.xiaomimimo.com/v1/models"
        case .openai: ""
        case .minimax: "https://api.minimax.io/anthropic/v1/models"
        }
    }

    /// Whether this provider uses OpenAI-compatible chat completions API format.
    var isOpenAICompatible: Bool {
        switch self {
        case .moonshot: true
        case .xiaomi: true
        case .openai: false
        case .minimax: false
        }
    }

    /// Whether this provider uses Anthropic-compatible API format.
    var usesAnthropicAPI: Bool {
        switch self {
        case .minimax: true
        case .moonshot, .xiaomi, .openai: false
        }
    }

    /// Whether this provider requires OAuth login instead of API key.
    var usesOAuth: Bool {
        switch self {
        case .moonshot: false
        case .xiaomi: false
        case .openai: true
        case .minimax: false
        }
    }

    /// Whether this provider uses the Codex /responses API format.
    var usesCodexAPI: Bool {
        switch self {
        case .moonshot: false
        case .xiaomi: false
        case .openai: true
        case .minimax: false
        }
    }

    /// Whether this provider uses the custom `thinking` parameter.
    /// All providers should return true here — thinking is disabled by default
    /// to avoid latency. Only change if the user explicitly opts in.
    var usesCustomThinkingParam: Bool {
        switch self {
        case .moonshot: true
        case .xiaomi: false // Xiaomi Token Plan doesn't support this param
        case .openai: false
        case .minimax: true
        }
    }
}

/// Information about an available model.
struct ModelInfo: Identifiable {
    let id: String
    let name: String
    let provider: AIProvider
    let contextWindow: Int
    let maxOutputTokens: Int
    let supportsTools: Bool
    let supportsThinking: Bool
}

/// Central registry of available models.
enum ModelRegistry {
    static let models: [ModelInfo] = [
        ModelInfo(
            id: "kimi-k2.5",
            name: "Kimi K2.5",
            provider: .moonshot,
            contextWindow: 200_000,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "xiaomi-token-plan-sgp/mimo-v2-pro",
            name: "MiMo-V2-Pro",
            provider: .xiaomi,
            contextWindow: 1_048_576,
            maxOutputTokens: 32000,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "gpt-5.4",
            name: "GPT-5.4",
            provider: .openai,
            contextWindow: 1_050_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "gpt-5.4-mini",
            name: "GPT-5.4 Mini",
            provider: .openai,
            contextWindow: 400_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "gpt-5.3-codex",
            name: "GPT-5.3 Codex",
            provider: .openai,
            contextWindow: 400_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "codex-mini-latest",
            name: "Codex Mini",
            provider: .openai,
            contextWindow: 200_000,
            maxOutputTokens: 100_000,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "MiniMax-M2.7",
            name: "MiniMax M2.7",
            provider: .minimax,
            contextWindow: 204_800,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true
        ),
        ModelInfo(
            id: "MiniMax-M2.7-highspeed",
            name: "MiniMax M2.7 Highspeed",
            provider: .minimax,
            contextWindow: 204_800,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true
        ),
    ]

    /// Returns models for a specific provider.
    static func models(for provider: AIProvider) -> [ModelInfo] {
        models.filter { $0.provider == provider }
    }

    /// Returns the default model for a provider.
    static func defaultModel(for provider: AIProvider) -> ModelInfo {
        switch provider {
        case .moonshot:
            models.first { $0.id == "kimi-k2.5" }!
        case .xiaomi:
            models.first { $0.id == "xiaomi-token-plan-sgp/mimo-v2-pro" }!
        case .openai:
            models.first { $0.id == "gpt-5.4-mini" }!
        case .minimax:
            models.first { $0.id == "MiniMax-M2.7-highspeed" }!
        }
    }

    /// Finds a model by ID.
    static func model(withId id: String) -> ModelInfo? {
        models.first { $0.id == id }
    }

    /// Returns models only for providers that have credentials configured.
    @MainActor
    static func availableModels() -> [ModelInfo] {
        models.filter { ProviderStore.shared.hasCredentials(for: $0.provider) }
    }
}
