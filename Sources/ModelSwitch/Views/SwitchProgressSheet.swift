import AppKit
import ModelSwitchCore
import SwiftUI

struct SwitchProgressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let run = model.switchRun {
                content(run: run)
            } else {
                ProgressView()
            }
        }
        .frame(width: 560)
        .padding(22)
    }

    @ViewBuilder
    private func content(run: SwitchRun) -> some View {
        if let outcome = run.outcome {
            switch outcome {
            case .success(let success):
                successView(success, run: run)
            case .failed(let failure):
                failureView(failure, isUnload: run.kind == .unloadModel)
            case .cancelled(let phase, let modelName):
                cancelledView(phase: phase, modelName: modelName)
            }
        } else {
            runningView(run: run)
        }
    }

    private func runningView(run: SwitchRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.kind == .unloadModel ? "Unloading a model" : "Switching Claude to a new model")
                        .font(.title3.weight(.semibold))
                    Text(run.phase.title).font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(run.steps) { step in
                    StepRow(step: step)
                }
            }

            TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                Text("Elapsed: \(Format.duration(context.date.timeIntervalSince(run.startedAt)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Stop waiting") {
                    model.cancelSwitch()
                }
                .keyboardShortcut(.cancelAction)
                .help("Stops the UI. The server may keep loading the model.")
            }
        }
    }

    private func successView(_ success: SwitchSuccess, run: SwitchRun) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready").font(.title3.weight(.semibold))
                    Text(success.model.id)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            LabeledContent("Server", value: success.serverName)
            LabeledContent("Provider", value: success.providerName)
            LabeledContent("Context", value: "\(success.contextTokens) tokens")
            LabeledContent("Load time", value: Format.duration(success.elapsed))
            if let backup = success.backup {
                LabeledContent("Backup") {
                    Text(backup.lastPathComponent).font(.caption).monospaced()
                }
            }

            RestartReminder()

            HStack {
                Button("Copy reminder") {
                    copyToPasteboard(model.restartReminder)
                }
                Spacer()
                Button("Close") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failureView(_ failure: SwitchFailure, isUnload: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                Text(isUnload ? "Unload failed" : "Switch failed").font(.title3.weight(.semibold))
            }

            Text(failure.message)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if let backup = failure.backup {
                Text("Backup: \(backup.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Refresh") {
                    model.dismissSheet()
                    Task { await model.refreshAll() }
                }
                Spacer()
                Button("Close") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func cancelledView(phase: SwitchPhase, modelName: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stop.circle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Stopped waiting").font(.title3.weight(.semibold))
            }
            Text("Stopped during \"\(phase.title)\" while \(modelName ?? "working"). The server may still be loading the model; refresh to see its real state.")
                .font(.callout)
            HStack {
                Button("Refresh now") {
                    model.dismissSheet()
                    Task { await model.refreshAll() }
                }
                Spacer()
                Button("Close") {
                    model.dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct StepRow: View {
    let step: SwitchStepVM

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 16)
            Text(step.title)
                .font(.callout)
            Spacer()
            if let detail = step.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

struct RestartReminder: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
            Text(appModel.restartReminder)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
