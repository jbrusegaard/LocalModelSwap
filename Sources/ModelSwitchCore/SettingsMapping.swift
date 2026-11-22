import Foundation

/// Builds the six env values Claude Code reads from one provider + model.
public enum SettingsMapping {
    public static func environment(
        provider: ProviderConfiguration,
        model: String,
        contextTokens: String? = nil,
        smallModel: String? = nil
    ) -> JSONValue {
        let context = contextTokens?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveContext = (context?.isEmpty == false ? context : nil)
            ?? provider.contextTokens(for: model)
        let small = smallModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .makeObject([
            ("ANTHROPIC_BASE_URL", .string(provider.normalizedBaseURL)),
            ("ANTHROPIC_AUTH_TOKEN", .string(provider.apiKey)),
            ("ANTHROPIC_MODEL", .string(model)),
            ("ANTHROPIC_SMALL_FAST_MODEL", .string(small?.isEmpty == false ? small! : model)),
            ("API_TIMEOUT_MS", .string(provider.normalizedTimeout)),
            ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", .string(effectiveContext)),
        ])
    }

    public static func provider(
        forBaseURL baseURL: String,
        in providers: [ProviderConfiguration]
    ) -> ProviderConfiguration? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return providers.first { $0.normalizedBaseURL == base }
    }
}
