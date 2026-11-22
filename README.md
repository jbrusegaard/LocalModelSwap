# LocalModelSwap

**LocalModelSwap** (the app builds and runs as **Model Switch**) is one macOS
app for the whole loop: pick a model on your local inference server, load it,
unload the ones that were in the way, and write the result into Claude Code's
settings — then restart Claude Code on the new model.

It targets self-hosted model servers on your LAN — **sushi** and **oMLX** are
supported natively, auto-detected by their endpoints — and is the successor to
juggling `cps`, `curl` and hand-edited JSON every time you want to swap models.

## Features

- **Providers are providers.** A provider is a name, base URL, API key, default
  timeout and default context window. Models are not baked into providers — the
  same server can serve any number of models.
- **Models are scanned or added manually.** Model lists come live from the
  server's `/v1/models` (sushi) or `/v1/models/status` (oMLX); anything the
  server doesn't list can be added by hand. Each model can carry its own
  context-window override.
- **Server kind is auto-detected.** LocalModelSwap probes the endpoints and
  picks the sushi or oMLX adapter for you — no "provider type" dropdown.
- **The switch flow is safe.** Pick a model → other loaded models are unloaded
  one at a time → the pick is loaded and verified → `~/.claude/settings.json`
  is rewritten atomically (with a timestamped backup) → Claude Code restarts on
  the new model. settings.json is *only* written after the load is verified.
- **Standalone Unload.** Free one loaded model from its provider without
  touching Claude Code — e.g. to reload the same pack from a different
  provider on the same machine. Always confirms first.
- **Claude Settings sheet.** Change just the model id, context window or
  timeout in settings.json directly, without loading anything.
- **Respects other tools' files.** Claude Code owns `~/.claude/settings.json`
  — only the six provider env keys are managed, everything else is preserved.
  `~/.claude/providers.json` (the cps registry) is read **once** on first
  launch to import providers and is never written. Unknown keys in
  `settings.local.json` that would shadow the switch are shown as a warning and
  never modified.
- **Keys stay private.** API tokens are masked in the UI and never logged.

## Requirements

| | |
|---|---|
| macOS | 14 (Sonoma) or later |
| Build | Xcode Command Line Tools (Swift 6) — `xcode-select --install` |
| Tests | A full Xcode install (used only by `make test`, for XCTest) |
| Server | A reachable sushi (`:12345`) or oMLX (`:4200`) instance, or any provider you point it at |

## Setup

### 1. Clone

```bash
git clone https://github.com/jbrusegaard/LocalModelSwap.git
cd LocalModelSwap
```

### 2. Build and run

```bash
make app          # release build -> "build/Model Switch.app"
open "build/Model Switch.app"
```

`make app` compiles with `swift build -c release`, assembles a proper `.app`
bundle (icon, `Info.plist` with `NSAllowsLocalNetworking` so plain-HTTP LAN
servers work), strips Finder metadata and ad-hoc codesigns it.

### 3. Install (optional)

```bash
make install      # copies to ~/Applications (override: make install PREFIX=/Applications)
```

The app lives in `~/Applications` by default so it shows up in Launchpad and
Spotlight alongside store apps without needing admin rights.

### 4. First launch

- **If you already use `cps`:** with `~/.claude/providers.json` present, all
  providers are imported on first launch — grouped by base URL, keeping the
  first non-empty token, timeout and context-window annotations as per-model
  overrides. The file is then never touched again.
- **Otherwise:** use *Add Provider* and enter the server's name, base URL
  (e.g. `http://192.168.1.50:12345`) and API key. Press *Scan* (or *Refresh*)
  to pull the model list, or add model ids manually.

### 5. Point Claude Code at it (one-time, automatic)

Nothing to configure in Claude Code — the switch flow writes the provider's
env block into `~/.claude/settings.json` for you:

```
ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL,
ANTHROPIC_SMALL_FAST_MODEL, API_TIMEOUT_MS,
CLAUDE_CODE_MAX_CONTEXT_TOKENS
```

## Using it

1. Select a provider and a model in the table (loaded models are marked).
2. Press **Switch**. Confirm — the sheet shows exactly which models will be
   unloaded and what will be written to settings.json.
3. Watch progress: unload → load → verify → write settings → relaunch Claude
   Code.
4. Use **Unload** alone when you just want to evict a model to make room, and
   the **Claude Settings** button when you want a surgical edit to
   settings.json without any server calls.

Unloads wait until the server reports the model actually free (up to 180 s by
default), so sequential switches don't race the server's memory reclamation.

## Files this app owns (and doesn't)

| File | Owner | Purpose |
|---|---|---|
| `~/.model-switch.json` | LocalModelSwap | providers, keys, manual models, per-model context overrides |
| `~/.claude/settings.json` | Claude Code | `env` block rewritten after a verified load; backups in `~/.claude/backups` (last 20), written atomically preserving file mode |
| `~/.claude/providers.json` | cps | read-only import source on first launch, never written |

### Config schema (`~/.model-switch.json`)

```json
{
  "version": 1,
  "providers": [
    {
      "id": "uuid",
      "name": "sushi",
      "baseURL": "http://192.168.1.50:12345",
      "apiKey": "...",
      "timeoutMs": "600000",
      "defaultContextTokens": "262144",
      "manualModels": ["beamster/GLM-5.3-Flash-Sushi-2.4bpw"],
      "modelOverrides": {
        "beamster/DeepSeek-V4.1-Flash-1017-Sushi-STQ-1.75bpw": "962000"
      }
    }
  ]
}
```

- Effective context for a model = `modelOverrides[model]` ?? `defaultContextTokens`.
- One provider per base URL; the editor validates name/URL uniqueness and
  numeric timeout/context values.
- oMLX model ids containing `/` are percent-escaped as a single path segment.

## Development

```bash
make build         # debug compile (swift build)
make test          # unit tests (mock HTTP servers + temp dirs; needs Xcode for XCTest)
make run           # run unbundled from swift
make run-fixture   # run against canned fixture providers/servers
make fixture       # build the .app and open it in fixture mode
make icon          # re-render Resources/AppIcon.icns from tools/make-icon.swift
make clean
```

**Fixture mode** (`--fixture`) swaps in an in-memory provider registry and fake
servers, so you can exercise the full UI — switching, unloading, error paths —
without touching `~/.claude` or `~/.model-switch.json`. It's the fastest way to
contribute without owning a Mac Studio full of quantized MoEs.

### Project layout

```
Sources/ModelSwitchCore/   # everything testable: config, adapters, switch engine
Sources/ModelSwitch/       # SwiftUI/AppKit app: window, sheets, table
Tests/ModelSwitchCoreTests # mock-HTTP unit tests
tools/make-icon.swift      # procedural app-icon renderer
docs/                      # design notes and plans
```

The core has no UI dependencies — adapters (`SushiAPI`, `OMLXAPI`), discovery,
atomic file writing and settings mapping are all plain Swift, exercised by
`swift test`.

## Troubleshooting

- **`make test` fails to link XCTest** — you have Command Line Tools but not
  full Xcode. Install Xcode, or set `XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and retry.
- **App refuses to open (Gatekeeper)** — the bundle is ad-hoc signed for local
  use. If you move the `.app` between machines, rebuild with `make app` on the
  target machine, or right-click → Open the first time.
- **Provider shows "unreachable"** — plain-HTTP LAN URLs need the
  `NSAllowsLocalNetworking` ATS exception, which `build-app.sh` puts in the
  bundle. Running via `swift run` (no bundle) still works against HTTP hosts,
  but named *public* HTTPS hosts keep normal ATS behavior.
- **"Overridden by settings.local.json" warning** — a key
  `~/.claude/settings.local.json` sets one of the six managed env keys; Claude
  Code will prefer that file. LocalModelSwap shows it and never writes it.

## No subprocess magic

Everything is done in-process over HTTP and file I/O — no `modelswitch`/`cps`
binary needs to be installed.

## License

[MIT](LICENSE) — do whatever you want with it, just keep the copyright notice.
