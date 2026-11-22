import AppKit
import ModelSwitchCore
import SwiftUI

/// Edits the live provider/model/context Claude Code reads from settings.json.
/// This is the "only change model id and context window" path: the provider's
/// URL/key/timeout come from the provider record and never change here.
struct ClaudeSettingsSheet: View {
    @Environment(AppModel.self) private var model

    @State private var providerID: String = ""
    @State private var modelID: String = ""
    @State private var contextTokens: String = ""
    @State private var result: SettingsApplyResult?
    @State private var errorMessage: String?

    private var provider: ProviderConfiguration? {
        model.provider(id: providerID)
    }

    private var knownModelIDs: [String] {
        var ids = model.scannedModelIDs(providerID: providerID)
        for id in provider?.knownModelIDs ?? [] where !ids.contains(id) {
            ids.append(id)
        }
        if let active = model.activeSettings,
           model.provider(id: providerID)?.normalizedBaseURL == active.normalizedBaseURL,
           !active.model.isEmpty,
           !ids.contains(active.model) {
            ids.append(active.model)
        }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Settings").font(.title2.weight(.semibold))
            Text("Updates the env block of ~/.claude/settings.json. A backup is written first; restart Claude Code afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.providersList.isEmpty {
                Text("Add a provider in Manage Providers… first.")
                    .foregroundStyle(.orange)
            } else {
                Picker("Provider", selection: $providerID) {
                    ForEach(model.providersList) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .onChange(of: providerID) { _, _ in
                    applyProviderDefaults()
                }

                if let provider {
                    LabeledContent("Base URL", value: provider.normalizedBaseURL)
                        .font(.callout)
                    LabeledContent("API key", value: provider.maskedAPIKey)
                        .font(.callout)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model id").font(.caption).foregroundStyle(.secondary)
                            TextField("ANTHROPIC_MODEL", text: $modelID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        Menu {
                            ForEach(knownModelIDs, id: \.self) { id in
                                Button(id) {
                                    modelID = id
                                    contextTokens = provider.contextTokens(for: id)
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .help("Choose a scanned or manual model")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context window (tokens)").font(.caption).foregroundStyle(.secondary)
                        TextField(provider.normalizedDefaultContext, text: $contextTokens)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 240)
                    }

                    Text("Writes ANTHROPIC_MODEL, ANTHROPIC_SMALL_FAST_MODEL and CLAUDE_CODE_MAX_CONTEXT_TOKENS; base URL, key and timeout come from the provider.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    if let result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Saved settings. Backup: \(result.backupURL.lastPathComponent)")
                                .font(.callout)
                                .foregroundStyle(.green)
                            RestartReminder()
                        }
                    }

                    HStack {
                        Button("Copy reminder") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(model.restartReminder, forType: .string)
                        }
                        Spacer()
                        Button("Close") { model.dismissSheet() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save settings") { save() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if model.providersList.isEmpty {
                HStack {
                    Spacer()
                    Button("Close") { model.dismissSheet() }
                }
            }
        }
        .padding(22)
        .frame(width: 580)
        .onAppear {
            let initial = model.selectedProvider ?? model.activeProvider ?? model.providersList.first
            providerID = initial?.id ?? ""
            applyProviderDefaults()
        }
    }

    private func save() {
        do {
            result = try model.applyClaudeSettings(
                providerID: providerID,
                modelID: modelID,
                contextTokens: contextTokens
            )
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyProviderDefaults() {
        guard let provider else {
            modelID = ""
            contextTokens = ""
            return
        }

        let fallbackModel = model.selectedProvider?.id == provider.id
            ? model.selectedModel?.modelID
            : nil
        let modelCandidate = fallbackModel
            ?? (model.activeProvider?.id == provider.id ? model.activeSettings?.model : nil)
            ?? provider.knownModelIDs.first
            ?? ""

        modelID = modelCandidate
        contextTokens = modelCandidate.isEmpty ? provider.normalizedDefaultContext : provider.contextTokens(for: modelCandidate)
        result = nil
        errorMessage = nil
    }
}
