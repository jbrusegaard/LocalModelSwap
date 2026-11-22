import ModelSwitchCore
import SwiftUI

struct ProviderSheet: View {
    @Environment(AppModel.self) private var model

    @State private var selectedID: String?
    @State private var draft: ProviderConfiguration?
    @State private var revealKey = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDelete = false
    @State private var newModelID = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Providers").font(.headline)
                Spacer()
                Button("Done") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                providerList
                    .frame(width: 230)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 900, height: 560)
        .onAppear {
            if selectedID == nil, let active = model.activeProvider?.id ?? model.providersList.first?.id {
                selectedID = active
                draft = model.provider(id: active)
            }
        }
        .onChange(of: selectedID) { _, id in
            revealKey = false
            if let id {
                draft = model.provider(id: id)
            } else if isNewDraft == false {
                draft = nil
            }
        }
        .alert("Delete provider \"\(draft?.name ?? "")\"?", isPresented: $pendingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteDraft() }
        } message: {
            if let activeBase = model.activeSettings?.normalizedBaseURL,
               let draft,
               model.provider(id: draft.id)?.normalizedBaseURL == activeBase {
                Text("Claude settings currently use this provider. They keep the old URL/key until you write new settings.")
            } else {
                Text("The provider and its manual model annotations are removed from ~/.model-switch.json. settings.json is not changed.")
            }
        }
    }

    private var isNewDraft: Bool {
        guard let draft else { return false }
        return model.provider(id: draft.id) == nil
    }

    /// User clicks go through this binding so a new selection clears the last
    /// save/delete message; programmatic assigns (right after a save) do not.
    private var listSelection: Binding<String?> {
        Binding(
            get: { selectedID },
            set: { newValue in
                statusMessage = nil
                errorMessage = nil
                selectedID = newValue
            }
        )
    }

    // MARK: Left column

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Providers").font(.headline)
                Spacer()
                Button {
                    selectedID = nil
                    draft = ProviderConfiguration(
                        name: "New Provider",
                        baseURL: "",
                        apiKey: "",
                        timeoutMs: "600000",
                        defaultContextTokens: "262144"
                    )
                    statusMessage = nil
                    errorMessage = nil
                    revealKey = false
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add provider")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: listSelection) {
                ForEach(model.providersList) { provider in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(provider.hostLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("\(provider.manualModels.count) manual model\(provider.manualModels.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if model.activeProvider?.id == provider.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help("provider used by Claude settings")
                        }
                    }
                    .tag(provider.id)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Right column

    @ViewBuilder
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let draft {
                    editorContent(draft: draft)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Select a provider on the left, or add one with ＋.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                        if let statusMessage {
                            Text(statusMessage).font(.caption).foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 40)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func editorContent(draft: ProviderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.name.isEmpty ? "New Provider" : draft.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                if isNewDraft {
                    Text("not yet saved").font(.caption).foregroundStyle(.orange)
                } else if model.activeProvider?.id == draft.id {
                    Text("used by Claude").font(.caption).foregroundStyle(.green)
                }
            }

            field("Name") {
                TextField("Provider name", text: stringBinding(\.name))
            }

            field("Base URL") {
                TextField("http://172.29.69.69:12345", text: stringBinding(\.baseURL))
            }

            field("API key") {
                HStack(spacing: 8) {
                    if revealKey {
                        TextField("API key", text: stringBinding(\.apiKey))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API key", text: stringBinding(\.apiKey))
                            .font(.system(.body, design: .monospaced))
                    }
                    Button(revealKey ? "Hide" : "Reveal") { revealKey.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Text("Stored plaintext in ~/.model-switch.json (mode 0600).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                field("Default timeout (ms)") {
                    TextField("600000", text: stringBinding(\.timeoutMs))
                }
                field("Default context tokens") {
                    TextField("262144", text: stringBinding(\.defaultContextTokens))
                }
            }

            Divider()

            HStack {
                Text("Models").font(.headline)
                Spacer()
                Text("scanned + manual").font(.caption).foregroundStyle(.secondary)
            }

            modelList(draft: draft)

            HStack(spacing: 8) {
                TextField("Add a model id (beamster/…)", text: $newModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Add") { addManualModel() }
                    .disabled(newModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let problem = draft.validationProblem(existingProviders: model.config?.providers ?? []) {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.green)
            }

            Divider()

            HStack {
                if !isNewDraft {
                    Button("Delete", role: .destructive) {
                        pendingDelete = true
                    }
                }
                Spacer()
                Button("Save") {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.validationProblem(existingProviders: model.config?.providers ?? []) != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func modelIDs(for draft: ProviderConfiguration) -> [String] {
        var ids = model.scannedModelIDs(providerID: draft.id)
        for id in draft.manualModels where !ids.contains(id) { ids.append(id) }
        for id in draft.modelOverrides.keys.sorted() where !ids.contains(id) { ids.append(id) }
        return ids
    }

    @ViewBuilder
    private func modelList(draft: ProviderConfiguration) -> some View {
        let scanned = model.scannedModelIDs(providerID: draft.id)
        let ids = modelIDs(for: draft)

        VStack(alignment: .leading, spacing: 6) {
            if ids.isEmpty {
                Text("No models yet. Scan the server or add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(id)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .help(id)
                        Text(scanned.contains(id) ? "server" : "manual")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(draft.defaultContextTokens, text: overrideBinding(for: id))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .font(.system(.caption, design: .monospaced))
                            .help("Context tokens written to settings.json for this model (blank = provider default)")
                        if draft.manualModels.contains(id) && !scanned.contains(id) {
                            Button {
                                removeManualModel(id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove manual model")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<ProviderConfiguration, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var current = draft else { return }
                current[keyPath: keyPath] = newValue
                draft = current
            }
        )
    }

    private func overrideBinding(for modelID: String) -> Binding<String> {
        Binding(
            get: { draft?.modelOverrides[modelID] ?? "" },
            set: { newValue in
                guard var current = draft else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    current.modelOverrides.removeValue(forKey: modelID)
                } else {
                    current.modelOverrides[modelID] = trimmed
                }
                draft = current
            }
        )
    }

    private func addManualModel() {
        guard var current = draft else { return }
        let id = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !current.manualModels.contains(id) && !model.scannedModelIDs(providerID: current.id).contains(id) {
            current.manualModels.append(id)
        }
        draft = current
        newModelID = ""
    }

    private func removeManualModel(_ id: String) {
        guard var current = draft else { return }
        current.manualModels.removeAll { $0 == id }
        current.modelOverrides.removeValue(forKey: id)
        draft = current
    }

    private func saveDraft() {
        guard let draft else { return }
        do {
            statusMessage = try model.saveProvider(draft) ?? "Saved."
            errorMessage = nil
            selectedID = draft.id
            if let saved = model.provider(id: draft.id) {
                self.draft = saved
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func deleteDraft() {
        guard let draft, !isNewDraft else { return }
        do {
            try model.deleteProvider(id: draft.id)
            selectedID = nil
            self.draft = nil
            statusMessage = "Removed \(draft.name)."
            errorMessage = nil
            revealKey = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
