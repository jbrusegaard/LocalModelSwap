import Foundation

/// Faithful port of cps's `apply_provider` env rewrite.
public enum ProviderApplier {
    public static let knownEnvKeys = ClaudeEnv.knownKeys
    private static let knownSet = Set(knownEnvKeys)

    /// Deletes managed keys missing from the provider, merges the provider in,
    /// puts the six known keys first, then carries `modelSettings` to the new
    /// lowercase model id when no entry exists for it yet.
    public static func apply(settings: JSONValue, providerEnv: JSONValue) throws -> JSONValue {
        guard var rootPairs = settings.objectPairs else {
            throw APIError.decoding("settings.json must contain a JSON object")
        }
        guard let providerPairs = providerEnv.objectPairs else {
            throw APIError.decoding("provider env must be a JSON object")
        }

        var envPairs: [JSONPair]
        if let existing = settings["env"] {
            guard let pairs = existing.objectPairs else {
                throw APIError.decoding("settings.json 'env' must be a JSON object")
            }
            envPairs = pairs
        } else {
            envPairs = []
        }

        let oldModel = (settings["env"]?["ANTHROPIC_MODEL"]?.stringValue ?? "").lowercased()
        let newModel = (providerEnv["ANTHROPIC_MODEL"]?.stringValue ?? "").lowercased()

        var modelSettingsPairs: [JSONPair]
        if let existing = settings["modelSettings"] {
            guard let pairs = existing.objectPairs else {
                throw APIError.decoding("settings.json 'modelSettings' must be a JSON object")
            }
            modelSettingsPairs = pairs
        } else {
            modelSettingsPairs = []
        }

        let providerKeys = Set(providerPairs.map(\.key))
        let managed = knownSet

        // Drop stale managed keys the new provider does not define.
        envPairs = envPairs.filter { pair in
            !(managed.contains(pair.key) && !providerKeys.contains(pair.key))
        }

        // env.update(provider): replacement keeps the old position, new keys append.
        for pair in providerPairs {
            if let index = envPairs.firstIndex(where: { $0.key == pair.key }) {
                envPairs[index] = pair
            } else {
                envPairs.append(pair)
            }
        }

        // Canonical order: the six known keys (present ones), then the rest in
        // the order they already had.
        let knownInOrder = knownEnvKeys.compactMap { key in
            envPairs.first(where: { $0.key == key })
        }
        let rest = envPairs.filter { !knownSet.contains($0.key) }
        envPairs = knownInOrder + rest

        // Carry the old model's per-model settings to the new model, if the
        // new model has none of its own.
        if !newModel.isEmpty,
           modelSettingsPairs.contains(where: { $0.key == newModel }) == false,
           let previous = modelSettingsPairs.first(where: { $0.key == oldModel })?.value {
            modelSettingsPairs.append(JSONPair(key: newModel, value: previous))
        }

        let newEnv = JSONValue.object(envPairs)
        let newModelSettings = JSONValue.object(modelSettingsPairs)

        if let index = rootPairs.firstIndex(where: { $0.key == "env" }) {
            rootPairs[index] = JSONPair(key: "env", value: newEnv)
        } else {
            rootPairs.append(JSONPair(key: "env", value: newEnv))
        }

        if let index = rootPairs.firstIndex(where: { $0.key == "modelSettings" }) {
            rootPairs[index] = JSONPair(key: "modelSettings", value: newModelSettings)
        } else {
            rootPairs.append(JSONPair(key: "modelSettings", value: newModelSettings))
        }

        return .object(rootPairs)
    }
}
