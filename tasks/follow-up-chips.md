# Follow-Up Chips

Spawn these when they would otherwise bloat an active change.

## Round-Corner Inline Code Chip Rendering

Replace flat `.backgroundColor` with a custom `TextRenderer` that paints a
3pt rounded background per run.

## Shared Text-View Coordinator Base

`MacBlockTextEditor.Coordinator` and `IOSBlockTextEditorView.Coordinator`
have parallel structure: delegate text-change, autotransform check, undo
registration, binding push, and focus-boundary handling.

Extract a tiny base or protocol only if a third platform-specific text
view appears. Two parallel files are still readable.

