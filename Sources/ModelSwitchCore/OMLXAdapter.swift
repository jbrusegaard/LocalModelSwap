import Foundation

/// oMLX (port 4200 by convention): `/v1/models/status` for the authoritative
/// loaded/is_loading table, and bodyless `/v1/models/{id}/load|unload`.
public struct OMLXAPI: ModelServerAPI {
    public let client: HTTPClient
    public let base: String

    public init(client: HTTPClient) {
        self.client = client
        self.base = client.base
    }

    public func fetchModels() async throws -> [ServerModel] {
        let response = try await client.get("/v1/models/status", timeout: 15)
        guard response.status == 200 else {
            throw APIError.from(status: response.status, data: response.body)
        }
        guard let root = response.object, let rows = root["models"]?.arrayValues else {
            throw APIError.decoding("oMLX /v1/models/status response has no models array")
        }

        var models: [ServerModel] = []
        for row in rows {
            guard let id = row["id"]?.stringValue, !id.isEmpty else { continue }
            let loaded = row["loaded"]?.boolValue ?? false
            let isLoading = row["is_loading"]?.boolValue ?? false
            let state: ModelState = loaded ? .ready : (isLoading ? .loading : .unloaded)
            var size = row["actual_size"]?.intValue ?? 0
            if size == 0 {
                size = row["estimated_size"]?.intValue ?? 0
            }
            models.append(ServerModel(
                id: id,
                loaded: loaded,
                state: state,
                sizeBytes: size > 0 ? size : nil,
                contextLength: row["context_length"]?.intValue.map(Int.init)
            ))
        }
        return models
    }

    public func load(_ id: String) async throws {
        let response = try await client.post("/v1/models/\(Self.pathEscaped(id))/load", json: nil, timeout: 1800)
        guard response.status == 200 else {
            throw APIError.from(status: response.status, data: response.body)
        }
    }

    public func unload(_ id: String) async throws {
        let response = try await client.post("/v1/models/\(Self.pathEscaped(id))/unload", json: nil, timeout: 1800)
        switch response.status {
        case 200, 202:
            return
        case 400:
            throw APIError.http(status: 400, message: "not loaded")
        default:
            throw APIError.from(status: response.status, data: response.body)
        }
    }

    public func health() async throws -> ServerHealth {
        let response = try await client.get("/health", timeout: 8)
        return ServerDiscovery.parseHealth(response)
    }

    /// Percent-escape a whole model id for a path segment. `/` is NOT allowed
    /// unescaped here even though it is in `urlPathAllowed`.
    static func pathEscaped(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}
