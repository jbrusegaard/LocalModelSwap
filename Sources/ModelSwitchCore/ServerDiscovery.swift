import Foundation

public enum ServerDiscovery {
    /// Identifies sushi vs oMLX the way modelswitch's `DetectKind` does:
    /// health payload, then the status table, then owned_by, then port hints.
    public static func detectKind(
        base: String,
        token: String,
        timeout: TimeInterval = 4,
        session: URLSession? = nil
    ) async -> ServerKind {
        let client = HTTPClient(base: base, token: token, session: session)

        if let response = try? await client.get("/health", timeout: timeout),
           let root = response.object,
           root["engine_pool"] != nil || root["default_model"] != nil {
            return .omlx
        }

        if let response = try? await client.get("/v1/models/status", timeout: timeout),
           response.status == 200,
           response.object?["models"] != nil {
            return .omlx
        }

        if let response = try? await client.get("/v1/models", timeout: timeout),
           response.status == 200,
           let rows = response.object?["data"]?.arrayValues,
           rows.contains(where: { $0["owned_by"]?.stringValue == "sushi" }) {
            return .sushi
        }

        if let url = URL(string: base), let port = url.port {
            if port == 12345 { return .sushi }
            if port == 4200 { return .omlx }
        }

        return .unknown
    }

    public static func parseHealth(_ response: HTTPResponse) -> ServerHealth {
        var health = ServerHealth(up: response.status == 200 || response.status == 503)
        guard let root = response.object else { return health }
        health.up = health.up || root["status"] != nil
        return health
    }

    public static func makeAPI(base: String, token: String, kind: ServerKind) -> any ModelServerAPI {
        let client = HTTPClient(base: base, token: token)
        switch kind {
        case .sushi:
            return SushiAPI(client: client)
        case .omlx:
            return OMLXAPI(client: client)
        case .unknown:
            return UnreachableAPI(base: client.base, reason: "Cannot tell sushi from oMLX at \(client.base)")
        }
    }

    /// Builds one InferenceServer per configured provider, reusing a module
    /// kind only while that provider keeps the same base URL.
    public static func servers(
        from config: ModelSwitchConfig,
        cachedKinds: [String: ServerKind] = [:]
    ) async -> (servers: [InferenceServer], kinds: [String: ServerKind]) {
        var kinds = cachedKinds
        var servers: [InferenceServer] = []

        for provider in config.sortedProviders {
            let kind: ServerKind
            if let cached = kinds[provider.id] {
                kind = cached
            } else {
                kind = await detectKind(
                    base: provider.normalizedBaseURL,
                    token: provider.apiKey
                )
                if kind != .unknown {
                    kinds[provider.id] = kind
                }
            }

            servers.append(InferenceServer(
                provider: provider,
                kind: kind,
                api: makeAPI(
                    base: provider.normalizedBaseURL,
                    token: provider.apiKey,
                    kind: kind
                )
            ))
        }

        return (servers: servers, kinds: kinds)
    }
}

public struct UnreachableAPI: ModelServerAPI {
    public let base: String
    public let reason: String

    public init(base: String, reason: String) {
        self.base = base
        self.reason = reason
    }

    public func fetchModels() async throws -> [ServerModel] { throw APIError.server(reason) }
    public func load(_ id: String) async throws { throw APIError.server(reason) }
    public func unload(_ id: String) async throws { throw APIError.server(reason) }
    public func health() async throws -> ServerHealth { throw APIError.server(reason) }
}
