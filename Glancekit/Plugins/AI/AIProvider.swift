import Foundation
import Observation

/// Which chat *wire format* the AI assistant speaks. Two shapes cover the whole
/// field: Anthropic's Messages API (Claude), and the OpenAI chat-completions
/// shape that OpenAI, Google, xAI, Groq, DeepSeek, Mistral, OpenRouter, and the
/// long tail of local/hosted servers (Ollama, LM Studio, …) all speak.
///
/// This is deliberately *not* the user-facing provider list — see `AIProvider`.
/// Several named providers map onto the same wire format; `AIClient` only cares
/// about the format, so keeping this a two-case enum keeps the client simple.
enum AIProviderKind: String, CaseIterable, Codable, Identifiable {
    case anthropic
    case openAICompatible

    var id: String { rawValue }
}

/// A named provider the user can pick in Settings.
///
/// Each preset carries the wire format, a default endpoint, and a handful of
/// suggested model ids so the user isn't left guessing. Providers that speak the
/// OpenAI shape but at a fixed URL (OpenAI, Google, Groq, …) hide the base-URL
/// field entirely; only "Custom" and "Ollama" expose it (`requiresBaseURL`).
struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    /// The wire format `AIClient` encodes for.
    let kind: AIProviderKind
    /// The endpoint root. For a fixed provider this is used as-is; for a
    /// `requiresBaseURL` provider it's only a seed for the editable field.
    let defaultBaseURL: String
    /// Suggested model ids, most capable first. The user may still type their own.
    let models: [String]
    /// Whether the user must supply the base URL (custom / local servers).
    let requiresBaseURL: Bool
    /// Whether an API key is needed (false for a local Ollama server).
    let requiresAPIKey: Bool
    /// Where to obtain an API key, shown as a link in Settings.
    let apiKeysURL: String?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AIProvider, rhs: AIProvider) -> Bool { lhs.id == rhs.id }

    // MARK: - Catalog

    /// The provider picker's contents, in display order.
    static let catalog: [AIProvider] = [
        AIProvider(id: "anthropic", name: "Anthropic (Claude)", kind: .anthropic,
                   defaultBaseURL: "", models: ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://console.anthropic.com/settings/keys"),
        AIProvider(id: "openai", name: "OpenAI", kind: .openAICompatible,
                   defaultBaseURL: "https://api.openai.com/v1", models: ["gpt-4o", "gpt-4o-mini", "o3", "o4-mini"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://platform.openai.com/api-keys"),
        AIProvider(id: "google", name: "Google Gemini", kind: .openAICompatible,
                   defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                   models: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://aistudio.google.com/apikey"),
        AIProvider(id: "xai", name: "xAI (Grok)", kind: .openAICompatible,
                   defaultBaseURL: "https://api.x.ai/v1", models: ["grok-2-latest", "grok-2-mini"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://console.x.ai"),
        AIProvider(id: "groq", name: "Groq", kind: .openAICompatible,
                   defaultBaseURL: "https://api.groq.com/openai/v1",
                   models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://console.groq.com/keys"),
        AIProvider(id: "deepseek", name: "DeepSeek", kind: .openAICompatible,
                   defaultBaseURL: "https://api.deepseek.com/v1", models: ["deepseek-chat", "deepseek-reasoner"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://platform.deepseek.com/api_keys"),
        AIProvider(id: "mistral", name: "Mistral", kind: .openAICompatible,
                   defaultBaseURL: "https://api.mistral.ai/v1", models: ["mistral-large-latest", "mistral-small-latest"],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://console.mistral.ai/api-keys"),
        AIProvider(id: "openrouter", name: "OpenRouter", kind: .openAICompatible,
                   defaultBaseURL: "https://openrouter.ai/api/v1",
                   models: [
                       // Paid flagships.
                       "anthropic/claude-sonnet-5",
                       "openai/gpt-4o",
                       "google/gemini-2.5-pro",
                       // Free tier (":free"; openrouter/free rotates across them).
                       // See https://openrouter.ai/openrouter/free
                       "openrouter/free",
                       "meta-llama/llama-3.3-70b-instruct:free",
                       "qwen/qwen3-coder:free",
                       "qwen/qwen3-next-80b-a3b-instruct:free",
                       "openai/gpt-oss-20b:free",
                       "nvidia/nemotron-3-super-120b-a12b:free",
                       "nousresearch/hermes-3-llama-3.1-405b:free",
                       "google/gemma-4-31b-it:free",
                       "meta-llama/llama-3.2-3b-instruct:free",
                   ],
                   requiresBaseURL: false, requiresAPIKey: true,
                   apiKeysURL: "https://openrouter.ai/keys"),
        AIProvider(id: "ollama", name: "Ollama (local)", kind: .openAICompatible,
                   defaultBaseURL: "http://localhost:11434/v1", models: ["llama3.2", "qwen2.5", "mistral"],
                   requiresBaseURL: true, requiresAPIKey: false, apiKeysURL: nil),
        AIProvider(id: "custom", name: "Custom (OpenAI-compatible)", kind: .openAICompatible,
                   defaultBaseURL: "", models: [], requiresBaseURL: true, requiresAPIKey: true, apiKeysURL: nil),
    ]

    static let `default` = catalog[0]

    /// Look a provider up by id, falling back to the default for an unknown id.
    static func provider(id: String) -> AIProvider {
        catalog.first { $0.id == id } ?? `default`
    }
}

/// Non-secret configuration for the AI assistant glance.
///
/// The selected provider, base URL, model, and system prompt are plain
/// preferences and persist in `UserDefaults` under `glancekit.ai.*`. The API key
/// is *not* a preference — it lives in `CredentialStore`, keyed *per provider*
/// (`ai.apiKey.<providerID>`), so switching providers keeps each company's key
/// and the secret never lands in preferences or their backups.
///
/// A singleton, like `ColorPaletteStore.shared`: the settings UI and the running
/// conversation read the same live config, and `@Observable` re-renders the UI
/// when any field changes.
@MainActor
@Observable
final class AIConfigStore {
    static let shared = AIConfigStore()

    /// The canonical Anthropic Messages endpoint. Anthropic ignores the
    /// user-facing base URL and always posts here.
    static let anthropicEndpoint = "https://api.anthropic.com/v1/messages"

    /// A sensible default system prompt. Steers the model toward *doing* things
    /// with the tools rather than narrating steps back to the user.
    static let defaultSystemPrompt = """
    You are the assistant inside Glancekit, a macOS menu-bar app. You help the \
    user manage color palettes, notes, and which tools/glances are enabled, \
    using the provided tools. Prefer taking action with tools over describing \
    steps. Confirm concisely what you did. Colors are #RRGGBB hex.
    """

    /// The selected provider's id (see `AIProvider.catalog`).
    var providerID: String {
        didSet { persist() }
    }

    /// User-supplied base URL, only meaningful for a `requiresBaseURL` provider
    /// (Custom / Ollama). Ignored for fixed providers.
    var baseURL: String {
        didSet { persist() }
    }

    var model: String {
        didSet { persist() }
    }

    var systemPrompt: String {
        didSet { persist() }
    }

    /// The API key for the *current* provider. Stored (so the UI binds to it and
    /// `isConfigured` reacts live), and mirrored into `CredentialStore` on every
    /// change under the current provider's key. Reloaded when the provider
    /// changes (see `selectProvider(id:)`).
    var apiKey: String {
        didSet { CredentialStore.set(apiKey.isEmpty ? nil : apiKey, for: Self.keychainKey(for: providerID)) }
    }

    // MARK: - Persistence keys

    private let providerIDKey = "glancekit.ai.providerID"
    private let legacyProviderKindKey = "glancekit.ai.providerKind"
    private let baseURLKey = "glancekit.ai.baseURL"
    private let modelKey = "glancekit.ai.model"
    private let systemPromptKey = "glancekit.ai.systemPrompt"

    static func keychainKey(for providerID: String) -> String { "ai.apiKey.\(providerID)" }
    private static let legacyKeychainKey = "ai.apiKey"

    private init() {
        let defaults = UserDefaults.standard

        // Resolve the provider id, migrating an old two-case `providerKind`
        // preference: openAICompatible → "custom", anything else → "anthropic".
        let resolvedID: String
        if let stored = defaults.string(forKey: providerIDKey) {
            resolvedID = stored
        } else if let legacy = defaults.string(forKey: legacyProviderKindKey) {
            resolvedID = legacy == AIProviderKind.openAICompatible.rawValue ? "custom" : "anthropic"
        } else {
            resolvedID = AIProvider.default.id
        }
        let provider = AIProvider.provider(id: resolvedID)
        providerID = provider.id

        baseURL = defaults.string(forKey: baseURLKey) ?? (provider.requiresBaseURL ? provider.defaultBaseURL : "")
        model = defaults.string(forKey: modelKey) ?? provider.models.first ?? ""
        systemPrompt = defaults.string(forKey: systemPromptKey) ?? Self.defaultSystemPrompt

        // Property observers don't fire inside init, so seed `apiKey` directly:
        // migrate any single legacy key onto the resolved provider, then load.
        let key = Self.keychainKey(for: provider.id)
        if CredentialStore.get(key) == nil, let legacyKey = CredentialStore.get(Self.legacyKeychainKey) {
            CredentialStore.set(legacyKey, for: key)
            CredentialStore.set(nil, for: Self.legacyKeychainKey)
        }
        apiKey = CredentialStore.get(key) ?? ""
    }

    /// The selected provider.
    var provider: AIProvider { AIProvider.provider(id: providerID) }

    /// The wire format the client should encode for.
    var providerKind: AIProviderKind { provider.kind }

    /// Switch providers: persist the choice, reset the model to that provider's
    /// default when the current one doesn't belong to it, seed an editable base
    /// URL if needed, and load that provider's stored key.
    func selectProvider(id: String) {
        guard id != providerID else { return }
        providerID = id
        let provider = AIProvider.provider(id: id)
        if !provider.models.contains(model) {
            model = provider.models.first ?? (provider.requiresBaseURL ? model : "")
        }
        if provider.requiresBaseURL, baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            baseURL = provider.defaultBaseURL
        }
        apiKey = CredentialStore.get(Self.keychainKey(for: id)) ?? ""
    }

    /// The effective base URL for the current provider: the user's field for a
    /// `requiresBaseURL` provider, otherwise the preset's fixed URL.
    private var effectiveBaseURL: String {
        provider.requiresBaseURL ? baseURL : provider.defaultBaseURL
    }

    /// Whether the assistant has everything it needs to make a request.
    var isConfigured: Bool {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let provider = provider
        if provider.requiresAPIKey, apiKey.isEmpty { return false }
        if provider.requiresBaseURL,
           effectiveBaseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    /// The URL a request should POST to for the current provider.
    ///
    /// - Anthropic: always the canonical Messages endpoint.
    /// - OpenAI-compatible: the effective base URL, with `/chat/completions`
    ///   appended unless already present (defensive against both ".../v1" and
    ///   ".../v1/chat/completions").
    var effectiveEndpoint: String {
        switch providerKind {
        case .anthropic:
            return Self.anthropicEndpoint
        case .openAICompatible:
            var base = effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/chat/completions") { return base }
            return base + "/chat/completions"
        }
    }

    /// Explicit save, for a UI that batches edits. Field `didSet`s already
    /// persist on every change, so calling this is belt-and-suspenders.
    func save() {
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(providerID, forKey: providerIDKey)
        defaults.set(baseURL, forKey: baseURLKey)
        defaults.set(model, forKey: modelKey)
        defaults.set(systemPrompt, forKey: systemPromptKey)
    }
}
