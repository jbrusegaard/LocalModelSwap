import Foundation

/// sushi (port 12345 by convention): OpenAI-ish `/v1/models` with loaded/state
/// inline, plus `/v1/load-model` and `/v1/unload-model` JSON endpoints.
public struct SushiAPI: ModelServerAPI {
    public let client: HTTPClient
    public let base: String

    public init(client: HTTPClient) {
        self.client = client
        self.base = client.base
    }

    public func fetchModels() async throws -> [ServerModel] {
        let response = try await client.get("/v1/models", timeout: 15)
        guard response.status == 200 else {
            throw APIError.from(status: response.status, data: response.body)
        }
        guard let root = response.object, let rows = root["data"]?.arrayValues else {
            throw APIError.decoding("sushi /v1/models response has no data array")
        }

        var models: [ServerModel] = []
        for row in rows {
            guard let id = row["id"]?.stringValue, !id.isEmpty else { continue }
            let loaded = row["loaded"]?.boolValue ?? false
            let rawState = row["state"]?.stringValue ?? (loaded ? "ready" : "unloaded")
            let state = ModelState(rawValue: rawState.lowercased()) ?? .unknown
            models.append(ServerModel(
                id: id,
                loaded: loaded || state == .ready,
                state: state,
                sizeBytes: row["bytes_on_disk"]?.intValue,
                contextLength: row["context_length"]?.intValue.map(Int.init)
            ))
        }
        return models
    }

    public func load(_ id: String) async throws {
        let response = try await client.post(
            "/v1/load-model",
            json: .object([
                JSONPair(key: "model", value: .string(id)),
                JSONPair(key: "default", value: .bool(true)),
            ]),
            timeout: 1800
        )
        guard response.status == 200 else {
            throw APIError.from(status: response.status, data: response.body)
        }
        if let state = response.object?["model"]?["state"]?.stringValue, !state.isEmpty, state != "ready" {
            throw APIError.server("load answered \(id) but state is \"\(state)\"")
        }
    }

    public func unload(_ id: String) async throws {
        let response = try await client.post(
            "/v1/unload-model",
            json: .object([JSONPair(key: "model", value: .string(id))]),
            timeout: 1800
        )
        guard response.status == 200 else {
            throw APIError.from(status: response.status, data: response.body)
        }
    }

    public func health() async throws -> ServerHealth {
        let response = try await client.get("/health", timeout: 8)
        return ServerDiscovery.parseHealth(response)
    }

}
