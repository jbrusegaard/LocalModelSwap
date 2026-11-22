import ModelSwitchCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            ServerSidebarView()
        } detail: {
            VStack(spacing: 0) {
                HeaderBar()
                WarningBanners()
                ModelTableView()
                Divider()
                FooterBar()
            }
            .frame(minWidth: 620, minHeight: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedServerID) { _, _ in
            model.pruneSelection()
        }
        .onChange(of: model.query) { _, _ in
            model.pruneSelection()
        }
        .sheet(item: $model.sheet) { item in
            Group {
                switch item {
                case .confirm(let data):
                    SwitchConfirmSheet(data: data)
                case .unloadConfirm(let data):
                    UnloadConfirmSheet(data: data)
                case .progress:
                    SwitchProgressSheet()
                case .providers:
                    ProviderSheet()
                case .claudeSettings:
                    ClaudeSettingsSheet()
                }
            }
            .environment(model)
        }
    }
}

// MARK: - Sidebar

struct ServerSidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: sidebarSelection) {
            Label("All Providers", systemImage: "square.stack.3d.up")
                .tag(SidebarSelection.all)

            ForEach(model.servers) { server in
                ProviderRow(
                    server: server,
                    health: model.healthByServer[server.provider.id],
                    models: model.modelsByServer[server.provider.id] ?? [],
                    error: model.errorsByServer[server.provider.id],
                    isClaudeActive: model.activeProvider?.id == server.provider.id
                )
                .tag(SidebarSelection.server(server.provider.id))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Claude settings").font(.caption).foregroundStyle(.secondary)
                if let active = model.activeSettings, !active.baseURL.isEmpty || !active.model.isEmpty {
                    Text(activeProviderLabel(active))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("not recognized").font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button("Manage Providers…") {
                        model.openProviders()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    Button("Claude Settings…") {
                        model.openClaudeSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 240, maxWidth: 300)
    }

    private func activeProviderLabel(_ active: ClaudeSettingsSnapshot) -> String {
        let provider = model.activeProvider
        let modelName = active.model.split(separator: "/").last.map(String.init) ?? active.model
        if let provider {
            return "\(provider.name) · \(modelName) · \(Format.tokens(active.contextTokens))"
        }
        return "\(active.baseURL) · \(modelName)"
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { model.selectedServerID.map(SidebarSelection.server) ?? .all },
            set: { selection in
                switch selection {
                case .server(let id): model.selectedServerID = id
                case .all, .none: model.selectedServerID = nil
                }
            }
        )
    }
}

private enum SidebarSelection: Hashable {
    case all
    case server(String)
}

private struct ProviderRow: View {
    let server: InferenceServer
    let health: ServerHealth?
    let models: [ServerModel]
    let error: String?
    let isClaudeActive: Bool

    private var loadedCount: Int {
        models.filter(\.loaded).count
    }

    private var loadedLabel: String {
        guard !models.isEmpty else { return "no models scanned" }
        return "\(loadedCount)/\(models.count) loaded"
    }

    private var dotColor: Color {
        if error != nil { return .red }
        if health?.up == true { return .green }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.weight(.medium))
                    if server.kind != .unknown && server.name.lowercased() != server.kind.rawValue {
                        Text(server.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isClaudeActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("provider used by Claude settings")
                    }
                }
                Text(server.hostLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(loadedLabel)
                    .font(.caption2)
                    .foregroundStyle(loadedCount > 0 ? .secondary : Color.secondary.opacity(0.7))
                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search models", text: $model.query)
                .textFieldStyle(.plain)
                .frame(width: 220)

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("Scan models", systemImage: "arrow.clockwise")
            }
            .help("Re-scan models from every provider and refresh health")
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Banners

private struct WarningBanners: View {
    @Environment(AppModel.self) private var model

    private var serverErrors: [(String, String)] {
        model.errorsByServer.compactMap { id, error in
            guard !error.isEmpty else { return nil }
            let name = model.servers.first(where: { $0.provider.id == id })?.name ?? id
            return (name, error)
        }
    }

    private var unrecognizedSettings: String? {
        guard let active = model.activeSettings,
              !active.baseURL.isEmpty,
              model.activeProvider == nil else { return nil }
        return "Claude settings use \(active.baseURL), which is not one of your providers."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = model.refreshMessage {
                Banner(message: message, color: .red)
            }
            if let settingsError = model.settingsError {
                Banner(message: "settings.json: \(settingsError)", color: .red)
            }
            if let message = unrecognizedSettings {
                Banner(message: message, color: .orange)
            }
            if !model.localOverrideKeys.isEmpty {
                Banner(
                    message: "settings.local.json overrides provider keys: \(model.localOverrideKeys.joined(separator: ", "))",
                    color: .orange
                )
            }
            ForEach(Array(serverErrors.enumerated()), id: \.offset) { _, item in
                Banner(message: "\(item.0): \(item.1)", color: .orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

struct Banner: View {
    let message: String
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 12) {
            if let row = model.selectedRow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "server").font(.caption).foregroundStyle(.secondary)
                        Text(row.serverName).font(.caption).fontWeight(.medium)
                        if row.model.manual {
                            Text("manual").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text("Context: \(Format.tokens(row.contextTokens)) tokens · provider: \(model.selectedProvider?.name ?? "—")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select a model").font(.caption).foregroundStyle(.secondary)
                    Text("Scanned or manually added models appear here.").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Claude Settings…") {
                model.openClaudeSettings()
            }
            .font(.caption)

            Toggle("Keep other models loaded", isOn: $model.keepOthers)
                .toggleStyle(.checkbox)
                .font(.caption)

            Button {
                model.requestUnload()
            } label: {
                Label("Unload \(model.selectedRow?.model.shortName ?? "…")", systemImage: "minus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canUnloadSelected)

            Button {
                model.requestSwitch()
            } label: {
                Text("Switch Claude to \(model.selectedRow?.model.shortName ?? "…")")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedRow == nil || model.isRefreshing || model.servers.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
