# Implementation plans

Generated on 2026-08-13. Read the plan fully before starting and update its
milestone status table as work lands.

| Plan | Purpose | Status |
|---|---|---|
| [quagmire-0.1-foundation.md](quagmire-0.1-foundation.md) | Replace the Hunch-specific subpage API with one neutral document-link row, H1–H6, unsupported fallback, stable BlockID rules, a host boundary a remote backend can actually conform to, and a simultaneous Hunch migration | DONE — 2026-08-18; Milestone 7 unblocked |
| [editor-extraction-plan.md](editor-extraction-plan.md) | Stabilize the reusable editor, name and verify it locally, then extract, publish, and adopt it remotely | Milestones 0–6 DONE; Milestone 7 TODO |

Verification records:

- [editor-extraction-baseline.md](editor-extraction-baseline.md) — Milestones 0–2
- [editor-extraction-milestones-3-4.md](editor-extraction-milestones-3-4.md) — Milestones 3–4
- [editor-extraction-milestone-5.md](editor-extraction-milestone-5.md) — Milestone 5
- [editor-extraction-milestone-6.md](editor-extraction-milestone-6.md) — Milestone 6

Milestone 6 research:

- [editor-name-landscape.md](editor-name-landscape.md) — Quagmire decision
  record, existing editor names, naming patterns, and accepted collision
  tradeoffs

The Milestones 3–4 and Milestone 5 records include the 2026-08-15 stabilization
follow-up that cleared the previously recorded iOS reorder failures before
Milestone 5.

The milestones inside the editor extraction plan are ordered dependencies.
Before Milestone 7, execute `quagmire-0.1-foundation.md` completely so the first
published `0.1.0` already contains the neutral document-link and identity
boundary. That plan was revised on 2026-08-18 after auditing the code rather
than the docs: it now also splits the whole-document replacement seam (an
ID-preserving splice must not clear the undo stack), adds a `pending`
presentation state plus a warm hook so a network-backed host can implement the
synchronous lookup the row-gating architecture requires, makes mention
suggestions async, and runs as one commit per stage instead of one commit
total. The public name was chosen and verified locally in Milestone 6. Do
not create the standalone repository until the foundation plan is DONE and
Milestone 7 begins explicitly.
