# Virtual Display Persistence & Editing Plan

## Goals

1. Persist virtual display **configurations** across app relaunch.
2. Allow users to **enable/disable** any saved configuration at will.
3. Make **Edit** work reliably (no “empty square” sheet) and allow editing whether a display is enabled or disabled.
4. Keep runtime state consistent with system reality (avoid “running” while no runtime display exists).

## Root Cause (Bug: Edit shows an empty square)

- The list UI is driven by stored configs (`displayConfigs`), but the Edit sheet currently renders **only if** it can also find a matching runtime `CGVirtualDisplay` in `displays`.
- When that lookup fails, the `.sheet` content becomes `EmptyView`, which macOS renders as a small blank square.
- This is a **state-model mismatch** (config truth vs runtime object truth), not a layout or timing-only issue.

## Architecture Changes

### 1) Single Source of Truth: Config First

- Treat `VirtualDisplayConfig` as the durable truth.
- Separate:
  - `desiredEnabled` (persisted): user intent (“enable this on launch / keep enabled”).
  - `runtimeEnabled` (derived): whether a runtime `CGVirtualDisplay` exists for that config in the current process.

### 2) Runtime Mapping

- Maintain a runtime map in `AppHelper`:
  - `activeDisplaysByConfigId: [UUID: CGVirtualDisplay]`
- Use this map for:
  - “Running/Disabled” badge
  - Enable/Disable actions
  - Optional live-apply when editing

### 3) Persistence Store

- Add a small store layer that reads/writes `[VirtualDisplayConfig]` to:
  - `Application Support/<bundle-id>/virtual-displays.json`
- Use atomic writes and a `schemaVersion` field for future migrations.

## UI/UX Changes

### 4) Virtual Display List

- The list shows all saved configs.
- “Running” is computed from the runtime map; “Disabled” otherwise.
- Enable/Disable toggles modify runtime + `desiredEnabled`.
- Edit is always available (enabled or disabled).

### 5) Edit Sheet (Always Shows Content)

- The sheet should be driven by a selected `configId` and always render an edit view.
- The edit view loads/updates the config from `AppHelper` by id.
- If the config is currently running:
  - Modes can be applied live (`display.apply(settings)`).
  - Fields that require re-creation (e.g. serial, physical size, possibly name) are handled as:
    - “Save only (apply on next enable)”
    - “Rebuild now” (disable + enable).

## Runtime Consistency

### 6) Handle System Termination

- `CGVirtualDisplayDescriptor.terminationHandler` should update runtime mapping:
  - Remove from `activeDisplaysByConfigId`
  - Refresh UI state

## Implementation Order

1. Add persistence store + load configs on launch.
2. Refactor `AppHelper` to manage runtime map and `desiredEnabled`.
3. Refactor `VirtualDisplayView` to:
   - Use config-driven sheet
   - Show runtime state derived from the runtime map
4. Add config-driven edit view that works for both enabled/disabled.
5. Add rebuild flow for changes requiring re-creation.

## Acceptance Criteria

- Creating configs persists across relaunch.
- Users can enable/disable saved configs.
- Edit never shows an empty sheet; it always opens.
- Editing disabled configs updates persisted config and affects next enable.
- Editing enabled configs:
  - Live-applies supported changes
  - Clearly prompts when rebuild is required

