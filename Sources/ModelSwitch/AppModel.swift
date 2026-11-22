import AppKit
import Foundation
import ModelSwitchCore
import Observation

// MARK: - Sheet payloads

struct SwitchConfirmData: Identifiable, Sendable {
    let id = UUID()
    let server: InferenceServer
    let modelID: String
    let providerName: String
    let contextTokens: String
    let evictions: [ServerModel]
    let keepOthers: Bool

    var shortName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }
}

struct UnloadConfirmData: Identifiable, Sendable {
    let id = UUID()
    let server: InferenceServer
    let modelID: String
    let isClaudeActive: Bool

    var shortName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }
}

enum AppSheet: Identifiable {
    case confirm(SwitchConfirmData)
    case unloadConfirm(UnloadConfirmData)
    case progress
    case providers
    case claudeSettings

    var id: String {
        switch self {
        case .confirm(let data): return "confirm-\(data.id.uuidString)"
        case .unloadConfirm(let data): return "unload-confirm-\(data.id.uuidString)"
        case .progress: return "progress"
        case .providers: return "providers"
        case .claudeSettings: return "claude-settings"
        }
    }
}

// MARK: - Switch progress

enum StepState: Sendable {
    case running
    case done
    case failed
}

@MainActor @Observable
final class SwitchStepVM: Identifiable {
    let id = UUID()
    let phase: SwitchPhase
    let model: String?
    var detail: String?
    var state: StepState

    init(phase: SwitchPhase, model: String?, detail: String?, state: StepState) {
        self.phase = phase
        self.model = model
        self.detail = detail
        self.state = state
    }

    var title: String {
        phase.title + (model.map { ": \($0.split(separator: "/").last ?? "")" } ?? "")
    }
}

enum RunKind: Sendable {
    case switchModel
    case unloadModel
}

@MainActor @Observable
final class SwitchRun {
    var kind: RunKind = .switchModel
    var steps: [SwitchStepVM] = []
    var phase: SwitchPhase = .resolving
    var startedAt = Date()
    var outcome: SwitchOutcome?
    var isFinished = false
}

// MARK: - App state

@MainActor
private struct ProviderRefresh: Sendable {
    let serverID: String
    let models: [ServerModel]
    let health: ServerHealth?
    let error: String?
}

@MainActor @Observable
final class AppModel {
    let fixtureMode: Bool
    var paths: AppPaths

    var config: ModelSwitchConfig?
    var servers: [InferenceServer] = []
    var modelsByServer: [String: [ServerModel]] = [:]
    var healthByServer: [String: ServerHealth] = [:]
    var errorsByServer: [String: String] = [:]

    /// The provider/model/env Claude Code will read at startup.
    var activeSettings: ClaudeSettingsSnapshot?
    var settingsError: String?
    var localOverrideKeys: [String] = []

    var selectedServerID: String?
    var selectedModel: ModelRef?
    var query: String = ""
    var keepOthers: Bool = false
    var isRefreshing = false
    var refreshMessage: String?

    var sheet: AppSheet?
    var switchRun: SwitchRun?

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didAutoSelect = false
    @ObservationIgnored private var kindCache: [String: ServerKind] = [:]
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var switchTask: Task<Void, Never>?

    init() {
        fixtureMode = CommandLine.arguments.contains("--fixture")
            || ProcessInfo.processInfo.environment["MODELSWITCH_FIXTURE"] == "1"

        if fixtureMode {
            do {
                paths = try Fixtures.prepare()
            } catch {
                // Fixture mode must never fall back onto the real home directory.
                let fallback = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ModelSwitch-Fixture-\(UUID().uuidString)", isDirectory: true)
                paths = AppPaths(
                    claudeDir: fallback.appendingPathComponent(".claude", isDirectory: true),
                    appConfigURL: fallback.appendingPathComponent("model-switch.json")
                )
                refreshMessage = "Fixture setup failed: \(error.localizedDescription)"
            }
        } else {
            paths = AppPaths.default()
        }
    }

    // MARK: Start & refresh

    func start() async {
        guard !didStart else { return }
        didStart = true
        await refreshAll()
        startAutoRefresh()
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        refreshGeneration += 1
        let generation = refreshGeneration

        do {
            let loadedConfig = try await loadOrImportConfig()
            guard generation == refreshGeneration else { return }
            config = loadedConfig

            let settingsStore = SettingsStore(paths: paths)
            do {
                let settings = try settingsStore.load()
                activeSettings = ClaudeSettingsSnapshot.from(settings: settings)
                settingsError = nil
            } catch {
                activeSettings = nil
                settingsError = error.localizedDescription
            }
            localOverrideKeys = settingsStore.localEnvKeys().filter { ClaudeEnv.knownKeys.contains($0) }

            let discovered: [InferenceServer]
            if fixtureMode {
                discovered = Fixtures.makeServers(config: loadedConfig)
            } else {
                let result = await ServerDiscovery.servers(from: loadedConfig, cachedKinds: kindCache)
                discovered = result.servers
                kindCache = result.kinds
            }
            guard generation == refreshGeneration else { return }
            servers = discovered

            var results: [ProviderRefresh] = []
            await withTaskGroup(of: ProviderRefresh.self) { group in
                for server in discovered {
                    group.addTask {
                        var models: [ServerModel] = []
                        var health: ServerHealth?
                        var message: String?
                        do {
                            models = try await server.api.fetchModels()
                        } catch {
                            message = (error as? APIError)?.message ?? error.localizedDescription
                        }
                        do {
                            health = try await server.api.health()
                        } catch {
                            if message == nil {
                                message = (error as? APIError)?.message ?? error.localizedDescription
                            }
                        }
                        return ProviderRefresh(
                            serverID: server.provider.id,
                            models: models,
                            health: health,
                            error: message
                        )
                    }
                }
                for await result in group {
                    results.append(result)
                }
            }

            guard generation == refreshGeneration else { return }

            var models: [String: [ServerModel]] = [:]
            var health: [String: ServerHealth] = [:]
            var errors: [String: String] = [:]
            for result in results {
                guard let server = discovered.first(where: { $0.provider.id == result.serverID }) else { continue }
                models[result.serverID] = mergedModels(
                    scanned: result.models,
                    provider: server.provider,
                    active: activeSettings
                )
                health[result.serverID] = result.health
                errors[result.serverID] = result.error
            }
            modelsByServer = models
            healthByServer = health
            errorsByServer = errors

            if loadedConfig.providers.isEmpty {
                refreshMessage = "No providers yet. Open Manage Providers… to add one."
            } else {
                refreshMessage = nil
            }

            if !didAutoSelect,
               selectedModel == nil,
               let active = activeSettings,
               !active.model.isEmpty,
               let provider = providersList.first(where: {
                   $0.normalizedBaseURL == active.normalizedBaseURL
               }) {
                didAutoSelect = true
                selectedServerID = provider.id
                selectedModel = ModelRef(serverID: provider.id, modelID: active.model)
            }
            pruneSelection()
        } catch {
            guard generation == refreshGeneration else { return }
            servers = []
            modelsByServer = [:]
            healthByServer = [:]
            errorsByServer = [:]
            if case FileFailure.notFound = error {
                refreshMessage = "No ~/.model-switch.json and no providers.json to import. Add a provider."
            } else {
                refreshMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// First launch imports cps's providers.json once, then this app owns its
    /// own registry. providers.json is never written by Model Switch.
    private func loadOrImportConfig() async throws -> ModelSwitchConfig {
        if FileManager.default.fileExists(atPath: paths.appConfigURL.path) {
            var config = try ModelSwitchConfig.load(from: paths.appConfigURL)
            config.path = paths.appConfigURL
            return config
        }

        let imported = (try? ProvidersJSONImporter.read(from: paths.providersURL)) ?? []
        var providers: [ProviderConfiguration] = []
        var usedNames = Set<String>()
        var newKinds: [String: ServerKind] = [:]

        for entry in imported {
            let kind = await ServerDiscovery.detectKind(
                base: entry.baseURL,
                token: entry.apiKey,
                timeout: 3
            )
            let name = uniqueImportName(kind: kind, baseURL: entry.baseURL, used: &usedNames)
            let id = UUID().uuidString
            if kind != .unknown { newKinds[id] = kind }

            var manualModels: [String] = []
            var overrides: [String: String] = [:]
            for model in entry.models {
                manualModels.append(model.id)
                if let context = model.contextTokens, !context.isEmpty {
                    overrides[model.id] = context
                }
            }

            providers.append(ProviderConfiguration(
                id: id,
                name: name,
                baseURL: entry.baseURL,
                apiKey: entry.apiKey,
                timeoutMs: entry.timeoutMs,
                defaultContextTokens: entry.defaultContextTokens,
                manualModels: manualModels,
                modelOverrides: overrides
            ))
        }

        kindCache.merge(newKinds) { _, new in new }
        let config = ModelSwitchConfig(
            version: 1,
            providers: providers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            },
            path: paths.appConfigURL
        )
        try config.save()
        return config
    }

    private func uniqueImportName(
        kind: ServerKind,
        baseURL: String,
        used: inout Set<String>
    ) -> String {
        var name: String
        if kind != .unknown && !used.contains(kind.rawValue) {
            name = kind.rawValue
        } else {
            name = baseURL
            if let url = URL(string: baseURL) {
                let host = url.host ?? baseURL
                name = url.port.map { "\(host):\($0)" } ?? host
            }
            if used.contains(name) {
                var suffix = 2
                while used.contains("\(name)-\(suffix)") { suffix += 1 }
                name = "\(name)-\(suffix)"
            }
        }
        used.insert(name)
        return name
    }

    private func mergedModels(
        scanned: [ServerModel],
        provider: ProviderConfiguration,
        active: ClaudeSettingsSnapshot?
    ) -> [ServerModel] {
        var rows = scanned
        var seen = Set(rows.map(\.id))

        for id in provider.manualModels where !seen.contains(id) {
            rows.append(ServerModel(id: id, loaded: false, state: .unknown, manual: true))
            seen.insert(id)
        }
        for id in provider.modelOverrides.keys.sorted() where !seen.contains(id) {
            rows.append(ServerModel(id: id, loaded: false, state: .unknown, manual: true))
            seen.insert(id)
        }
        if let active,
           active.normalizedBaseURL == provider.normalizedBaseURL,
           !active.model.isEmpty,
           !seen.contains(active.model) {
            rows.append(ServerModel(id: active.model, loaded: false, state: .unknown, manual: true))
        }
        return rows
    }

    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if self.switchRun != nil { continue }
                if self.sheet != nil { continue }
                await self.refreshAll()
            }
        }
    }

    // MARK: Selection and plans

    var providersList: [ProviderConfiguration] {
        config?.sortedProviders ?? []
    }

    var activeProvider: ProviderConfiguration? {
        guard let activeSettings else { return nil }
        return SettingsMapping.provider(
            forBaseURL: activeSettings.baseURL,
            in: providersList
        )
    }

    var visibleRows: [ModelRow] {
        var rows: [ModelRow] = []
        for server in servers {
            if let selectedServerID, server.provider.id != selectedServerID { continue }
            for model in modelsByServer[server.provider.id] ?? [] {
                if !query.isEmpty {
                    let needle = query.lowercased()
                    if !model.id.lowercased().contains(needle)
                        && !server.name.lowercased().contains(needle) {
                        continue
                    }
                }
                rows.append(ModelRow(
                    serverID: server.provider.id,
                    serverName: server.name,
                    model: model,
                    contextTokens: server.provider.contextTokens(for: model.id)
                ))
            }
        }
        return rows
    }

    var selectedRow: ModelRow? {
        guard let selectedModel else { return nil }
        return visibleRows.first { $0.id == selectedModel }
    }

    var selectedProvider: ProviderConfiguration? {
        guard let selectedModel, let config else { return nil }
        return config.provider(id: selectedModel.serverID)
    }

    var selectedServer: InferenceServer? {
        guard let selectedModel else { return nil }
        return servers.first { $0.provider.id == selectedModel.serverID }
    }

    func evictionsForSelection() -> [ServerModel] {
        guard !keepOthers, let row = selectedRow else { return [] }
        return (modelsByServer[row.serverID] ?? []).filter {
            $0.loaded && $0.id != row.modelID
        }
    }

    func pruneSelection() {
        guard let selectedModel else { return }
        let provider = config?.provider(id: selectedModel.serverID)
        let models = modelsByServer[selectedModel.serverID] ?? []
        let stillExists = provider != nil && models.contains { $0.id == selectedModel.modelID }
        if !stillExists {
            self.selectedModel = nil
        }
        if let selectedServerID, !servers.contains(where: { $0.provider.id == selectedServerID }) {
            self.selectedServerID = nil
        }
    }

    // MARK: Switch

    func requestSwitch() {
        guard let row = selectedRow,
              let server = servers.first(where: { $0.provider.id == row.serverID }) else { return }

        let provider = server.provider
        let data = SwitchConfirmData(
            server: server,
            modelID: row.model.id,
            providerName: provider.name,
            contextTokens: provider.contextTokens(for: row.model.id),
            evictions: evictionsForSelection(),
            keepOthers: keepOthers
        )

        if data.evictions.isEmpty {
            startSwitch(data)
        } else {
            sheet = .confirm(data)
        }
    }

    func switchFromMenu(serverID: String, modelID: String) async {
        if config == nil { await refreshAll() }
        guard let server = servers.first(where: { $0.provider.id == serverID }) else { return }

        selectedServerID = server.provider.id
        selectedModel = ModelRef(serverID: server.provider.id, modelID: modelID)

        let evictions = keepOthers
            ? []
            : (modelsByServer[server.provider.id] ?? []).filter { $0.loaded && $0.id != modelID }
        let data = SwitchConfirmData(
            server: server,
            modelID: modelID,
            providerName: server.provider.name,
            contextTokens: server.provider.contextTokens(for: modelID),
            evictions: evictions,
            keepOthers: keepOthers
        )

        if evictions.isEmpty {
            startSwitch(data)
        } else {
            sheet = .confirm(data)
        }
    }

    func startSwitch(_ data: SwitchConfirmData) {
        switchTask?.cancel()
        sheet = .progress

        let run = SwitchRun()
        run.startedAt = Date()
        switchRun = run

        let options = SwitchOptions(
            keepOthers: data.keepOthers,
            pollInterval: fixtureMode ? .milliseconds(300) : .seconds(2),
            unloadTimeout: fixtureMode ? .seconds(10) : .seconds(180),
            loadTimeout: fixtureMode ? .seconds(20) : .seconds(1800),
            verifyTimeout: fixtureMode ? .seconds(30) : .seconds(1800)
        )
        let request = SwitchRequest(
            server: data.server,
            modelID: data.modelID,
            options: options,
            paths: paths,
            contextTokens: data.contextTokens
        )

        switchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await SwitchEngine().run(request) { step in
                self.apply(step, to: run)
            }
            run.outcome = outcome
            run.isFinished = true

            if let success = outcome.success {
                self.selectedModel = ModelRef(serverID: data.server.provider.id, modelID: success.model.id)
            }
            if !Task.isCancelled {
                await self.refreshAll()
            }
        }
    }

    func apply(_ step: SwitchStep, to run: SwitchRun) {
        switch step.phase {
        case .done:
            if let last = run.steps.last, last.state == .running {
                last.state = .done
                if let detail = step.detail { last.detail = detail }
            }
            run.phase = .done
            return
        case .error:
            if let last = run.steps.last, last.state == .running {
                last.state = .failed
                if let detail = step.detail { last.detail = detail }
            }
            run.phase = .error
            return
        default:
            if let last = run.steps.last, last.state == .running {
                last.state = .done
            }
            run.phase = step.phase
            run.steps.append(SwitchStepVM(
                phase: step.phase,
                model: step.model,
                detail: step.detail,
                state: .running
            ))
        }
    }

    func cancelSwitch() {
        switchTask?.cancel()
    }

    func dismissSheet() {
        sheet = nil
        switchRun = nil
    }

    // MARK: Unload

    var canUnloadSelected: Bool {
        guard let row = selectedRow, row.model.loaded, !isRefreshing else { return false }
        if let run = switchRun, !run.isFinished { return false }
        return true
    }

    func requestUnload() {
        guard canUnloadSelected,
              let row = selectedRow,
              let server = servers.first(where: { $0.provider.id == row.serverID }) else { return }
        sheet = .unloadConfirm(UnloadConfirmData(
            server: server,
            modelID: row.model.id,
            isClaudeActive: activeProvider?.id == server.provider.id
                && activeSettings?.model == row.model.id
        ))
    }

    func startUnload(_ data: UnloadConfirmData) {
        switchTask?.cancel()
        sheet = .progress

        let run = SwitchRun()
        run.kind = .unloadModel
        run.startedAt = Date()
        switchRun = run

        let options = SwitchOptions(
            pollInterval: fixtureMode ? .milliseconds(300) : .seconds(2),
            unloadTimeout: fixtureMode ? .seconds(10) : .seconds(180)
        )

        switchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await SwitchEngine().unload(
                server: data.server,
                modelID: data.modelID,
                options: options
            ) { step in
                self.apply(step, to: run)
            }
            switch outcome {
            case .unloaded:
                // No success view on purpose: the sheet closes and the table refreshes.
                run.isFinished = true
                dismissSheet()
                if !Task.isCancelled {
                    await refreshAll()
                }
            case .cancelled(let phase, let model):
                run.outcome = .cancelled(phase: phase, model: model)
                run.isFinished = true
            case .failed(let message):
                run.outcome = .failed(SwitchFailure(message: message, backup: nil))
                run.isFinished = true
            }
        }
    }

    // MARK: Provider registry

    func openProviders() {
        sheet = .providers
    }

    func openClaudeSettings() {
        sheet = .claudeSettings
    }

    func provider(id: String) -> ProviderConfiguration? {
        config?.provider(id: id)
    }

    func scannedModelIDs(providerID: String) -> [String] {
        (modelsByServer[providerID] ?? []).filter { !$0.manual }.map(\.id)
    }

    /// Save one provider (new or edited) and, when it is the provider Claude is
    /// currently using, rewrite settings.json so the key/URL applies immediately.
    func saveProvider(_ provider: ProviderConfiguration) throws -> String? {
        guard var config = config else {
            throw APIError.server("Model Switch config is not loaded")
        }
        guard let problem = provider.validationProblem(existingProviders: config.providers) else {
            let oldProvider = config.provider(id: provider.id)
            let activeBase = activeSettings?.normalizedBaseURL
            let wasActive = activeBase != nil && oldProvider?.normalizedBaseURL == activeBase
            config.upsert(provider)
            try config.save()
            self.config = config
            kindCache.removeValue(forKey: provider.id)

            var status: String?
            if wasActive, let active = activeSettings, !active.model.isEmpty {
                let env = SettingsMapping.environment(
                    provider: provider,
                    model: active.model,
                    contextTokens: provider.contextTokens(for: active.model),
                    smallModel: active.smallModel
                )
                do {
                    _ = try SettingsStore(paths: paths).apply(providerEnv: env)
                    activeSettings = SettingsStore(paths: paths).snapshot()
                    status = "Provider saved. Claude settings updated; restart Claude Code."
                } catch {
                    throw APIError.server("Provider saved, but settings.json failed: \(error.localizedDescription)")
                }
            } else {
                status = "Provider saved."
            }

            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
            return status
        }
        throw APIError.server(problem)
    }

    func deleteProvider(id: String) throws {
        guard var config = config else {
            throw APIError.server("Model Switch config is not loaded")
        }
        guard config.provider(id: id) != nil else { return }
        config.remove(id: id)
        try config.save()
        self.config = config
        kindCache.removeValue(forKey: id)
        if selectedServerID == id {
            selectedServerID = nil
            selectedModel = nil
        }
        Task { @MainActor [weak self] in
            await self?.refreshAll()
        }
    }

    // MARK: Claude settings direct edit

    func applyClaudeSettings(
        providerID: String,
        modelID: String,
        contextTokens: String
    ) throws -> SettingsApplyResult {
        guard var config = config,
              var provider = config.provider(id: providerID) else {
            throw APIError.server("Provider not found")
        }

        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw APIError.server("Model id is required") }

        let context = contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty && context.contains(where: { !$0.isNumber }) {
            throw APIError.server("Context window must be a number")
        }

        let env = SettingsMapping.environment(
            provider: provider,
            model: model,
            contextTokens: context.isEmpty ? nil : context
        )
        let result = try SettingsStore(paths: paths).apply(providerEnv: env)

        if context.isEmpty {
            provider.modelOverrides.removeValue(forKey: model)
        } else {
            provider.modelOverrides[model] = context
        }
        let alreadyListed = (modelsByServer[providerID] ?? []).contains { $0.id == model }
        if !alreadyListed && !provider.manualModels.contains(model) {
            provider.manualModels.append(model)
        }
        config.upsert(provider)
        try config.save()
        self.config = config
        activeSettings = SettingsStore(paths: paths).snapshot()

        Task { @MainActor [weak self] in
            await self?.refreshAll()
        }
        return result
    }

    var restartReminder: String {
        "Restart Claude Code (or open a new session) to apply."
    }
}
