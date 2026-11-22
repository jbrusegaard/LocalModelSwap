import ModelSwitchCore
import SwiftUI

struct ModelTableView: View {
    @Environment(AppModel.self) private var model

    @State private var sortOrder = [
        KeyPathComparator(\ModelRow.serverName),
        KeyPathComparator(\ModelRow.model.id)
    ]

    var body: some View {
        @Bindable var model = model

        Table(model.visibleRows.sorted(using: sortOrder), selection: $model.selectedModel, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.model.id) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.model.state.symbolName)
                        .foregroundStyle(color(for: row.model.state))
                        .help(row.model.state.label)
                    Text(row.model.id)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .help(row.model.id)
                }
            }

            TableColumn("State", value: \.model.state.sortRank) { row in
                Text(row.model.state.label)
                    .foregroundStyle(row.model.state == .unloaded ? .secondary : .primary)
            }
            .width(80)

            TableColumn("Size", value: \.sizeForSort) { row in
                Text(Format.bytes(row.model.sizeBytes))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Context", value: \.contextForSort) { row in
                Text(Format.tokens(row.contextTokens))
                    .foregroundStyle(.secondary)
                    .help("CLAUDE_CODE_MAX_CONTEXT_TOKENS for this model")
            }
            .width(80)

            TableColumn("Source", value: \.sourceForSort) { row in
                Text(row.model.manual ? "manual" : "server")
                    .font(.caption)
                    .foregroundStyle(row.model.manual ? .orange : .secondary)
            }
            .width(70)

            TableColumn("Provider", value: \.serverName) { row in
                Text(row.serverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 140)
        }
        .tableStyle(.inset)
        .contextMenu {
            Button("Unload Model…") {
                model.requestUnload()
            }
            .disabled(!model.canUnloadSelected)
        }
        .overlay {
            if model.visibleRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(model.refreshMessage ?? "No models on this provider")
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func color(for state: ModelState) -> Color {
        switch state {
        case .ready: return .green
        case .loading: return .orange
        case .error: return .red
        case .unloaded, .unknown: return .secondary
        }
    }
}
