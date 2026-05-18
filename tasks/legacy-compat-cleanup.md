# Legacy compat shims — audit & cleanup

## Context

The repo went through a rename: bundle id `com.joeedelman.console` →
`org.nxhx.Hunch`, display name "Console" → "Hunch". A few migration
shims and "console"-flavored identifiers still live in the codebase to
keep pre-rename installs from orphaning data. Time to audit each one,
confirm whether anything still depends on the legacy name, and either
delete or rename.

## The three known holdovers

### 1. `--console-ui-testing` and `--console-ui-testing-tall-doc` launch flags

- Read in [Workspace.tryRestore()](../App/Sources/Workspace.swift) at lines 146, 150.
- Set by the UITest targets (`HunchDragAndDropUITests.swift:247,254`,
  `HunchEditScrollUITests.swift:16`, `HunchSplitKeyboardUITests.swift:20`).
- Not a migration shim — actively used by test infra. The "console" name
  is just historical.
- **Likely action:** rename to `--hunch-ui-testing` + `--hunch-ui-testing-tall-doc`
  in both the app and the UITests. Single-commit rename, no compat shim
  needed (UITest fixtures aren't user-visible).

### 2. `console.workspace.bookmark` UserDefaults key

- Defined in [WorkspaceBookmark.swift](../App/Sources/Clamshell/WorkspaceBookmark.swift) line 7.
- Used in `save()` (line 28) and `resolve()` (line 35).
- This is a **real migration surface**: an existing user's bookmark to
  their chosen workspace folder lives under this key. Rename = orphan
  the bookmark, user re-picks the folder.
- **Investigate:** how many installs are on a pre-rename TestFlight or
  local build vs. a fresh post-rename install? If the affected
  population is small (or just yourself), rename + best-effort
  migration in `resolve()` (read old key once, write to new, delete
  old). If the population is meaningful, leave as-is.
- The same file also references
  `legacyHomePathDefaultsKey` (used by Clamshell.init for a one-time
  migration of the home-page pointer into `.clamshell.json`). Audit
  that too — if every workspace has been opened on a `Clamshell`-aware
  build, this is also removable.

### 3. `com.joeedelman.console.deviceID` UserDefaults key

- Defined in [DeviceID.swift](../App/Sources/Clamshell/DeviceID.swift) line 9.
- Names this device's recovery-log file
  (`.history/<rel>/<device-id>.jsonl`).
- **Behavioral question:** does the code read the old key on first
  launch and migrate to a new key, or does it just mint a new UUID on
  a fresh `org.nxhx.Hunch` install? If the latter, this *string* is
  dead-but-harmless — the per-install UUID is what matters, the key
  name is just where it's stored.
- **Likely action:** rename the key to `org.nxhx.Hunch.deviceID` with
  a one-shot migration: on first read, if `org.nxhx.Hunch.deviceID` is
  nil but the legacy key is set, copy across. Otherwise mint fresh.
  Once enough time has passed, drop the legacy read.

## How to verify before deleting any of these

For each candidate, run on a local install:

```sh
defaults read org.nxhx.Hunch 2>/dev/null
defaults read com.joeedelman.console 2>/dev/null
```

If both domains hold values, deleting either is destructive. The repo's
`scripts/clean-orphans.sh` purges legacy bundles and rebuilds
LaunchServices — useful when testing migration paths.

## Constraints

- Migration code, if added, runs once per install. Keep it small and
  inline; no separate migration framework.
- Don't bundle this with the EditorHost / Clamshell glue cleanup. That
  refactor is API-surface; this is identifier hygiene. Different
  reviewers, different risk profile.

## Test loop

- Existing build green on macOS + iOS (the rename touches launch args
  + UserDefaults; nothing structural).
- Reset a local Hunch install (`scripts/clean-orphans.sh`, delete
  `~/Library/Containers/org.nxhx.Hunch`), then verify first-launch
  picks up the bookmark / home-page pointer / deviceID from the legacy
  keys if present, and writes them under the new names.
- Run the UITest scheme after the launch-arg rename to confirm tests
  still find their fixtures.
