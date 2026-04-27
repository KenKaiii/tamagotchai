import Foundation

/// Supported AI providers.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openai
    case anthropic
    case gemini
    case moonshot
    case xiaomi
    case minimax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .moonshot: "Moonshot"
        case .xiaomi: "Xiaomi"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .minimax: "MiniMax"
        }
    }

    var description: String {
        switch self {
        case .moonshot: "Kimi K2.6"
        case .xiaomi: "MiMo-V2-Pro (Token Plan)"
        case .openai: "GPT-5.5, Codex"
        case .anthropic: "Claude Sonnet 4.6 / Haiku 4.5 (via Claude account)"
        case .gemini: "Gemini 2.5 Pro / Flash (via Google account)"
        case .minimax: "MiniMax M2.7"
        }
    }

    /// Base URL for the provider's API.
    var baseURL: String {
        switch self {
        case .moonshot: "https://api.moonshot.ai/v1/chat/completions"
        case .xiaomi: "https://token-plan-sgp.xiaomimimo.com/v1"
        case .openai: "https://chatgpt.com/backend-api/codex/responses"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .gemini: "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse"
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
        case .anthropic: ""
        case .gemini: ""
        case .minimax: "https://api.minimax.io/anthropic/v1/models"
        }
    }

    /// Whether this provider uses OpenAI-compatible chat completions API format.
    var isOpenAICompatible: Bool {
        switch self {
        case .moonshot: true
        case .xiaomi: true
        case .openai: false
        case .anthropic: false
        case .gemini: false
        case .minimax: false
        }
    }

    /// Whether this provider uses Anthropic-compatible API format.
    var usesAnthropicAPI: Bool {
        switch self {
        case .anthropic: true
        case .minimax: true
        case .moonshot, .xiaomi, .openai, .gemini: false
        }
    }

    /// Whether this provider requires OAuth login instead of API key.
    var usesOAuth: Bool {
        switch self {
        case .moonshot: false
        case .xiaomi: false
        case .openai: true
        case .anthropic: true
        case .gemini: true
        case .minimax: false
        }
    }

    /// Whether this provider uses the Codex /responses API format.
    var usesCodexAPI: Bool {
        switch self {
        case .moonshot: false
        case .xiaomi: false
        case .openai: true
        case .anthropic: false
        case .gemini: false
        case .minimax: false
        }
    }

    /// Whether this provider uses the Google Cloud Code Assist (Gemini) API format.
    var usesGeminiAPI: Bool {
        switch self {
        case .gemini: true
        case .moonshot, .xiaomi, .openai, .anthropic, .minimax: false
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
        case .anthropic: false
        case .gemini: false
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
    /// Whether the model accepts image inputs (vision). Defaults to false.
    let supportsVision: Bool

    init(
        id: String,
        name: String,
        provider: AIProvider,
        contextWindow: Int,
        maxOutputTokens: Int,
        supportsTools: Bool,
        supportsThinking: Bool,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsThinking = supportsThinking
        self.supportsVision = supportsVision
    }
}

/// Central registry of available models.
enum ModelRegistry {
    static let models: [ModelInfo] = [
        ModelInfo(
            id: "kimi-k2.6",
            name: "Kimi K2.6",
            provider: .moonshot,
            contextWindow: 262_144,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "xiaomi-token-plan-sgp/mimo-v2-pro",
            name: "MiMo-V2-Pro",
            provider: .xiaomi,
            contextWindow: 1_048_576,
            maxOutputTokens: 32000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: false
        ),
        ModelInfo(
            id: "gpt-5.5",
            name: "GPT-5.5",
            provider: .openai,
            contextWindow: 1_000_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gpt-5.5-pro",
            name: "GPT-5.5 Pro",
            provider: .openai,
            contextWindow: 1_000_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gpt-5.4",
            name: "GPT-5.4",
            provider: .openai,
            contextWindow: 1_050_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gpt-5.4-mini",
            name: "GPT-5.4 Mini",
            provider: .openai,
            contextWindow: 400_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gpt-5.4-nano",
            name: "GPT-5.4 Nano",
            provider: .openai,
            contextWindow: 400_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gpt-5.3-codex",
            name: "GPT-5.3 Codex",
            provider: .openai,
            contextWindow: 400_000,
            maxOutputTokens: 128_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "codex-mini-latest",
            name: "Codex Mini",
            provider: .openai,
            contextWindow: 200_000,
            maxOutputTokens: 100_000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: false
        ),
        ModelInfo(
            id: "claude-sonnet-4-6",
            name: "Claude Sonnet 4.6",
            provider: .anthropic,
            contextWindow: 1_000_000,
            maxOutputTokens: 64000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "claude-haiku-4-5-20251001",
            name: "Claude Haiku 4.5",
            provider: .anthropic,
            contextWindow: 200_000,
            maxOutputTokens: 64000,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gemini-3-pro-preview",
            name: "Gemini 3 Pro (Preview)",
            provider: .gemini,
            contextWindow: 1_048_576,
            maxOutputTokens: 65535,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gemini-3-flash-preview",
            name: "Gemini 3 Flash (Preview)",
            provider: .gemini,
            contextWindow: 1_048_576,
            maxOutputTokens: 65535,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gemini-2.5-pro",
            name: "Gemini 2.5 Pro",
            provider: .gemini,
            contextWindow: 1_048_576,
            maxOutputTokens: 65535,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "gemini-2.5-flash",
            name: "Gemini 2.5 Flash",
            provider: .gemini,
            contextWindow: 1_048_576,
            maxOutputTokens: 65535,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: true
        ),
        ModelInfo(
            id: "MiniMax-M2.7",
            name: "MiniMax M2.7",
            provider: .minimax,
            contextWindow: 204_800,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: false
        ),
        ModelInfo(
            id: "MiniMax-M2.7-highspeed",
            name: "MiniMax M2.7 Highspeed",
            provider: .minimax,
            contextWindow: 204_800,
            maxOutputTokens: 16384,
            supportsTools: true,
            supportsThinking: true,
            supportsVision: false
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
            models.first { $0.id == "kimi-k2.6" }!
        case .xiaomi:
            models.first { $0.id == "xiaomi-token-plan-sgp/mimo-v2-pro" }!
        case .openai:
            models.first { $0.id == "gpt-5.5" }!
        case .anthropic:
            models.first { $0.id == "claude-sonnet-4-6" }!
        case .gemini:
            models.first { $0.id == "gemini-2.5-flash" }!
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
