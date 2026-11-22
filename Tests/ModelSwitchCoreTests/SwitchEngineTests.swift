import Foundation
import XCTest
@testable import ModelSwitchCore

@MainActor
final class SwitchEngineTests: XCTestCase {
    private let a = ServerModel(id: "A", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)
    private let b = ServerModel(id: "B", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)
    private let c = ServerModel(id: "C", loaded: false, state: .loading, sizeBytes: 2, contextLength: 96_200)
    private let d = ServerModel(id: "D", loaded: false, state: .unloaded)

    private func provider() -> ProviderConfiguration {
        TestConfig.provider(
            defaultContextTokens: "262144",
            manualModels: ["C"],
            modelOverrides: ["C": "962000"]
        )
    }

    private func makeRequest(
        paths: AppPaths,
        options: SwitchOptions = SwitchOptions(
            pollInterval: .milliseconds(20),
            unloadTimeout: .seconds(2),
            loadTimeout: .seconds(5),
            verifyTimeout: .seconds(2)
        )
    ) -> (SwitchRequest, FakeServerAPI, ProviderConfiguration) {
        let provider = provider()
        let api = FakeServerAPI(models: [a, b, c, d])
        let server = TestConfig.server(provider: provider, api: api)
        let request = SwitchRequest(
            server: server,
            modelID: "C",
            options: options,
            paths: paths
        )
        return (request, api, provider)
    }

    func testSwitchUnloadsOthersThenLoadsAndWritesSettings() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        try dir.writeSettings(TestConfig.settings(provider: provider, model: "A"))
        let (request, api, _) = makeRequest(paths: dir.paths)

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .success(let success) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(api.calls, ["unload A", "unload B", "load C"])
        XCTAssertEqual(success.model.id, "C")
        XCTAssertEqual(success.providerName, "sushi")
        XCTAssertEqual(success.contextTokens, "962000")
        XCTAssertNotNil(success.backup)
        XCTAssertGreaterThanOrEqual(success.elapsed, 0)

        let settings = try JSONValue.parse(try Data(contentsOf: dir.paths.settingsURL))
        XCTAssertEqual(settings["env"]?["ANTHROPIC_BASE_URL"]?.stringValue, TestConfig.base)
        XCTAssertEqual(settings["env"]?["ANTHROPIC_AUTH_TOKEN"]?.stringValue, TestConfig.token)
        XCTAssertEqual(settings["env"]?["ANTHROPIC_MODEL"]?.stringValue, "C")
        XCTAssertEqual(settings["env"]?["ANTHROPIC_SMALL_FAST_MODEL"]?.stringValue, "C")
        XCTAssertEqual(settings["env"]?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.stringValue, "962000")
        XCTAssertEqual(settings["modelSettings"]?["c"]?.compactText, #"{"effortLevel":"high"}"#)
        XCTAssertEqual(settings["statusLine"]?.compactText, #"{"type":"command","command":"~/.claude/statusline.sh"}"#)
    }

    func testSettingsAlreadyCorrectLeavesProvidersJSONAlone() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let providersJSON = #"{"version":1,"current":"cps-current","providers":{"cps":{"ANTHROPIC_BASE_URL":"http://cps:1","ANTHROPIC_MODEL":"m"}}}"#
        try dir.writeProvidersJSON(providersJSON)

        let provider = provider()
        try dir.writeSettings(TestConfig.settings(provider: provider, model: "C"))
        let (request, _, _) = makeRequest(paths: dir.paths)

        _ = await SwitchEngine().run(request) { _ in }
        XCTAssertEqual(
            try String(contentsOf: dir.paths.providersURL, encoding: .utf8),
            providersJSON,
            "Model Switch must never rewrite providers.json"
        )
    }

    func testKeepOthersSkipsUnloads() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        try dir.writeSettings(TestConfig.settings(provider: provider, model: "A"))
        let options = SwitchOptions(
            keepOthers: true,
            pollInterval: .milliseconds(20),
            unloadTimeout: .seconds(2),
            loadTimeout: .seconds(5),
            verifyTimeout: .seconds(2)
        )
        let (request, api, _) = makeRequest(paths: dir.paths, options: options)

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .success = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(api.calls, ["load C"])
    }

    func testExplicitContextOverrideWins() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        try dir.writeSettings(TestConfig.settings(provider: provider, model: "A"))
        let (baseRequest, api, _) = makeRequest(paths: dir.paths)
        var request = baseRequest
        request.contextTokens = "5000"

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .success(let success) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(success.contextTokens, "5000")
        let settings = try JSONValue.parse(try Data(contentsOf: dir.paths.settingsURL))
        XCTAssertEqual(settings["env"]?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.stringValue, "5000")
        XCTAssertEqual(api.calls, ["unload A", "unload B", "load C"])
    }

    func testAuthFailureDoesNotTouchSettings() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        let originalSettings = TestConfig.settings(provider: provider, model: "A")
        let original = originalSettings.jsonText(pretty: true) + "\n"
        try dir.writeSettings(originalSettings)

        let (request, api, _) = makeRequest(paths: dir.paths)
        api.authOnFetch = true

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .failed(let failure) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.message.lowercased().contains("authentication") || failure.message.contains("401"))
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(try String(contentsOf: dir.paths.settingsURL, encoding: .utf8), original)
    }

    func testLoadFailureDoesNotWriteSettings() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        let originalSettings = TestConfig.settings(provider: provider, model: "A")
        let original = originalSettings.jsonText(pretty: true) + "\n"
        try dir.writeSettings(originalSettings)

        let (request, api, _) = makeRequest(paths: dir.paths)
        api.loadError = APIError.http(status: 507, message: "not enough memory")

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .failed(let failure) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.message.contains("507") || failure.message.contains("not enough memory"))
        XCTAssertNil(failure.backup)
        XCTAssertEqual(try String(contentsOf: dir.paths.settingsURL, encoding: .utf8), original)
    }

    func testVerifyTimeoutFails() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        try dir.writeSettings(TestConfig.settings(provider: provider(), model: "A"))

        let (request, api, _) = makeRequest(
            paths: dir.paths,
            options: SwitchOptions(
                pollInterval: .milliseconds(20),
                unloadTimeout: .seconds(1),
                loadTimeout: .seconds(5),
                verifyTimeout: .milliseconds(150)
            )
        )
        api.autoReady = false

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .failed(let failure) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(failure.message.contains("timed out"))
        XCTAssertTrue(failure.message.contains("verify"))
    }

    func testUnknownModelMakesNoCalls() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        try dir.writeSettings(TestConfig.settings(provider: provider(), model: "A"))

        let provider = provider()
        let api = FakeServerAPI(models: [a, b, c, d])
        let server = TestConfig.server(provider: provider, api: api)
        let request = SwitchRequest(
            server: server,
            modelID: "not-a-model",
            options: SwitchOptions(pollInterval: .milliseconds(10)),
            paths: dir.paths
        )

        let outcome = await SwitchEngine().run(request) { _ in }
        guard case .failed(let failure) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(failure.message.contains("not found"))
        XCTAssertEqual(api.calls, [])
    }

    func testCancellationStopsWaits() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = provider()
        let originalSettings = TestConfig.settings(provider: provider, model: "A")
        let original = originalSettings.jsonText(pretty: true) + "\n"
        try dir.writeSettings(originalSettings)

        let (request, api, _) = makeRequest(paths: dir.paths)
        api.autoReady = false
        api.loadDelay = .seconds(5)

        let engine = SwitchEngine()
        let task = Task { @MainActor in
            await engine.run(request) { _ in }
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let outcome = await task.value

        guard case .cancelled = outcome else { return XCTFail("expected cancelled, got \(outcome)") }
        XCTAssertEqual(try String(contentsOf: dir.paths.settingsURL, encoding: .utf8), original)
    }
}
