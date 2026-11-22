import Foundation
import XCTest
@testable import ModelSwitchCore

final class AdapterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockTransport.shared.reset()
    }

    override func tearDown() {
        MockTransport.shared.reset()
        super.tearDown()
    }

    private func sushiClient(handler: @escaping (URLRequest) -> (Int, Data)) -> SushiAPI {
        MockTransport.shared.set(handler)
        return SushiAPI(client: HTTPClient(
            base: "http://test:12345",
            token: "secret",
            session: MockTransport.shared.session
        ))
    }

    private func omlxClient(handler: @escaping (URLRequest) -> (Int, Data)) -> OMLXAPI {
        MockTransport.shared.set(handler)
        return OMLXAPI(client: HTTPClient(
            base: "http://test:4200",
            token: "secret",
            session: MockTransport.shared.session
        ))
    }

    func testSushiFetchModelsToleratesStringAndNumberSizes() async throws {
        let body = Data(#"""
        {"data":[
          {"id":"a","loaded":true,"state":"ready","bytes_on_disk":"53687091200","context_length":"262144","meta":{"quantization":"STQ"}},
          {"id":"b","loaded":false,"bytes_on_disk":1024,"meta":{}},
          {"id":"c","state":"loading"}
        ]}
        """#.utf8)
        let api = sushiClient { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (200, body)
        }

        let models = try await api.fetchModels()
        XCTAssertEqual(models.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(models[0].state, .ready)
        XCTAssertEqual(models[0].sizeBytes, 53_687_091_200)
        XCTAssertEqual(models[0].contextLength, 262_144)
        XCTAssertEqual(models[1].state, .unloaded)
        XCTAssertEqual(models[2].state, .loading)
        XCTAssertFalse(models[2].loaded)
    }

    func testSushiLoadSendsDefaultTrueAndRejectsLoadingState() async throws {
        let api = sushiClient { request in
            XCTAssertEqual(request.url?.path, "/v1/load-model")
            let body = try? JSONValue.parse(MockData.body(of: request) ?? Data())
            XCTAssertEqual(body?["model"]?.stringValue, "m")
            XCTAssertEqual(body?["default"]?.boolValue, true)
            return (200, Data(#"{"model":{"id":"m","state":"loading"}}"#.utf8))
        }
        do {
            try await api.load("m")
            XCTFail("expected loading state to fail")
        } catch let error as APIError {
            XCTAssertTrue(error.message.contains("state is \"loading\""))
        }
    }

    func testSushiUnloadNon200SurfacesError() async throws {
        let api = sushiClient { request in
            XCTAssertEqual(request.url?.path, "/v1/unload-model")
            return (409, Data(#"{"error":"model not loaded"}"#.utf8))
        }
        do {
            try await api.unload("m")
            XCTFail("expected error")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "model not loaded")
        }
    }

    func testOMLXFetchModelsAndEmptyBodyLoad() async throws {
        let status = Data(#"""
        {"models":[
          {"id":"x","loaded":true,"is_loading":false,"estimated_size":10,"actual_size":20,"model_format":"oQ4e"},
          {"id":"y","loaded":false,"is_loading":true,"estimated_size":30}
        ]}
        """#.utf8)

        let api = omlxClient { request in
            if request.url?.path == "/v1/models/status" {
                return (200, status)
            }
            // A namespaced id must keep `/` percent-escaped as one path segment.
            let absolute = request.url?.absoluteString.lowercased() ?? ""
            XCTAssertTrue(absolute.contains("org%2fmodel"))
            XCTAssertNil(request.httpBody)
            return (200, Data(#"{"status":"ok"}"#.utf8))
        }

        let models = try await api.fetchModels()
        XCTAssertEqual(models[0].state, .ready)
        XCTAssertEqual(models[0].sizeBytes, 20)
        XCTAssertEqual(models[1].state, .loading)

        try await api.load("org/model")
    }

    func testOMLXUnloadAcceptances() async throws {
        var status = 202
        let api = omlxClient { _ in (status, Data(#"{"status":"unloading"}"#.utf8)) }
        do { try await api.unload("x") } catch { XCTFail("202 should be accepted: \(error)") }

        status = 400
        do {
            try await api.unload("x")
            XCTFail("expected not-loaded")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "not loaded")
        }
    }

    func testHealthIsUpOn200() async throws {
        let body = Data(#"{"status":"healthy","engine_pool":{}}"#.utf8)
        let api = omlxClient { _ in (200, body) }
        let health = try await api.health()
        XCTAssertTrue(health.up)
    }

    func test503CountsAsUp() {
        let health = ServerDiscovery.parseHealth(HTTPResponse(status: 503, body: Data()))
        XCTAssertTrue(health.up)
    }

    func testDetectKindByHealthAndPortHint() async {
        MockTransport.shared.set { _ in (200, Data(#"{"status":"ok","engine_pool":{}}"#.utf8)) }
        var kind = await ServerDiscovery.detectKind(
            base: "http://test:7777",
            token: "",
            session: MockTransport.shared.session
        )
        XCTAssertEqual(kind, .omlx)

        MockTransport.shared.set { _ in (401, Data()) }
        kind = await ServerDiscovery.detectKind(base: "http://test:12345", token: "", session: MockTransport.shared.session)
        XCTAssertEqual(kind, .sushi)
        kind = await ServerDiscovery.detectKind(base: "http://test:4200", token: "", session: MockTransport.shared.session)
        XCTAssertEqual(kind, .omlx)
    }

    func testDetectKindBySushiOwnedBy() async {
        MockTransport.shared.set { request in
            if request.url?.path == "/v1/models" {
                return (200, Data(#"{"data":[{"id":"m","owned_by":"sushi"}]}"#.utf8))
            }
            return (401, Data())
        }
        let kind = await ServerDiscovery.detectKind(base: "http://test:7777", token: "", session: MockTransport.shared.session)
        XCTAssertEqual(kind, .sushi)
    }

    func testAPIErrorExtraction() {
        XCTAssertEqual(APIError.from(status: 500, data: Data(#"{"detail":"boom"}"#.utf8)).message, "boom")
        XCTAssertEqual(APIError.from(status: 500, data: Data(#"{"error":{"message":"openai"}}"#.utf8)).message, "openai")
        XCTAssertEqual(APIError.from(status: 500, data: Data(#"{"message":"plain"}"#.utf8)).message, "plain")
        XCTAssertEqual(APIError.from(status: 500, data: Data("raw text".utf8)).message, "raw text")
        XCTAssertEqual(APIError.from(status: 500, data: Data()).message, "HTTP 500")
        XCTAssertTrue(APIError.from(status: 401, data: Data()).isAuth)
        XCTAssertTrue(APIError.from(status: 403, data: Data()).isAuth)
        let long = APIError.from(status: 500, data: Data(String(repeating: "x", count: 300).utf8)).message
        XCTAssertEqual(long.count, 241)
    }
}

enum MockData {
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
