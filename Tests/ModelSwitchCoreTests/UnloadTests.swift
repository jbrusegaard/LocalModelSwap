import Foundation
import XCTest
@testable import ModelSwitchCore

/// Probe for MockTransport handlers that flip server state mid-test.
final class UnloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

@MainActor
final class UnloadTests: XCTestCase {
    override func setUp() { super.setUp(); MockTransport.shared.reset() }
    override func tearDown() { MockTransport.shared.reset(); super.tearDown() }

    private let loadedA = ServerModel(id: "A", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)
    private let loadedB = ServerModel(id: "B", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)

    private func makeServer(api: any ModelServerAPI) -> InferenceServer {
        TestConfig.server(provider: TestConfig.provider(), api: api)
    }

    private func shortOptions() -> SwitchOptions {
        SwitchOptions(pollInterval: .milliseconds(20), unloadTimeout: .seconds(2))
    }

    func testUnloadSuccessLeavesSettingsAlone() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        try dir.writeSettings(TestConfig.settings(provider: TestConfig.provider(), model: "A"))
        let original = try String(contentsOf: dir.paths.settingsURL, encoding: .utf8)

        let api = FakeServerAPI(models: [loadedA, loadedB])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .unloaded(let model, let providerName, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertEqual(model.id, "A")
        XCTAssertEqual(providerName, "sushi")
        XCTAssertFalse(already)
        XCTAssertEqual(model.loaded, false)
        XCTAssertEqual(model.state, .unloaded)
        XCTAssertEqual(api.calls, ["unload A"])
        XCTAssertEqual(try String(contentsOf: dir.paths.settingsURL, encoding: .utf8), original)
    }

    func testUnloadToleratesNotLoadedAnswer() async throws {
        let probe = UnloadProbe()
        MockTransport.shared.set { request in
            if request.httpMethod == "POST" {
                probe.set()
                return (409, Data(#"{"error":"model not loaded"}"#.utf8))
            }
            let body = probe.isSet
                ? #"{"data":[{"id":"a","loaded":false,"state":"unloaded"}]}"#
                : #"{"data":[{"id":"a","loaded":true,"state":"ready"}]}"#
            return (200, Data(body.utf8))
        }
        let api = SushiAPI(client: HTTPClient(
            base: "http://test:12345", token: "secret", session: MockTransport.shared.session
        ))
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "a", options: shortOptions()
        ) { _ in }

        guard case .unloaded(_, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertFalse(already)
    }

    func testUnloadAlreadyUnloadedMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [ServerModel(id: "A", loaded: false, state: .unloaded)])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .unloaded(_, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertTrue(already)
        XCTAssertEqual(api.calls, [])
    }

    func testUnloadNotFoundMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [loadedB])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("not found"))
        XCTAssertEqual(api.calls, [])
    }

    func testUnloadWaitTimeoutFails() async throws {
        MockTransport.shared.set { request in
            if request.httpMethod == "POST" {
                return (200, Data(#"{"status":"unloading"}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"a","loaded":true,"state":"ready"}]}"#.utf8))
        }
        let api = SushiAPI(client: HTTPClient(
            base: "http://test:12345", token: "secret", session: MockTransport.shared.session
        ))
        let options = SwitchOptions(pollInterval: .milliseconds(20), unloadTimeout: .milliseconds(150))
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "a", options: options
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("timed out"))
        XCTAssertTrue(message.contains("wait for unload"))
    }

    func testUnloadOfLoadingModelStillAttemptsUnload() async throws {
        let api = FakeServerAPI(models: [ServerModel(id: "C", loaded: false, state: .loading)])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "C", options: shortOptions()
        ) { _ in }

        guard case .unloaded(let model, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertFalse(already)
        XCTAssertEqual(model.state, .unloaded)
        XCTAssertEqual(api.calls, ["unload C"])
    }

    func testUnloadCancellationStopsWait() async throws {
        let api = FakeServerAPI(models: [loadedA])
        api.unloadDelay = .seconds(5)

        let engine = SwitchEngine()
        let task = Task { @MainActor in
            await engine.unload(
                server: makeServer(api: api), modelID: "A", options: shortOptions()
            ) { _ in }
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let outcome = await task.value

        guard case .cancelled(let phase, let model) = outcome else {
            return XCTFail("expected cancelled, got \(outcome)")
        }
        XCTAssertEqual(phase, .unloading)
        XCTAssertEqual(model, "A")
    }

    func testUnloadAuthFailureMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [loadedA])
        api.authOnFetch = true
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Authentication") || message.contains("401"))
        XCTAssertEqual(api.calls, [])
    }

    func testUnloadCallErrorSurfacesServerMessage() async throws {
        let api = FakeServerAPI(models: [loadedA])
        api.unloadError = APIError.server("unload refused: model is busy")
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("busy"))
        XCTAssertFalse(message.contains("timed out"))
        XCTAssertEqual(api.calls, ["unload A"])
    }
}
