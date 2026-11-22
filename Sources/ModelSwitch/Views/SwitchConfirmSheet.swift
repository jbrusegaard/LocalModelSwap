import ModelSwitchCore
import SwiftUI

struct SwitchConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let data: SwitchConfirmData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Switch Claude to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(data.shortName)
                        .font(.title3.weight(.semibold))
                        .monospaced()
                }
            }

            HStack(spacing: 6) {
                Text(data.server.name).fontWeight(.medium)
                Text("·").foregroundStyle(.secondary)
                Text(data.server.hostLabel).foregroundStyle(.secondary)
            }
            .font(.caption)

            LabeledContent("Provider", value: data.providerName)
                .font(.callout)
            LabeledContent("Context", value: "\(data.contextTokens) tokens")
                .font(.callout)

            if !data.evictions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The following \(data.evictions.count) loaded model\(data.evictions.count == 1 ? "" : "s") will be unloaded first:")
                        .font(.callout)
                    ForEach(data.evictions) { eviction in
                        HStack(spacing: 6) {
                            Image(systemName: "minus.circle").foregroundStyle(.red)
                            Text(eviction.id)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .help(eviction.id)
                        }
                    }
                }
            } else {
                Text("No other loaded models need to be unloaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Then the model is loaded and verified, and ~/.claude/settings.json is rewritten (backup kept). providers.json is not touched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button("Switch") {
                    model.startSwitch(data)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

struct UnloadConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let data: UnloadConfirmData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unload from \(data.server.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(data.shortName)
                        .font(.title3.weight(.semibold))
                        .monospaced()
                    Text(data.modelID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospaced()
                        .lineLimit(1)
                        .help(data.modelID)
                }
            }
            Text(data.server.hostLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if data.isClaudeActive {
                Label(
                    "Claude Code is using this model. It will fail until you load another model.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Text("The model is unloaded and the app waits until the server reports it free. settings.json is not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.cancelAction)

                Button("Unload") {
                    model.startUnload(data)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
