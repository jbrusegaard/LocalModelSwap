# Unload Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One standalone action that unloads a selected loaded model from its provider and waits until the server reports it free, without touching Claude settings.

**Architecture:** New `SwitchEngine.unload` on the existing `@MainActor` engine, reusing `waitForRow`/`isAlreadyUnloaded` and returning a dedicated `UnloadOutcome`. The app reuses the switch task slot, progress sheet, and confirm-sheet pattern; the progress sheet gains a kind-aware header and failure title; entry points are a footer button and a row context menu, both gated on a loaded selection.

**Tech Stack:** Swift 5.9, macOS 14, SwiftUI + ModelSwitchCore (Foundation only), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-unload-model-design.md`

## Global Constraints

- Unload never writes `~/.claude/settings.json` or any file (verbatim from spec).
- Same timing as switch: `unloadTimeout` 180 s, `pollInterval` 2 s; fixture mode poll 300 ms / unload 10 s.
- `~/.model-switch.json` and `~/.claude/providers.json` are untouched by unload.
- No third-party dependencies; macOS 14+; SwiftPM targets unchanged.
- No git repository exists in this working copy: omit commit steps; do not `git init`.
- Tests run as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (XCTest needs Xcode).

## Review Focus

1. Model already free when the action runs (race between the enabled row and the fresh fetch) — expect no unload call, immediate success, sheet closes. Pinned by `testUnloadAlreadyUnloadedMakesNoCalls` (Task 1).
2. Server answers an unload with wording other than "not loaded" — expect the failure surfaced with the server's message and no settings write. Pinned by `testUnloadWaitTimeoutFails` (Task 1) for the wait path; AdapterTests already pin the exact 409/400 shapes.
3. Unloading the model Claude Code is using — expect the confirm sheet to warn and settings.json to stay unchanged (Claude breaks until another model loads; documented, not fixed). Pinned by `testUnloadSuccessLeavesSettingsAlone` (Task 1) plus the warning condition in Task 2.
4. Cancel mid-wait — expect "Stop waiting" to end the wait while the server may finish anyway; the table reflects truth on refresh. Pinned by `testUnloadCancellationStopsWait` (Task 1).
5. The Table context menu may act on the selected row rather than the right-clicked row — expect the confirm sheet to always name the exact model id, so a mismatch is visible before harm. Guarded structurally in Task 2 (no automated test; the confirm sheet is the safety net).

---

### Task 1: Engine unload path

**Files:**
- Modify: `Sources/ModelSwitchCore/SwitchEngine.swift`
- Create: `Tests/ModelSwitchCoreTests/UnloadTests.swift`
- Modify: `Tests/ModelSwitchCoreTests/TestSupport.swift`

**Interfaces:**
- Consumes: `ModelServerAPI.fetchModels()/unload(_:)`, `SwitchEngine.waitForRow`, `SwitchEngine.isAlreadyUnloaded`, `SwitchEngine.describe`, `SwitchPhase`, `SwitchStep`.
- Produces: `public enum UnloadOutcome: Sendable` with cases `unloaded(ServerModel, provider: String, elapsed: TimeInterval, alreadyUnloaded: Bool)`, `cancelled(phase: SwitchPhase, model: String?)`, `failed(message: String)`; `@MainActor SwitchEngine.unload(server: InferenceServer, modelID: String, options: SwitchOptions = SwitchOptions(), progress: @escaping (SwitchStep) -> Void) async -> UnloadOutcome`; `FakeServerAPI.unloadDelay: Duration` (test support).

- [ ] **Step 1: Write the failing tests** — create `Tests/ModelSwitchCoreTests/UnloadTests.swift` with:

```swift
import Foundation
import XCTest
@testable import ModelSwitchCore

/// Probe for MockTransport handlers that flip server state mid-test.
final class UnloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

@MainActor
final class UnloadTests: XCTestCase {
    override func setUp() { super.setUp(); MockTransport.shared.reset() }
    override func tearDown() { MockTransport.shared.reset(); super.tearDown() }

    private let loadedA = ServerModel(id: "A", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)
    private let loadedB = ServerModel(id: "B", loaded: true, state: .ready, sizeBytes: 1, contextLength: 10_000)

    private func makeServer(api: any ModelServerAPI) -> InferenceServer {
        TestConfig.server(provider: TestConfig.provider(), api: api)
    }

    private func shortOptions() -> SwitchOptions {
        SwitchOptions(pollInterval: .milliseconds(20), unloadTimeout: .seconds(2))
    }

    func testUnloadSuccessLeavesSettingsAlone() async throws {
        let dir = try TempClaudeDir()
        defer { dir.remove() }
        try dir.writeSettings(TestConfig.settings(provider: TestConfig.provider(), model: "A"))
        let original = try String(contentsOf: dir.paths.settingsURL, encoding: .utf8)

        let api = FakeServerAPI(models: [loadedA, loadedB])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .unloaded(let model, let providerName, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertEqual(model.id, "A")
        XCTAssertEqual(providerName, "sushi")
        XCTAssertFalse(already)
        XCTAssertEqual(model.loaded, false)
        XCTAssertEqual(model.state, .unloaded)
        XCTAssertEqual(api.calls, ["unload A"])
        XCTAssertEqual(try String(contentsOf: dir.paths.settingsURL, encoding: .utf8), original)
    }

    func testUnloadToleratesNotLoadedAnswer() async throws {
        let probe = UnloadProbe()
        MockTransport.shared.set { request in
            if request.httpMethod == "POST" {
                probe.set()
                return (409, Data(#"{"error":"model not loaded"}"#.utf8))
            }
            let body = probe.isSet
                ? #"{"data":[{"id":"a","loaded":false,"state":"unloaded"}]}"#
                : #"{"data":[{"id":"a","loaded":true,"state":"ready"}]}"#
            return (200, Data(body.utf8))
        }
        let api = SushiAPI(client: HTTPClient(
            base: "http://test:12345", token: "secret", session: MockTransport.shared.session
        ))
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "a", options: shortOptions()
        ) { _ in }

        guard case .unloaded(_, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertFalse(already)
    }

    func testUnloadAlreadyUnloadedMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [ServerModel(id: "A", loaded: false, state: .unloaded)])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .unloaded(_, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertTrue(already)
        XCTAssertEqual(api.calls, [])
    }

    func testUnloadNotFoundMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [loadedB])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("not found"))
        XCTAssertEqual(api.calls, [])
    }

    func testUnloadWaitTimeoutFails() async throws {
        MockTransport.shared.set { request in
            if request.httpMethod == "POST" {
                return (200, Data(#"{"status":"unloading"}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"a","loaded":true,"state":"ready"}]}"#.utf8))
        }
        let api = SushiAPI(client: HTTPClient(
            base: "http://test:12345", token: "secret", session: MockTransport.shared.session
        ))
        let options = SwitchOptions(pollInterval: .milliseconds(20), unloadTimeout: .milliseconds(150))
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "a", options: options
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("timed out"))
        XCTAssertTrue(message.contains("wait for unload"))
    }

    func testUnloadOfLoadingModelStillAttemptsUnload() async throws {
        let api = FakeServerAPI(models: [ServerModel(id: "C", loaded: false, state: .loading)])
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "C", options: shortOptions()
        ) { _ in }

        guard case .unloaded(let model, _, _, let already) = outcome else {
            return XCTFail("expected unloaded, got \(outcome)")
        }
        XCTAssertFalse(already)
        XCTAssertEqual(model.state, .unloaded)
        XCTAssertEqual(api.calls, ["unload C"])
    }

    func testUnloadCancellationStopsWait() async throws {
        let api = FakeServerAPI(models: [loadedA])
        api.unloadDelay = .seconds(5)

        let engine = SwitchEngine()
        let task = Task { @MainActor in
            await engine.unload(
                server: makeServer(api: api), modelID: "A", options: shortOptions()
            ) { _ in }
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let outcome = await task.value

        guard case .cancelled(let phase, let model) = outcome else {
            return XCTFail("expected cancelled, got \(outcome)")
        }
        XCTAssertEqual(phase, .unloading)
        XCTAssertEqual(model, "A")
    }

    func testUnloadAuthFailureMakesNoCalls() async throws {
        let api = FakeServerAPI(models: [loadedA])
        api.authOnFetch = true
        let outcome = await SwitchEngine().unload(
            server: makeServer(api: api), modelID: "A", options: shortOptions()
        ) { _ in }

        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Authentication") || message.contains("401"))
        XCTAssertEqual(api.calls, [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UnloadTests`
Expected: build FAILS — `UnloadOutcome` and `unload` are unresolved.

- [ ] **Step 3: Add `unloadDelay` to `FakeServerAPI`** in `Tests/ModelSwitchCoreTests/TestSupport.swift` — after `var loadDelay: Duration = .zero` add `var unloadDelay: Duration = .zero`; in `unload(_ id:)` insert between the error check and the storage mutation:

```swift
        if unloadDelay > .zero {
            try await Task.sleep(for: unloadDelay)
        }
```

- [ ] **Step 4: Implement `UnloadOutcome` and `unload`** in `Sources/ModelSwitchCore/SwitchEngine.swift` — `UnloadOutcome` exactly as listed in Interfaces, placed next to `SwitchOutcome`; the method inside the `@MainActor` engine, reusing the existing helpers. The wait predicate excludes `.loading` so a mid-load model can never be reported free:

```swift
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
        // The three outer catches are the same shape as SwitchEngine.run's:
        // CancellationError -> .cancelled(phase: lastPhase, model: lastModel),
        // APIError / any error -> fail("\(lastPhase.title.lowercased()): …").
    }
```

- [ ] **Step 5: Run to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UnloadTests`
Expected: 8 tests PASS.

- [ ] **Step 6: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 51 tests, 0 failures.

---

### Task 2: App wiring — confirm, progress, footer, context menu

**Files:**
- Modify: `Sources/ModelSwitch/AppModel.swift`
- Modify: `Sources/ModelSwitch/Views/MainWindowView.swift`
- Modify: `Sources/ModelSwitch/Views/ModelTableView.swift`
- Modify: `Sources/ModelSwitch/Views/SwitchConfirmSheet.swift`
- Modify: `Sources/ModelSwitch/Views/SwitchProgressSheet.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `SwitchEngine.unload(server:modelID:options:progress:) -> UnloadOutcome` (Task 1), existing `SwitchRun`, `AppModel.apply(step:to:)`, `dismissSheet()`, `refreshAll()`, `activeProvider`, `activeSettings`.
- Produces: `struct UnloadConfirmData: Identifiable, Sendable`; `AppSheet.unloadConfirm(UnloadConfirmData)`; `enum RunKind: Sendable { case switchModel, unloadModel }` with `SwitchRun.kind: RunKind` (default `.switchModel`); `AppModel.canUnloadSelected: Bool`; `AppModel.requestUnload()`; `AppModel.startUnload(_ data: UnloadConfirmData)`; `UnloadConfirmSheet`; footer Unload button; table context menu item.

- [ ] **Step 1: AppModel additions** in `Sources/ModelSwitch/AppModel.swift`:

Next to `SwitchConfirmData`:

```swift
struct UnloadConfirmData: Identifiable, Sendable {
    let id = UUID()
    let server: InferenceServer
    let modelID: String
    let isClaudeActive: Bool

    var shortName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }
}
```

`AppSheet` gains the case and id (`"unload-confirm-\(data.id.uuidString)"`):

```swift
    case unloadConfirm(UnloadConfirmData)
```

Next to `SwitchRun` (the kind rides the existing run; no second VM):

```swift
enum RunKind: Sendable {
    case switchModel
    case unloadModel
}
```

```swift
final class SwitchRun {
    var kind: RunKind = .switchModel
    // existing fields unchanged
```

AppModel methods (place near the switch section):

```swift
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
```

- [ ] **Step 2: View changes**

`MainWindowView.swift` sheet switch gains:

```swift
                case .unloadConfirm(let data):
                    UnloadConfirmSheet(data: data)
```

`SwitchConfirmSheet.swift` gains the unload confirm sheet (same file, below `SwitchConfirmSheet`):

```swift
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
```

`MainWindowView.swift` `FooterBar` gains the Unload button between the keep-others toggle and the Switch button:

```swift
            Button {
                model.requestUnload()
            } label: {
                Label("Unload \(model.selectedRow?.model.shortName ?? "…")", systemImage: "minus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canUnloadSelected)
```

`ModelTableView.swift` gains a context menu after `.tableStyle(.inset)`:

```swift
        .contextMenu {
            Button("Unload Model…") {
                model.requestUnload()
            }
            .disabled(!model.canUnloadSelected)
        }
```

`SwitchProgressSheet.swift` — the header and failure title follow the run kind:

```swift
                Text(run.kind == .unloadModel ? "Unloading a model" : "Switching Claude to a new model")
                    .font(.title3.weight(.semibold))
```

```swift
            case .failed(let failure):
                failureView(failure, isUnload: run.kind == .unloadModel)
```

```swift
    private func failureView(_ failure: SwitchFailure, isUnload: Bool) -> some View {
        // body unchanged except the heading:
        Text(isUnload ? "Unload failed" : "Switch failed").font(.title3.weight(.semibold))
```

- [ ] **Step 3: README** — after the main-flow bullet add:

```markdown
- A standalone **Unload** button frees one loaded model from its provider, so a
  pack can be reloaded from a different provider on the same machine. It always
  confirms first and never writes settings.json.
```

and in Behavior notes, before the "No `modelswitch`/`cps` subprocess" line:

```markdown
- Unload tolerates "not loaded" answers and waits until the server reports the
  model free (≤180 s by default).
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: PASS, no warnings.

- [ ] **Step 5: Rebuild the bundle and smoke**

Run: `./build-app.sh` then `open "build/Model Switch.app" --args --fixture`; confirm the fixture instance is alive via `pgrep -fl "MacOS/ModelSwitch"`; stop it and relaunch `open "build/Model Switch.app"`. UI interaction itself is verified by the end-of-branch review (screenshots are not reliably available in this harness).

- [ ] **Step 6: Final full-suite check**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 51 tests, 0 failures.
