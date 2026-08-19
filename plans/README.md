# Implementation plans

The root of this directory contains active executor plans. Completed-stage
evidence and research live in [`records/`](records/README.md) so an executor
does not mistake history for queued work.

| Active plan | Purpose | Status |
|---|---|---|
| [editor-extraction-plan.md](editor-extraction-plan.md) | Extract, publish, and adopt Quagmire after the completed local editor/Hunch foundation | Milestones 0–6 and the pre-publication foundation DONE; Milestone 7 TODO |

The pre-publication foundation completed on 2026-08-18, with review follow-ups
through Hunch commit `ef37cc6`. Quagmire now has one neutral `documentLink`
row, H1–H6 representation, an unsupported/raw fallback, specified stable block
identity, observation-backed target presentation, safe system replacement, and
synchronous commit admission plus async flush. Hunch migrated with it and the
failure-ordering and observation contracts are covered by tests. Its completed
executor file was removed after this outcome was folded into the Milestone 7
precondition in the active extraction plan.

The next authorized work is Milestone 7: extract Quagmire in a disposable
clone, publish the verified package as `0.1.0`, and switch Hunch to the exact
remote version only after clean remote resolution and resource verification.
