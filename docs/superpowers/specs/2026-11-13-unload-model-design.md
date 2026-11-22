# Unload model — design (2026-11-13)

## Intent
A model pack can sit resident on one provider (e.g. sushi) while the user wants
to serve it from another (e.g. oMLX) on the same Mac Studio; the second provider
cannot load until the first frees the memory. This adds a standalone "Unload"
action for one selected loaded model, without touching Claude settings.

## Goals
- Unload one selected loaded model from its provider and verify it is actually
  unloaded (poll, ≤180 s).
- Always confirm first; warn when Claude Code's active model is the one being
  unloaded (same model id on the same provider).
- Reuse the engine's unload machinery: unload call, "model not loaded" tolerance,
  wait poll, Stop-waiting cancellation.
- Refresh the table and sidebar counts afterwards.

## Non-goals
- Unload never writes `~/.claude/settings.json` (or any file).
- No menu bar entry (for now).
- No automatic cross-provider move inside the switch flow (can build on this later).

## Anti-goals
- Never report success while the model is still resident or loading.

## Constraints
- Same server APIs, timeouts (unloadTimeout 180 s, poll 2 s; fixture mode shortened),
  cancellation semantics as the switch flow.
- Provider-only registry (`~/.model-switch.json`) unchanged; providers.json untouched.

## Approaches
1. **Standalone unload action on the selected row** (chosen): direct fulfillment of
   the request; reuses existing machinery; cheap.
2. Fire-and-forget unload (rejected): the user could never tell when the memory is
   actually free — the whole point is loading elsewhere right after.
3. Automatic cross-provider unload inside the switch flow (rejected for now): a
   bigger change to switch; the standalone action covers today's need.

## Decided parts
- Entry points: footer **Unload <model>** button (enabled only when the selected
  row is loaded) and a table-row context menu item.
- Confirm sheet always: provider/host, model, plus the Claude-active warning
  (active provider == this provider and active model == this model id). Cancel is
  the safe default.
- Progress: reuse the switch progress sheet; steps Resolve → Unload → Wait for
  unload; "Stop waiting" cancels; the server may finish anyway.
- Engine: `SwitchEngine.unload(server:modelID:options:progress:) async ->
  UnloadOutcome` on the existing `@MainActor` engine, reusing `waitForRow` and
  `isAlreadyUnloaded`. Fresh fetch first: missing id → failed "not found"; present
  but not loaded (and not loading) → success "already unloaded" with no unload
  call; present and loaded (or loading) → unload call (404/409/400 "not loaded"
  tolerated) → wait for `!loaded`. A model stuck loading may time out with an
  honest message.
- App model: single-flight on the existing switch task slot; on success the
  progress sheet closes itself and refreshes (no success view, no restart
  reminder).
- Tests: new engine tests (success + settings untouched, tolerated not-loaded,
  already-unloaded, not-found, wait timeout, cancellation, auth failure) and
  `FakeServerAPI` gains `unloadDelay`.

## Left to the builder
- Exact button/step/sheet wording; failure message prefix style (match the
  switch: `unload: …`, `unload wait: …`).
- Verify the Table context menu tracks the right-clicked row; if it does not,
  the footer button stays the source of truth and the confirm sheet still names
  the model.
