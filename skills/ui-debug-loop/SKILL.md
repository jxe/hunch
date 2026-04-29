---
name: ui-debug-loop
description: Use when a SwiftUI rendering, focus, or interaction problem isn't surfacing in builds or unit tests — clicks don't focus, edits don't propagate, key events get eaten, layout drifts, etc. Loop is: launch from terminal with stderr redirected → sprinkle print() in suspect paths → drive interactions via computer-use → tail /tmp/console.log → iterate. Only for actual UI runtime issues; don't use for logic bugs that show up in tests.
---

# UI runtime debug loop

## When this fires

A change to UI code (`Packages/UI/Sources/UI/*` or `App/Sources/*`) compiles
and passes Core tests, but the running app behaves wrong: clicks don't reach
the right view, focus doesn't transfer, key events vanish, layout doesn't
match the read-only render, autosave doesn't fire. Symptoms only visible
once you run the app and interact with it.

Don't reach for this if the failure shows up in `swift test
--package-path Packages/Core` — that's a logic bug, fix it without the GUI.

## Setup

You'll want three things going at once:

1. **The app, launched from a shell so stdout/stderr is visible.**
   ```sh
   pkill -f Console.app
   /Users/joe/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app/Contents/MacOS/Console > /tmp/console.log 2>&1 &
   ```
   The `&` backgrounds it; the redirect captures everything `print()` emits.
   GUI apps launched via `open` redirect stdio to `/dev/null`, so the binary
   path is required.

   Caveats:
   - `print()` from Swift can buffer when stdout isn't a tty. If lines don't
     show up in `/tmp/console.log`, replace `print(...)` with `NSLog(...)` or
     write to a `FileHandle` directly.
   - Running from terminal won't preserve dock activation behavior. Use
     `open_application` (computer-use) or `osascript -e 'tell application
     "Console" to activate'` to bring it forward.

2. **Computer-use access to the app.**
   ```
   request_access(["Console"], reason: "<what you're testing>")
   ```
   Then `open_application("Console")` to bring it forward. Fresh access is
   needed each session (the user can revoke via Esc — that stops a CU session
   but doesn't quit the app).

3. **A fixture loaded.** `./scripts/use-fixture.sh <name>` resets
   `/tmp/console-fixture/everything.md` to a known state and relaunches.
   `headings_and_bullets` is the broadest mix.

## Instrumenting

Sprinkle `print("[CLI] ...")` at the points where you suspect state isn't
propagating. Useful spots in this codebase:

- `BlockRow.textBinding.set` — does an edit reach the document?
- `PageView.onKeyPress` — is the page-level handler receiving the key?
- `MacBlockTextEditor.Coordinator.textDidChange` — is the NSTextView edit
  reaching the binding?
- `WorkspaceModel.markEdited` and `saveNow` — is autosave firing?
- `.onChange(of: editorFocused)` — is focus moving where you expect?

Use a stable prefix (`[CLI]`) so you can grep:
```sh
grep "\[CLI\]" /tmp/console.log
```

## The loop

1. **Form a hypothesis.** "Click on bullet doesn't enter edit mode" — possible
   causes: tap gesture not firing, `editingBlock` not setting, focus not
   transferring, editor not mounting.
2. **Add print() at each suspected step.** Tap handler, state setter, view
   conditional, focus binding.
3. **Rebuild + relaunch.**
4. **Drive the interaction via computer-use.** `left_click(coordinate)` then
   `type` or `key`.
5. **Read the log.** `tail -30 /tmp/console.log` (or `cat` if buffered).
6. **Cross-check with screenshots.** `screenshot()` then `zoom(region)` for
   small details.

The log + screenshot together pin down which step in the chain failed.

## Common gotchas in this codebase

- **`.onKeyPress` on a focused TextEditor on macOS is unreliable for keys
  the editor consumes** (Return, Tab, Backspace). The fix that works in this
  app is `MacBlockTextEditor`'s `keyDown(_:)` override on a custom NSTextView
  subclass — see `Packages/UI/Sources/UI/BlockTextEditor.swift`.
- **N TextEditors all live at once is fragile.** SwiftUI's hit testing and
  focus arbitration break down. Single-editor architecture (one editor
  mounted on the active block; everything else read-only `Text`) is much more
  predictable. See `editingBlock` / `selectedBlock` state in `PageView`.
- **`firstTextBaseline` alignment doesn't work out-of-the-box for
  `NSViewRepresentable`.** SwiftUI defaults to the view's top as the
  baseline, which puts a TextEditor visually below a sibling marker. The fix
  is an explicit `.alignmentGuide(.firstTextBaseline) { _ in nsFont.ascender }`.
- **GUI apps launched via `&` from a shell may detach stdio.** If
  `/tmp/console.log` stays empty, switch the prints to `NSLog` (visible via
  `log show --predicate 'process == "Console"' --last 2m`) or write to a
  `FileHandle` directly.
- **The user pressing `Esc` stops the active computer-use session.** Don't
  send `key text="Escape"` from CU itself if you can avoid it — drive Esc-
  exits-edit-mode tests manually or via the in-app key handler. Sending Esc
  through computer-use is fine for the app to receive, but the user pressing
  Esc on their keyboard halts CU entirely.

## When to stop

When the screenshot shows the right thing AND the log shows the right
sequence of state transitions. Either alone is not enough — you can have a
correct-looking screenshot from the wrong state path (e.g. a phantom
mutation that happened to land on the same visible result), or correct logs
with a layout bug that the log doesn't surface.

## Cleanup

Strip the `print("[CLI] ...")` calls before committing. They're not load-
bearing and clutter the source. `grep -n '\[CLI\]' Packages/UI App/Sources`
finds them.
