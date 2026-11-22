import Foundation

/// Canned providers/settings and fake sushi/oMLX APIs. Fixture mode runs the
/// exact same engine and settings writer against a separate directory, so the
/// real `~/.claude` and `~/.model-switch.json` are never touched.
public enum Fixtures {
    public static let sushiModelID = "beamster/DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw"
    public static let sushiSecondModelID = "beamster/GLM-5.3-Flash-Sushi-2.4bpw"
    public static let omlxModelIDs = [
        "Qwen3.8-27B-DFlash2",
        "Qwen3.8-27B-UD-Q4_K_M",
        "Qwen3.8-Flash-Next-Uncensored-oQ5e-mtp",
        "Qwen3.8-Flash-Next-oQ4e-mtp",
        "gemma-4-26B-A4B-it-oQ4e-mtp",
    ]

    public static func prepare() throws -> AppPaths {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ModelSwitch/fixture", isDirectory: true)
        let paths = AppPaths(
            claudeDir: support.appendingPathComponent(".claude", isDirectory: true),
            appConfigURL: support.appendingPathComponent("model-switch.json", isDirectory: false)
        )
        try paths.ensureClaudeLayout()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: paths.appConfigURL.path) {
            try makeConfig().save(to: paths.appConfigURL)
        }

        if !FileManager.default.fileExists(atPath: paths.settingsURL.path) {
            let settings = makeSettings()
            var data = try settings.serializedData(pretty: true)
            data.append(0x0A)
            try AtomicFile.write(data, to: paths.settingsURL, mode: 0o644)
        }

        return paths
    }

    public static func makeConfig() -> ModelSwitchConfig {
        return ModelSwitchConfig(
            version: 1,
            providers: [
                ProviderConfiguration(
                    id: "fixture-sushi",
                    name: "sushi",
                    baseURL: "http://fixture.local:12345",
                    apiKey: "fixture-sushi-key",
                    timeoutMs: "600000",
                    defaultContextTokens: "262144",
                    manualModels: [sushiModelID, sushiSecondModelID],
                    modelOverrides: [sushiModelID: "962000"]
                ),
                ProviderConfiguration(
                    id: "fixture-omlx",
                    name: "omlx",
                    baseURL: "http://fixture.local:4200",
                    apiKey: "fixture-omlx-key",
                    timeoutMs: "600000",
                    defaultContextTokens: "262144",
                    manualModels: omlxModelIDs
                ),
            ],
            path: AppPaths.defaultConfigURL()
        )
    }

    public static func makeSettings() -> JSONValue {
        let provider = makeConfig().provider(id: "fixture-sushi")!
        let env = SettingsMapping.environment(
            provider: provider,
            model: sushiModelID,
            contextTokens: "962000"
        )
        return .object([
            JSONPair(key: "autoCompactEnabled", value: .bool(true)),
            JSONPair(key: "editorMode", value: .string("normal")),
            JSONPair(key: "env", value: env),
            JSONPair(key: "modelSettings", value: .object([
                JSONPair(
                    key: sushiModelID.lowercased(),
                    value: .makeObject([("effortLevel", .string("xhigh"))])
                ),
            ])),
            JSONPair(key: "statusLine", value: .makeObject([
                ("type", .string("command")),
                ("command", .string("~/.claude/statusline.sh")),
            ])),
        ])
    }

    public static func makeServers(config: ModelSwitchConfig) -> [InferenceServer] {
        let apiByBase: [String: any ModelServerAPI] = [
            "http://fixture.local:12345": SushiFixtureAPI(),
            "http://fixture.local:4200": OMLXFixtureAPI(),
        ]
        return config.sortedProviders.map { provider in
            let kind: ServerKind
            switch provider.normalizedBaseURL {
            case "http://fixture.local:12345": kind = .sushi
            case "http://fixture.local:4200": kind = .omlx
            default: kind = .unknown
            }
            return InferenceServer(
                provider: provider,
                kind: kind,
                api: apiByBase[provider.normalizedBaseURL]
                    ?? UnreachableAPI(base: provider.normalizedBaseURL, reason: "fixture")
            )
        }
    }
}

// MARK: - Fake servers

final class SushiFixtureAPI: ModelServerAPI, @unchecked Sendable {
    let base = "http://fixture.local:12345"
    private let lock = NSLock()
    private var loaded: Set<String> = [Fixtures.sushiModelID]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fetchModels() async throws -> [ServerModel] {
        let current = locked { loaded }
        return [
            ServerModel(
                id: Fixtures.sushiModelID,
                loaded: current.contains(Fixtures.sushiModelID),
                state: current.contains(Fixtures.sushiModelID) ? .ready : .unloaded,
                sizeBytes: 332_300_000_000,
                contextLength: 962_000
            ),
            ServerModel(
                id: Fixtures.sushiSecondModelID,
                loaded: current.contains(Fixtures.sushiSecondModelID),
                state: current.contains(Fixtures.sushiSecondModelID) ? .ready : .unloaded,
                sizeBytes: 97_800_000_000,
                contextLength: 262_144
            ),
        ]
    }

    func load(_ id: String) async throws {
        try await Task.sleep(for: .seconds(2))
        _ = locked { loaded.insert(id) }
    }

    func unload(_ id: String) async throws {
        _ = locked { loaded.remove(id) }
    }

    func health() async throws -> ServerHealth {
        ServerHealth(up: true)
    }
}

final class OMLXFixtureAPI: ModelServerAPI, @unchecked Sendable {
    let base = "http://fixture.local:4200"
    private let lock = NSLock()
    private let ids = Fixtures.omlxModelIDs
    private var loaded: Set<String> = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fetchModels() async throws -> [ServerModel] {
        let current = locked { loaded }
        return ids.map { id in
            ServerModel(
                id: id,
                loaded: current.contains(id),
                state: current.contains(id) ? .ready : .unloaded,
                sizeBytes: id.hasPrefix("Qwen3.8-Flash-Next-Uncensored") ? 135_000_000_000 : 16_000_000_000
            )
        }
    }

    func load(_ id: String) async throws {
        try await Task.sleep(for: .seconds(2))
        _ = locked { loaded.insert(id) }
    }

    func unload(_ id: String) async throws {
        _ = locked { loaded.remove(id) }
    }

    func health() async throws -> ServerHealth {
        ServerHealth(up: true)
    }
}
