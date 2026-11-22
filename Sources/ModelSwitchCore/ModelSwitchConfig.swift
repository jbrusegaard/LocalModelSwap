import Foundation

/// A provider is just a named URL and API key. Models are scanned from that
/// server or added manually; they never live inside the provider record.
public struct ProviderConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var timeoutMs: String
    public var defaultContextTokens: String
    public var manualModels: [String]
    public var modelOverrides: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        apiKey: String = "",
        timeoutMs: String = "600000",
        defaultContextTokens: String = "262144",
        manualModels: [String] = [],
        modelOverrides: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeoutMs = timeoutMs
        self.defaultContextTokens = defaultContextTokens
        self.manualModels = manualModels
        self.modelOverrides = modelOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, timeoutMs, defaultContextTokens, manualModels, modelOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Provider"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        timeoutMs = try container.decodeIfPresent(String.self, forKey: .timeoutMs) ?? "600000"
        defaultContextTokens = try container.decodeIfPresent(String.self, forKey: .defaultContextTokens) ?? "262144"
        manualModels = try container.decodeIfPresent([String].self, forKey: .manualModels) ?? []
        modelOverrides = try container.decodeIfPresent([String: String].self, forKey: .modelOverrides) ?? [:]
    }

    public var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public var hostLabel: String {
        guard let url = URL(string: normalizedBaseURL) else { return normalizedBaseURL }
        let host = url.host ?? normalizedBaseURL
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    public var maskedAPIKey: String {
        guard !apiKey.isEmpty else { return "no key" }
        if apiKey.count <= 10 { return String(apiKey.prefix(2)) + "…" }
        return String(apiKey.prefix(5)) + "…" + String(apiKey.suffix(3))
    }

    public var normalizedTimeout: String {
        let value = timeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "600000" : value
    }

    public var normalizedDefaultContext: String {
        let value = defaultContextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "262144" : value
    }

    /// Effective Claude context for this model: an explicit override, else the
    /// provider default. Always a digit string so it can go straight into env.
    public func contextTokens(for model: String) -> String {
        if let value = modelOverrides[model]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return normalizedDefaultContext
    }

    /// Manual model ids in order, then override-only ids that are not manual.
    public var knownModelIDs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in manualModels where !id.isEmpty && seen.insert(id).inserted {
            result.append(id)
        }
        for id in modelOverrides.keys.sorted() where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    public func validationProblem(
        existingProviders: [ProviderConfiguration]
    ) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Name is required" }
        if name.contains("/") { return "Name cannot contain /" }
        if existingProviders.contains(where: {
            $0.id != id && $0.name.lowercased() == name.lowercased()
        }) {
            return "Another provider already uses that name"
        }

        let base = normalizedBaseURL
        if !(base.hasPrefix("http://") || base.hasPrefix("https://")) {
            return "Base URL must start with http:// or https://"
        }
        if existingProviders.contains(where: {
            $0.id != id && $0.normalizedBaseURL == base
        }) {
            return "Another provider already uses that URL"
        }

        for (label, value) in [("Timeout", timeoutMs), ("Default context", defaultContextTokens)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.contains(where: { !$0.isNumber }) {
                return "\(label) must be a number"
            }
        }
        var seenModels = Set<String>()
        for value in manualModels {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Manual model ids cannot be empty" }
            if !seenModels.insert(trimmed).inserted {
                return "Duplicate manual model: \(trimmed)"
            }
        }
        for value in modelOverrides.values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.contains(where: { !$0.isNumber }) {
                return "Model context overrides must be numbers"
            }
        }
        return nil
    }
}

/// `~/.model-switch.json` — Model Switch's own registry, independent of cps's
/// providers.json (which is read once for import and never written).
public struct ModelSwitchConfig: Equatable, Sendable {
    public var version: Int
    public var providers: [ProviderConfiguration]
    public var path: URL

    public init(
        version: Int = 1,
        providers: [ProviderConfiguration] = [],
        path: URL = AppPaths.defaultConfigURL()
    ) {
        self.version = version
        self.providers = providers
        self.path = path
    }

    private struct StoredConfig: Codable {
        var version: Int
        var providers: [ProviderConfiguration]
    }

    public static func load(from url: URL) throws -> ModelSwitchConfig {
        let data = try AtomicFile.read(url)
        let stored = try JSONDecoder().decode(StoredConfig.self, from: data)
        return ModelSwitchConfig(version: stored.version, providers: stored.providers, path: url)
    }

    public func save(to url: URL? = nil, mode: Int = 0o600) throws {
        let target = url ?? path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(StoredConfig(version: version, providers: providers))
        data.append(0x0A)
        try AtomicFile.write(data, to: target, mode: mode)
    }

    public func provider(id: String) -> ProviderConfiguration? {
        providers.first { $0.id == id }
    }

    public func provider(normalizedBase: String) -> ProviderConfiguration? {
        providers.first { $0.normalizedBaseURL == normalizedBase }
    }

    public func provider(named name: String) -> ProviderConfiguration? {
        providers.first { $0.name.lowercased() == name.lowercased() }
    }

    public var sortedProviders: [ProviderConfiguration] {
        providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func uniqueName(_ desired: String) -> String {
        if provider(named: desired) == nil { return desired }
        var suffix = 2
        while provider(named: "\(desired)-\(suffix)") != nil { suffix += 1 }
        return "\(desired)-\(suffix)"
    }

    public mutating func upsert(_ provider: ProviderConfiguration) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    public mutating func remove(id: String) {
        providers.removeAll { $0.id == id }
    }
}

// MARK: - providers.json import (read-only)

public struct ImportedModel: Equatable, Sendable {
    public let id: String
    public let contextTokens: String?

    public init(id: String, contextTokens: String?) {
        self.id = id
        self.contextTokens = contextTokens
    }
}

public struct ImportedProvider: Equatable, Sendable {
    public let baseURL: String
    public let apiKey: String
    public let timeoutMs: String
    public let defaultContextTokens: String
    public let models: [ImportedModel]
    public let sourceNames: [String]

    public init(
        baseURL: String,
        apiKey: String,
        timeoutMs: String,
        defaultContextTokens: String,
        models: [ImportedModel],
        sourceNames: [String]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeoutMs = timeoutMs
        self.defaultContextTokens = defaultContextTokens
        self.models = models
        self.sourceNames = sourceNames
    }
}

/// Reads cps's `~/.claude/providers.json` to bootstrap this app's providers.
/// One base URL becomes one provider; per-entry models become manual models
/// plus context overrides. The file is never modified.
public enum ProvidersJSONImporter {
    private struct Record {
        let name: String
        let baseURL: String
        let apiKey: String
        let model: String
        let contextTokens: String?
        let timeoutMs: String?
    }

    public static func read(from url: URL) throws -> [ImportedProvider] {
        let data = try AtomicFile.read(url)
        let root = try JSONValue.parse(data)
        guard case .object = root else {
            throw APIError.decoding("providers.json must contain a JSON object")
        }
        guard let providerPairs = root["providers"]?.objectPairs else {
            return []
        }

        var recordsByBase: [String: [Record]] = [:]
        for pair in providerPairs {
            guard let env = pair.value.objectPairs else { continue }
            let base = normalize(env.first(where: { $0.key == "ANTHROPIC_BASE_URL" })?.value.stringValue ?? "")
            guard !base.isEmpty else { continue }
            func value(_ key: String) -> String? {
                env.first(where: { $0.key == key })?.value.scalarString
            }
            recordsByBase[base, default: []].append(Record(
                name: pair.key,
                baseURL: base,
                apiKey: value("ANTHROPIC_AUTH_TOKEN") ?? "",
                model: value("ANTHROPIC_MODEL") ?? "",
                contextTokens: emptyToNil(value("CLAUDE_CODE_MAX_CONTEXT_TOKENS")),
                timeoutMs: emptyToNil(value("API_TIMEOUT_MS"))
            ))
        }

        var providers: [ImportedProvider] = []
        for base in recordsByBase.keys.sorted() {
            let records = (recordsByBase[base] ?? []).sorted { $0.name < $1.name }
            let apiKey = records.first(where: { !$0.apiKey.isEmpty })?.apiKey ?? ""
            let timeout = records.first(where: { $0.timeoutMs != nil })?.timeoutMs ?? "600000"
            // Imported entries carry per-model context overrides; the provider
            // default stays at the Claude-safe 262144 for scanned models.
            let defaultContext = "262144"

            var models: [ImportedModel] = []
            var seen = Set<String>()
            for record in records where !record.model.isEmpty && seen.insert(record.model).inserted {
                models.append(ImportedModel(id: record.model, contextTokens: record.contextTokens))
            }

            providers.append(ImportedProvider(
                baseURL: base,
                apiKey: apiKey,
                timeoutMs: timeout,
                defaultContextTokens: defaultContext,
                models: models,
                sourceNames: records.map(\.name)
            ))
        }
        return providers
    }

    private static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
