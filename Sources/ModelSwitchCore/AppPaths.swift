import Foundation

/// Every file the app touches. `claudeDir` is read/written for settings.json;
/// `appConfigURL` is Model Switch's own registry and never `providers.json`.
public struct AppPaths: Sendable, Equatable {
    public var claudeDir: URL
    public var appConfigURL: URL

    public init(claudeDir: URL, appConfigURL: URL? = nil) {
        self.claudeDir = claudeDir
        self.appConfigURL = appConfigURL ?? AppPaths.defaultConfigURL()
    }

    public var providersURL: URL {
        claudeDir.appendingPathComponent("providers.json", isDirectory: false)
    }

    public var settingsURL: URL {
        claudeDir.appendingPathComponent("settings.json", isDirectory: false)
    }

    public var settingsLocalURL: URL {
        claudeDir.appendingPathComponent("settings.local.json", isDirectory: false)
    }

    public var backupsDir: URL {
        claudeDir.appendingPathComponent("backups", isDirectory: true)
    }

    public static func `default`() -> AppPaths {
        let environment = ProcessInfo.processInfo.environment
        let claudeDir: URL
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            claudeDir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            claudeDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        }

        let configPath = environment["MODEL_SWITCH_CONFIG"]
        let configURL = configPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? defaultConfigURL()
        return AppPaths(claudeDir: claudeDir, appConfigURL: configURL)
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".model-switch.json", isDirectory: false)
    }

    public func ensureClaudeLayout() throws {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            throw FileFailure.createDirectoryFailed(claudeDir.path)
        }
    }
}
