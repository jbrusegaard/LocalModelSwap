import Foundation

public enum SwitchPhase: String, Sendable, Equatable {
    case resolving
    case unloading
    case waitingUnload
    case loading
    case verifying
    case writingSettings
    case done
    case error

    public var title: String {
        switch self {
        case .resolving: return "Resolve"
        case .unloading: return "Unload"
        case .waitingUnload: return "Wait for unload"
        case .loading: return "Load"
        case .verifying: return "Verify"
        case .writingSettings: return "Write Claude settings"
        case .done: return "Done"
        case .error: return "Failed"
        }
    }
}

public struct SwitchStep: Sendable, Equatable {
    public let phase: SwitchPhase
    public let model: String?
    public let detail: String?

    public init(phase: SwitchPhase, model: String? = nil, detail: String? = nil) {
        self.phase = phase
        self.model = model
        self.detail = detail
    }
}

public struct SwitchOptions: Sendable, Equatable {
    public var keepOthers: Bool
    public var pollInterval: Duration
    public var unloadTimeout: Duration
    public var loadTimeout: Duration
    public var verifyTimeout: Duration

    public init(
        keepOthers: Bool = false,
        pollInterval: Duration = .seconds(2),
        unloadTimeout: Duration = .seconds(180),
        loadTimeout: Duration = .seconds(1800),
        verifyTimeout: Duration = .seconds(1800)
    ) {
        self.keepOthers = keepOthers
        self.pollInterval = pollInterval
        self.unloadTimeout = unloadTimeout
        self.loadTimeout = loadTimeout
        self.verifyTimeout = verifyTimeout
    }

}

public struct SwitchRequest: Sendable {
    public var server: InferenceServer
    public var modelID: String
    public var options: SwitchOptions
    public var paths: AppPaths
    /// Explicit settings override; nil uses the provider's per-model default.
    public var contextTokens: String?

    public init(
        server: InferenceServer,
        modelID: String,
        options: SwitchOptions = SwitchOptions(),
        paths: AppPaths,
        contextTokens: String? = nil
    ) {
        self.server = server
        self.modelID = modelID
        self.options = options
        self.paths = paths
        self.contextTokens = contextTokens
    }
}

public struct SwitchSuccess: Sendable, Equatable {
    public let serverName: String
    public let providerName: String
    public let model: ServerModel
    public let contextTokens: String
    public let backup: URL?
    public let elapsed: TimeInterval
}

public struct SwitchFailure: Sendable, Equatable {
    public let message: String
    public let backup: URL?

    public init(message: String, backup: URL?) {
        self.message = message
        self.backup = backup
    }
}

public enum SwitchOutcome: Sendable {
    case success(SwitchSuccess)
    case cancelled(phase: SwitchPhase, model: String?)
    case failed(SwitchFailure)

    public var success: SwitchSuccess? {
        if case .success(let value) = self { return value }
        return nil
    }
}

public enum UnloadOutcome: Sendable {
    case unloaded(ServerModel, provider: String, elapsed: TimeInterval, alreadyUnloaded: Bool)
    case cancelled(phase: SwitchPhase, model: String?)
    case failed(message: String)
}

/// Resolve → unload others → load → verify → settings. Runs on the main actor
/// so progress arrives in view order; network awaits suspend, not block.
@MainActor
public struct SwitchEngine {
    public init() {}

    public func run(
        _ request: SwitchRequest,
        progress: @escaping (SwitchStep) -> Void
    ) async -> SwitchOutcome {
        let started = Date()
        var lastPhase: SwitchPhase = .resolving
        var lastModel: String?

        func emit(_ phase: SwitchPhase, _ model: String?, _ detail: String? = nil) {
            lastPhase = phase
            if let model { lastModel = model }
            progress(SwitchStep(phase: phase, model: model, detail: detail))
        }

        func fail(_ message: String, backup: URL? = nil) -> SwitchOutcome {
            emit(.error, lastModel, message)
            return .failed(SwitchFailure(message: message, backup: backup))
        }

        do {
            emit(.resolving, nil, "resolving \(request.modelID)")
            let models = try await request.server.api.fetchModels()
            let target = try Self.resolve(models: models, requested: request.modelID)

            if !request.options.keepOthers {
                for row in models where row.loaded && row.id != target.id {
                    emit(.unloading, row.id, "unloading")
                    do {
                        try await request.server.api.unload(row.id)
                    } catch {
                        if !Self.isAlreadyUnloaded(error) {
                            return fail("unload: \(Self.describe(error))")
                        }
                    }

                    emit(.waitingUnload, row.id, "waiting for unload")
                    _ = try await Self.waitForRow(
                        api: request.server.api,
                        id: row.id,
                        timeout: request.options.unloadTimeout,
                        poll: request.options.pollInterval
                    ) { !$0.loaded }
                    emit(.waitingUnload, row.id, "unloaded")
                }
            }

            emit(.loading, target.id, "loading (this can take minutes for large packs)")
            do {
                try await request.server.api.load(target.id)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    emit(.error, target.id, "cancelled")
                    return .cancelled(phase: .loading, model: target.id)
                }
                return fail("load: \(Self.describe(error))")
            }

            emit(.verifying, target.id, "waiting for ready")
            let verified = try await Self.waitForRow(
                api: request.server.api,
                id: target.id,
                timeout: request.options.verifyTimeout,
                poll: request.options.pollInterval
            ) { $0.state == .ready }

            let finalRow = (try? await request.server.api.fetchModels())?
                .first(where: { $0.id == target.id }) ?? verified
            let provider = request.server.provider
            let context = request.contextTokens?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveContext = (context?.isEmpty == false ? context : nil)
                ?? provider.contextTokens(for: target.id)

            emit(.writingSettings, target.id, "updating ~/.claude/settings.json")
            let env = SettingsMapping.environment(
                provider: provider,
                model: target.id,
                contextTokens: effectiveContext
            )
            let settingsResult: SettingsApplyResult
            do {
                settingsResult = try SettingsStore(paths: request.paths).apply(providerEnv: env)
            } catch {
                return fail("settings: \(Self.describe(error))")
            }

            let elapsed = Date().timeIntervalSince(started)
            emit(.done, target.id, "\(target.id) ready in \(Format.duration(elapsed))")
            return .success(SwitchSuccess(
                serverName: request.server.name,
                providerName: provider.name,
                model: finalRow,
                contextTokens: effectiveContext,
                backup: settingsResult.backupURL,
                elapsed: elapsed
            ))
        } catch is CancellationError {
            emit(.error, lastModel, "cancelled")
            return .cancelled(phase: lastPhase, model: lastModel)
        } catch let error as APIError {
            if Task.isCancelled { return .cancelled(phase: lastPhase, model: lastModel) }
            return fail("\(lastPhase.title.lowercased()): \(error.message)")
        } catch {
            if Task.isCancelled { return .cancelled(phase: lastPhase, model: lastModel) }
            return fail("\(lastPhase.title.lowercased()): \(Self.describe(error))")
        }
    }

    /// Unloads one model and waits until the server reports it free. Never
    /// touches settings or any file.
    public func unload(
        server: InferenceServer,
        modelID: String,
        options: SwitchOptions = SwitchOptions(),
        progress: @escaping (SwitchStep) -> Void
    ) async -> UnloadOutcome {
        let started = Date()
        var lastPhase: SwitchPhase = .resolving
        var lastModel: String? = modelID

        func emit(_ phase: SwitchPhase, _ model: String?, _ detail: String? = nil) {
            lastPhase = phase
            if let model { lastModel = model }
            progress(SwitchStep(phase: phase, model: model, detail: detail))
        }

        func fail(_ message: String) -> UnloadOutcome {
            emit(.error, lastModel, message)
            return .failed(message: message)
        }

        do {
            emit(.resolving, modelID, "checking current state")
            let models = try await server.api.fetchModels()
            guard let row = models.first(where: { $0.id == modelID }) else {
                return fail("unload: model '\(modelID)' not found on \(server.name)")
            }
            if !row.loaded && row.state != .loading {
                return .unloaded(
                    row, provider: server.name,
                    elapsed: Date().timeIntervalSince(started),
                    alreadyUnloaded: true
                )
            }

            emit(.unloading, modelID, "unloading")
            do {
                try await server.api.unload(modelID)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    emit(.error, modelID, "cancelled")
                    return .cancelled(phase: .unloading, model: modelID)
                }
                if !Self.isAlreadyUnloaded(error) {
                    return fail("unload: \(Self.describe(error))")
                }
            }

            emit(.waitingUnload, modelID, "waiting for unload")
            let verified = try await Self.waitForRow(
                api: server.api,
                id: modelID,
                timeout: options.unloadTimeout,
                poll: options.pollInterval
            ) { !$0.loaded && $0.state != .loading }
            emit(.waitingUnload, modelID, "unloaded")

            return .unloaded(
                verified, provider: server.name,
                elapsed: Date().timeIntervalSince(started),
                alreadyUnloaded: false
            )
        } catch is CancellationError {
            emit(.error, lastModel, "cancelled")
            return .cancelled(phase: lastPhase, model: lastModel)
        } catch let error as APIError {
            if Task.isCancelled { return .cancelled(phase: lastPhase, model: lastModel) }
            return fail("\(lastPhase.title.lowercased()): \(error.message)")
        } catch {
            if Task.isCancelled { return .cancelled(phase: lastPhase, model: lastModel) }
            return fail("\(lastPhase.title.lowercased()): \(Self.describe(error))")
        }
    }

    // MARK: Helpers

    static func resolve(models: [ServerModel], requested: String) throws -> ServerModel {
        if let exact = models.first(where: { $0.id == requested }) {
            return exact
        }
        let matches = models.filter { $0.id.lowercased().contains(requested.lowercased()) }
        if matches.count == 1 {
            return matches[0]
        }
        if matches.isEmpty {
            let available = models.map(\.id).sorted().joined(separator: ", ")
            throw APIError.server("model '\(requested)' not found; available: \(available)")
        }
        let names = matches.map(\.id).sorted().joined(separator: ", ")
        throw APIError.server("model '\(requested)' is ambiguous; matches: \(names)")
    }

    static func isAlreadyUnloaded(_ error: Error) -> Bool {
        let message = (error as? APIError)?.message ?? error.localizedDescription
        return message.lowercased().contains("not loaded")
    }

    static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.message }
        return error.localizedDescription
    }

    @MainActor
    static func waitForRow(
        api: any ModelServerAPI,
        id: String,
        timeout: Duration,
        poll: Duration,
        predicate: (ServerModel) -> Bool
    ) async throws -> ServerModel {
        let deadline = Date().addingTimeInterval(timeout.asSeconds)
        while true {
            try Task.checkCancellation()

            do {
                let models = try await api.fetchModels()
                if let row = models.first(where: { $0.id == id }) {
                    if row.state == .error {
                        throw APIError.server("\(id) entered the error state")
                    }
                    if predicate(row) {
                        return row
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error.isAuth {
                throw error
            } catch {
                // Transient read failures retry until the deadline, like modelswitch.
            }

            if Date() >= deadline {
                throw APIError.server("timed out after \(Format.duration(timeout.asSeconds)) waiting for \(id)")
            }
            try await Task.sleep(for: poll)
        }
    }
}

private extension Duration {
    var asSeconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
