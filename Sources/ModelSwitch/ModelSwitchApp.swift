import AppKit
import SwiftUI

@main
struct ModelSwitchApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Model Switch", id: "main") {
            MainWindowView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1020, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Scan Models") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Claude Settings…") {
                    model.openClaudeSettings()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Manage Providers…") {
                    model.openProviders()
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .task { await model.start() }
        } label: {
            Label("Model Switch", systemImage: "arrow.left.arrow.right.circle")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Model Switch") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        if let active = model.activeSettings, !active.model.isEmpty {
            Text("Claude: \(model.activeProvider?.name ?? active.baseURL) · \(active.model.split(separator: "/").last ?? "")")
        }

        Divider()

        if model.servers.isEmpty {
            Text(model.refreshMessage ?? "No servers")
        } else {
            ForEach(model.servers) { server in
                Menu(server.name) {
                    let models = model.modelsByServer[server.id] ?? []
                    if models.isEmpty {
                        Text("No models")
                    } else {
                        ForEach(models) { item in
                            Button {
                                openWindow(id: "main")
                                NSApp.activate(ignoringOtherApps: true)
                                Task {
                                    await model.switchFromMenu(serverID: server.id, modelID: item.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: item.state.symbolName)
                                    Text(item.id)
                                    if item.manual { Text("(manual)") }
                                }
                            }
                            .disabled(model.switchRun != nil && !(model.switchRun?.isFinished ?? true))
                        }
                    }
                }
            }
        }

        Divider()
        Button("Manage Providers…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.openProviders()
        }
        Button("Claude Settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.openClaudeSettings()
        }
        Button("Refresh") {
            Task { await model.refreshAll() }
        }
        Divider()
        Button("Quit Model Switch") {
            NSApp.terminate(nil)
        }
    }
}
