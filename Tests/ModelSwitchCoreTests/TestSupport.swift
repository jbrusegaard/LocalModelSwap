import Foundation
import XCTest
@testable import ModelSwitchCore

// MARK: - Temp dir

struct TempClaudeDir {
    let url: URL
    let paths: AppPaths

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelSwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        paths = AppPaths(
            claudeDir: url,
            appConfigURL: url.appendingPathComponent("model-switch.json")
        )
        try paths.ensureClaudeLayout()
    }

    func writeConfig(_ config: ModelSwitchConfig) throws {
        try config.save(to: paths.appConfigURL)
    }

    func writeProvidersJSON(_ raw: String) throws {
        try AtomicFile.write(Data(raw.utf8), to: paths.providersURL, mode: 0o600)
    }

    func writeSettings(_ json: JSONValue) throws {
        var data = try json.serializedData(pretty: true)
        data.append(0x0A)
        try AtomicFile.write(data, to: paths.settingsURL, mode: 0o644)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Fixture config

enum TestConfig {
    static let base = "http://127.0.0.1:12345"
    static let token = "secret-token"

    static func provider(
        id: String = "test-provider",
        name: String = "sushi",
        baseURL: String = base,
        apiKey: String = token,
        timeoutMs: String = "600000",
        defaultContextTokens: String = "262144",
        manualModels: [String] = [],
        modelOverrides: [String: String] = [:]
    ) -> ProviderConfiguration {
        ProviderConfiguration(
            id: id,
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            timeoutMs: timeoutMs,
            defaultContextTokens: defaultContextTokens,
            manualModels: manualModels,
            modelOverrides: modelOverrides
        )
    }

    static func config(
        provider: ProviderConfiguration,
        path: URL = URL(fileURLWithPath: "/dev/null")
    ) -> ModelSwitchConfig {
        ModelSwitchConfig(version: 1, providers: [provider], path: path)
    }

    static func settings(provider: ProviderConfiguration, model: String) -> JSONValue {
        .makeObject([
            ("editorMode", .string("normal")),
            ("env", SettingsMapping.environment(provider: provider, model: model)),
            ("modelSettings", .object([
                JSONPair(key: model.lowercased(), value: .makeObject([
                    ("effortLevel", .string("high")),
                ])),
            ])),
            ("statusLine", .makeObject([
                ("type", .string("command")),
                ("command", .string("~/.claude/statusline.sh")),
            ])),
        ])
    }

    static func server(
        provider: ProviderConfiguration,
        api: any ModelServerAPI,
        kind: ServerKind = .sushi
    ) -> InferenceServer {
        InferenceServer(provider: provider, kind: kind, api: api)
    }
}

// MARK: - Fake server API

final class FakeServerAPI: ModelServerAPI, @unchecked Sendable {
    let base: String
    private let lock = NSLock()
    private var storage: [ServerModel]
    private var callStorage: [String] = []

    var autoReady = true
    var authOnFetch = false
    var loadError: APIError?
    var unloadError: APIError?
    var loadDelay: Duration = .zero
    var unloadDelay: Duration = .zero

    init(base: String = TestConfig.base, models: [ServerModel]) {
        self.base = base
        self.storage = models
    }

    var models: [ServerModel] { locked { storage } }
    var calls: [String] { locked { callStorage } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func fetchModels() async throws -> [ServerModel] {
        if authOnFetch {
            throw APIError.unauthorized(status: 401, message: "Authentication failed")
        }
        return locked { storage }
    }

    func load(_ id: String) async throws {
        locked { callStorage.append("load \(id)") }
        if let loadError { throw loadError }
        if loadDelay > .zero {
            try await Task.sleep(for: loadDelay)
        }
        locked {
            guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
            storage[index] = ServerModel(
                id: id,
                loaded: true,
                state: autoReady ? .ready : .loading,
                sizeBytes: storage[index].sizeBytes,
                contextLength: storage[index].contextLength
            )
        }
    }

    func unload(_ id: String) async throws {
        locked { callStorage.append("unload \(id)") }
        if let unloadError { throw unloadError }
        if unloadDelay > .zero {
            try await Task.sleep(for: unloadDelay)
        }
        locked {
            guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
            storage[index] = ServerModel(
                id: id,
                loaded: false,
                state: .unloaded,
                sizeBytes: storage[index].sizeBytes,
                contextLength: storage[index].contextLength
            )
        }
    }

    func health() async throws -> ServerHealth {
        ServerHealth(up: true)
    }

    func setModels(_ rows: [ServerModel]) {
        locked { storage = rows }
    }
}

// MARK: - Mock HTTP transport

final class MockTransport {
    private let lock = NSLock()
    private var handler: ((URLRequest) -> (Int, Data))?
    private var requestLog: [URLRequest] = []

    func set(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func reset() {
        lock.lock(); handler = nil; requestLog = []; lock.unlock()
    }

    func handleX(_ request: URLRequest) -> (Int, Data)? {
        lock.lock()
        requestLog.append(request)
        let handler = self.handler
        lock.unlock()
        return handler?(request)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    var lastAuthorization: String? {
        requests.last?.value(forHTTPHeaderField: "Authorization")
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    static let shared = MockTransport()
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (status, body) = MockTransport.shared.handleX(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

func pairs(_ value: JSONValue) -> [JSONPair] {
    value.objectPairs ?? []
}

func keys(_ value: JSONValue) -> [String] {
    pairs(value).map(\.key)
}
