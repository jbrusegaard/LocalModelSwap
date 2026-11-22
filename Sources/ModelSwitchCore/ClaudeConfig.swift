import Foundation

public enum ClaudeEnv {
    public static let knownKeys: [String] = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "API_TIMEOUT_MS",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
    ]
}

/// The provider values Claude Code is currently using. Derived from
/// `settings.json`'s env block, which remains the source of truth.
public struct ClaudeSettingsSnapshot: Equatable, Sendable {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let smallModel: String
    public let contextTokens: String

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        smallModel: String,
        contextTokens: String
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.smallModel = smallModel
        self.contextTokens = contextTokens
    }

    public var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public static func from(settings: JSONValue) -> ClaudeSettingsSnapshot? {
        guard let env = settings["env"], env.objectPairs != nil else { return nil }
        let base = env["ANTHROPIC_BASE_URL"]?.stringValue ?? ""
        let model = env["ANTHROPIC_MODEL"]?.stringValue ?? ""
        guard !base.isEmpty || !model.isEmpty else { return nil }
        return ClaudeSettingsSnapshot(
            baseURL: base,
            apiKey: env["ANTHROPIC_AUTH_TOKEN"]?.stringValue ?? "",
            model: model,
            smallModel: env["ANTHROPIC_SMALL_FAST_MODEL"]?.stringValue ?? model,
            contextTokens: env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.scalarString ?? ""
        )
    }
}

public struct SettingsApplyResult: Sendable, Equatable {
    public let backupURL: URL
    public let newModelID: String?
}

/// Rewrites the provider env block of `~/.claude/settings.json`, backups and
/// atomic write included. It never touches providers.json.
public struct SettingsStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func load() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else {
            return .object([])
        }
        return try JSONValue.parse(try AtomicFile.read(paths.settingsURL))
    }

    public func snapshot() -> ClaudeSettingsSnapshot? {
        guard let settings = try? load() else { return nil }
        return ClaudeSettingsSnapshot.from(settings: settings)
    }

    /// Env keys separately defined in `settings.local.json` override
    /// `settings.json`, so they are shown as a warning, never written.
    public func localEnvKeys() -> [String] {
        guard let data = try? Data(contentsOf: paths.settingsLocalURL),
              let root = try? JSONValue.parse(data),
              let env = root["env"]?.objectPairs else { return [] }
        return env.map(\.key).sorted()
    }

    public func apply(providerEnv: JSONValue, now: Date = Date()) throws -> SettingsApplyResult {
        let originalData: Data
        let settingsMode: Int
        if FileManager.default.fileExists(atPath: paths.settingsURL.path) {
            originalData = try AtomicFile.read(paths.settingsURL)
            settingsMode = AtomicFile.mode(of: paths.settingsURL) ?? 0o644
        } else {
            originalData = Data("{}".utf8)
            settingsMode = 0o644
        }

        let original = try JSONValue.parse(originalData)
        let rewritten = try ProviderApplier.apply(settings: original, providerEnv: providerEnv)

        try paths.ensureClaudeLayout()

        let stamp = Self.timestampFormatter.string(from: now)
        let backup = paths.backupsDir.appendingPathComponent("settings.json.\(stamp).bak")
        try AtomicFile.write(originalData, to: backup, mode: settingsMode)

        var output = try rewritten.serializedData(pretty: true, sortedKeys: false)
        output.append(0x0A)
        try AtomicFile.write(output, to: paths.settingsURL, mode: settingsMode)

        Self.pruneBackups(in: paths.backupsDir, keep: 20)

        return SettingsApplyResult(
            backupURL: backup,
            newModelID: providerEnv["ANTHROPIC_MODEL"]?.stringValue
        )
    }

    public static func pruneBackups(in directory: URL, keep: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let backups = names
            .filter { $0.hasPrefix("settings.json.") && $0.hasSuffix(".bak") }
            .sorted()
        guard backups.count > keep else { return }
        for name in backups.prefix(backups.count - keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
