import Foundation
import XCTest
@testable import ModelSwitchCore

final class ProviderApplierTests: XCTestCase {
    private func goldenSettings() -> JSONValue {
        .makeObject([
            ("autoCompactEnabled", .bool(true)),
            ("env", .makeObject([
                ("ANTHROPIC_BASE_URL", .string("http://old")),
                ("ANTHROPIC_AUTH_TOKEN", .string("oldtok")),
                ("ANTHROPIC_MODEL", .string("Old-Model")),
                ("ANTHROPIC_SMALL_FAST_MODEL", .string("Old-Model")),
                ("API_TIMEOUT_MS", .string("111")),
                ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", .string("222")),
                ("CUSTOM_ENV", .makeObject([("nested", .array([.int(1), .double(2.5), .null]))])),
            ])),
            ("modelSettings", .makeObject([
                ("old-model", .makeObject([("effortLevel", .string("high"))])),
            ])),
            ("statusLine", .makeObject([("type", .string("command"))])),
            ("unknownTop", .makeObject([("a", .int(1))])),
        ])
    }

    func testManagedKeysAreDeletedAndOrderIsCanonical() throws {
        let provider = JSONValue.makeObject([
            ("ANTHROPIC_BASE_URL", .string("http://new")),
            ("ANTHROPIC_MODEL", .string("New-Model")),
            ("ANTHROPIC_SMALL_FAST_MODEL", .string("New-Model")),
        ])
        let result = try ProviderApplier.apply(settings: goldenSettings(), providerEnv: provider)

        let env = result["env"]!
        XCTAssertEqual(keys(env), [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "CUSTOM_ENV",
        ])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"]?.stringValue, "http://new")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["API_TIMEOUT_MS"])
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        XCTAssertEqual(
            env["CUSTOM_ENV"]?.compactText,
            #"{"nested":[1,2.5,null]}"#
        )

        XCTAssertEqual(keys(result), ["autoCompactEnabled", "env", "modelSettings", "statusLine", "unknownTop"])
        XCTAssertEqual(result["statusLine"]?.compactText, #"{"type":"command"}"#)
        XCTAssertEqual(result["unknownTop"]?.compactText, #"{"a":1}"#)
    }

    func testModelSettingsAreCarriedToNewModel() throws {
        let provider = JSONValue.makeObject([
            ("ANTHROPIC_MODEL", .string("New-Model")),
        ])
        let result = try ProviderApplier.apply(settings: goldenSettings(), providerEnv: provider)
        let modelSettings = result["modelSettings"]!
        XCTAssertEqual(keys(modelSettings), ["old-model", "new-model"])
        XCTAssertEqual(modelSettings["new-model"]?.compactText, #"{"effortLevel":"high"}"#)
        XCTAssertEqual(modelSettings["old-model"]?.compactText, #"{"effortLevel":"high"}"#)
    }

    func testExistingNewModelDoesNotOverwrite() throws {
        var settings = goldenSettings()
        var ms = settings["modelSettings"]!
        ms.setValue(.makeObject([("effortLevel", .string("low"))]), forKey: "new-model")
        settings.setValue(ms, forKey: "modelSettings")

        let provider = JSONValue.makeObject([
            ("ANTHROPIC_MODEL", .string("New-Model")),
        ])
        let result = try ProviderApplier.apply(settings: settings, providerEnv: provider)
        XCTAssertEqual(result["modelSettings"]?["new-model"]?["effortLevel"]?.stringValue, "low")
    }

    func testCreatesEnvAndModelSettingsWhenMissing() throws {
        let settings = JSONValue.makeObject([("editorMode", .string("normal"))])
        let provider = JSONValue.makeObject([
            ("ANTHROPIC_MODEL", .string("x")),
            ("ANTHROPIC_AUTH_TOKEN", .string("t")),
        ])
        let result = try ProviderApplier.apply(settings: settings, providerEnv: provider)
        XCTAssertEqual(keys(result), ["editorMode", "env", "modelSettings"])
        XCTAssertEqual(keys(result["env"]!), ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"])
        XCTAssertEqual(result["modelSettings"]?.compactText, "{}")
    }

    func testInvalidShapesThrow() {
        XCTAssertThrowsError(try ProviderApplier.apply(
            settings: .array([]),
            providerEnv: .makeObject([("ANTHROPIC_MODEL", .string("x"))])
        ))
        XCTAssertThrowsError(try ProviderApplier.apply(
            settings: .makeObject([("env", .string("no"))]),
            providerEnv: .makeObject([("ANTHROPIC_MODEL", .string("x"))])
        ))
        XCTAssertThrowsError(try ProviderApplier.apply(
            settings: .makeObject([("modelSettings", .array([]))]),
            providerEnv: .makeObject([("ANTHROPIC_MODEL", .string("x"))])
        ))
    }
}

final class SettingsStoreTests: XCTestCase {
    func testApplyBacksUpAndWritesAtomicallyPreservingMode() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let original = goldenSettings().jsonText(pretty: true) + "\n"
        XCTAssertNoThrow(try AtomicFile.write(Data(original.utf8), to: dir.paths.settingsURL, mode: 0o640))

        let providerConfig = TestConfig.provider()
        let provider = SettingsMapping.environment(provider: providerConfig, model: "New-Model")
        let store = SettingsStore(paths: dir.paths)
        let result = try store.apply(providerEnv: provider)

        XCTAssertEqual(AtomicFile.mode(of: dir.paths.settingsURL), 0o640)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupURL.path))
        XCTAssertEqual(try String(contentsOf: result.backupURL, encoding: .utf8), original)

        let saved = try JSONValue.parse(try Data(contentsOf: dir.paths.settingsURL))
        XCTAssertEqual(saved["env"]?["ANTHROPIC_MODEL"]?.stringValue, "New-Model")
        XCTAssertEqual(saved["env"]?["ANTHROPIC_AUTH_TOKEN"]?.stringValue, TestConfig.token)
        XCTAssertNotNil(saved["modelSettings"]?["new-model"])
    }

    func testInvalidSettingsLeavesFilesUntouched() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        let broken = Data("{ not json".utf8)
        try AtomicFile.write(broken, to: dir.paths.settingsURL, mode: 0o644)

        let store = SettingsStore(paths: dir.paths)
        XCTAssertThrowsError(try store.apply(
            providerEnv: SettingsMapping.environment(provider: TestConfig.provider(), model: "x")
        ))

        XCTAssertEqual(try Data(contentsOf: dir.paths.settingsURL), broken)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.paths.backupsDir.path)) ?? []
        XCTAssertTrue(backups.isEmpty)
    }

    func testBackupPruneKeepsNewestTwenty() throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }

        for day in 1...25 {
            let name = String(format: "settings.json.202601%02d-000000.bak", day)
            try Data("{}".utf8).write(to: dir.paths.backupsDir.appendingPathComponent(name))
        }
        SettingsStore.pruneBackups(in: dir.paths.backupsDir, keep: 20)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.paths.backupsDir.path).sorted()
        XCTAssertEqual(remaining.count, 20)
        XCTAssertEqual(remaining.first, "settings.json.20260106-000000.bak")
        XCTAssertEqual(remaining.last, "settings.json.20260125-000000.bak")
    }

    private func goldenSettings() -> JSONValue {
        ProviderApplierTests().goldenSettingsForTests()
    }
}

private extension ProviderApplierTests {
    func goldenSettingsForTests() -> JSONValue {
        .makeObject([
            ("env", .makeObject([
                ("ANTHROPIC_BASE_URL", .string("http://old")),
                ("ANTHROPIC_AUTH_TOKEN", .string("oldtok")),
                ("ANTHROPIC_MODEL", .string("Old-Model")),
                ("ANTHROPIC_SMALL_FAST_MODEL", .string("Old-Model")),
                ("API_TIMEOUT_MS", .string("111")),
                ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", .string("222")),
            ])),
            ("modelSettings", .makeObject([
                ("old-model", .makeObject([("effortLevel", .string("high"))])),
            ])),
            ("statusLine", .makeObject([("type", .string("command"))])),
        ])
    }
}
