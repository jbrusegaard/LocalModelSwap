import Foundation
import XCTest
@testable import ModelSwitchCore

final class ModelSwitchConfigTests: XCTestCase {
    func testSaveLoadRoundTripAndMode() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let provider = TestConfig.provider(
            manualModels: ["a", "b"],
            modelOverrides: ["b": "962000"]
        )
        var config = TestConfig.config(provider: provider, path: dir.paths.appConfigURL)
        config.version = 1
        try config.save()

        XCTAssertEqual(AtomicFile.mode(of: dir.paths.appConfigURL), 0o600)
        let loaded = try ModelSwitchConfig.load(from: dir.paths.appConfigURL)
        XCTAssertEqual(loaded.providers, config.providers)
        XCTAssertEqual(loaded.providers.first?.manualModels, ["a", "b"])
        XCTAssertEqual(loaded.providers.first?.modelOverrides["b"], "962000")
    }

    func testEffectiveContextAndKnownModels() {
        let provider = TestConfig.provider(
            defaultContextTokens: "262144",
            manualModels: ["manual-1", "manual-2"],
            modelOverrides: ["scanned-x": "962000"]
        )
        XCTAssertEqual(provider.contextTokens(for: "scanned-x"), "962000")
        XCTAssertEqual(provider.contextTokens(for: "manual-1"), "262144")
        XCTAssertEqual(provider.knownModelIDs, ["manual-1", "manual-2", "scanned-x"])
        XCTAssertEqual(provider.normalizedTimeout, "600000")
        XCTAssertEqual(provider.normalizedBaseURL, TestConfig.base)
        XCTAssertEqual(provider.normalizedDefaultContext, "262144")
    }

    func testValidationRejectsDuplicateNameAndBase() {
        let one = TestConfig.provider(id: "1", name: "sushi")
        let two = TestConfig.provider(id: "2", name: "omlx", baseURL: "http://127.0.0.1:4200")
        let duplicateName = TestConfig.provider(id: "3", name: "Sushi", baseURL: "http://127.0.0.1:9")
        let duplicateBase = TestConfig.provider(id: "4", name: "other", baseURL: TestConfig.base)

        XCTAssertNil(two.validationProblem(existingProviders: [one, two]))
        XCTAssertEqual(
            duplicateName.validationProblem(existingProviders: [one, two]),
            "Another provider already uses that name"
        )
        XCTAssertEqual(
            duplicateBase.validationProblem(existingProviders: [one, two]),
            "Another provider already uses that URL"
        )

        var invalid = TestConfig.provider(id: "5", name: "x", baseURL: "ftp://host")
        XCTAssertNotNil(invalid.validationProblem(existingProviders: []))
        invalid.baseURL = "http://host"
        invalid.timeoutMs = "abc"
        XCTAssertNotNil(invalid.validationProblem(existingProviders: []))
        invalid.timeoutMs = "600000"
        invalid.defaultContextTokens = ""
        invalid.manualModels = ["a", "a"]
        XCTAssertNotNil(invalid.validationProblem(existingProviders: []))
    }

    func testUpsertAndRemove() {
        var config = ModelSwitchConfig(
            providers: [
                TestConfig.provider(id: "1", name: "sushi"),
                TestConfig.provider(id: "2", name: "sushi-2", baseURL: "http://x:1"),
            ]
        )
        config.upsert(TestConfig.provider(id: "3", name: "third", baseURL: "http://x:3"))
        XCTAssertEqual(config.providers.count, 3)
        config.upsert(TestConfig.provider(id: "3", name: "renamed", baseURL: "http://x:3"))
        XCTAssertEqual(config.provider(id: "3")?.name, "renamed")
        config.remove(id: "1")
        XCTAssertNil(config.provider(id: "1"))
    }
}

final class ProvidersJSONImporterTests: XCTestCase {
    private let sample = #"""
    {
      "version": 1,
      "current": "mac-studio-sushi-ds4.1",
      "providers": {
        "mac-studio": {
          "ANTHROPIC_BASE_URL": "http://172.29.69.69:4200",
          "ANTHROPIC_AUTH_TOKEN": "omlx-key",
          "ANTHROPIC_MODEL": "Qwen3.8-Flash-Next",
          "ANTHROPIC_SMALL_FAST_MODEL": "Qwen3.8-Flash-Next",
          "API_TIMEOUT_MS": "600000",
          "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
        },
        "mac-studio-sushi-glm": {
          "ANTHROPIC_BASE_URL": "http://172.29.69.69:12345/",
          "ANTHROPIC_AUTH_TOKEN": "sushi-key",
          "ANTHROPIC_MODEL": "beamster/GLM-5.3-Flash",
          "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
        },
        "mac-studio-sushi-ds4.1": {
          "ANTHROPIC_BASE_URL": "http://172.29.69.69:12345",
          "ANTHROPIC_AUTH_TOKEN": "sushi-key",
          "ANTHROPIC_MODEL": "beamster/DeepSeek-V4.1-Flash",
          "API_TIMEOUT_MS": "600000",
          "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "962000"
        }
      }
    }
    """#

    func testGroupsByBaseAndCollectsModels() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        try dir.writeProvidersJSON(sample)

        let imported = try ProvidersJSONImporter.read(from: dir.paths.providersURL)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported.map(\.baseURL), [
            "http://172.29.69.69:12345",
            "http://172.29.69.69:4200",
        ])

        let sushi = imported[0]
        XCTAssertEqual(sushi.apiKey, "sushi-key")
        XCTAssertEqual(sushi.timeoutMs, "600000")
        XCTAssertEqual(sushi.defaultContextTokens, "262144")
        XCTAssertEqual(sushi.models.map(\.id), [
            "beamster/DeepSeek-V4.1-Flash",
            "beamster/GLM-5.3-Flash",
        ])
        XCTAssertEqual(sushi.models[0].contextTokens, "962000")
        XCTAssertEqual(sushi.models[1].contextTokens, "262144")
        XCTAssertEqual(sushi.sourceNames, [
            "mac-studio-sushi-ds4.1",
            "mac-studio-sushi-glm",
        ])

        let omlx = imported[1]
        XCTAssertEqual(omlx.apiKey, "omlx-key")
        XCTAssertEqual(omlx.models.map(\.id), ["Qwen3.8-Flash-Next"])
    }

    func testMissingOrEmptyProvidersFile() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        XCTAssertThrowsError(try ProvidersJSONImporter.read(from: dir.paths.providersURL))

        try dir.writeProvidersJSON(#"{"version":1,"providers":{}}"#)
        XCTAssertEqual(try ProvidersJSONImporter.read(from: dir.paths.providersURL), [])
    }
}

final class SettingsMappingTests: XCTestCase {
    func testEnvironmentUsesProviderDefaultsAndOverrides() {
        let provider = TestConfig.provider(
            apiKey: "secret",
            timeoutMs: "123",
            defaultContextTokens: "262144",
            modelOverrides: ["big": "962000"]
        )

        let defaultEnv = SettingsMapping.environment(provider: provider, model: "big")
        XCTAssertEqual(defaultEnv["ANTHROPIC_BASE_URL"]?.stringValue, TestConfig.base)
        XCTAssertEqual(defaultEnv["ANTHROPIC_AUTH_TOKEN"]?.stringValue, "secret")
        XCTAssertEqual(defaultEnv["ANTHROPIC_MODEL"]?.stringValue, "big")
        XCTAssertEqual(defaultEnv["ANTHROPIC_SMALL_FAST_MODEL"]?.stringValue, "big")
        XCTAssertEqual(defaultEnv["API_TIMEOUT_MS"]?.stringValue, "123")
        XCTAssertEqual(defaultEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.stringValue, "962000")

        let smallEnv = SettingsMapping.environment(
            provider: provider,
            model: "big",
            contextTokens: "777",
            smallModel: "small"
        )
        XCTAssertEqual(smallEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]?.stringValue, "777")
        XCTAssertEqual(smallEnv["ANTHROPIC_SMALL_FAST_MODEL"]?.stringValue, "small")
    }

    func testProviderLookupNormalizesTrailingSlash() {
        let provider = TestConfig.provider(baseURL: TestConfig.base + "/")
        let found = SettingsMapping.provider(
            forBaseURL: TestConfig.base + "///",
            in: [provider]
        )
        XCTAssertEqual(found?.id, provider.id)
        XCTAssertNil(SettingsMapping.provider(forBaseURL: "", in: [provider]))
        XCTAssertNil(SettingsMapping.provider(forBaseURL: "http://elsewhere:1", in: [provider]))
    }
}
