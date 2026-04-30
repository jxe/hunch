# UI Testing Notes

## Gesture Work

Prefer making gesture decisions observable and testable before adding broad
simulator automation. For drag/reorder, the important seam is the pure
resolver: feed it stable frames and pointer paths, then assert the active
slot does not oscillate.

Use simulator/UI testing for integration checks that cannot be proven from
pure geometry:

- A long press starts reorder without entering edit mode.
- A horizontal swipe still wins before reorder begins.
- Pinch gestures still reach the page-level pinch handler.
- Dropping mutates order exactly once.
- Cancelling clears transient hover/source-row state.

## Accessibility Hooks

Rows expose readable labels such as `Paragraph: Alpha`. In deterministic UI
fixtures, rows also expose text-based identifiers such as `block-row-alpha`;
rows without text fall back to `block-row-<uuid>`. Drop slots expose
`block-drop-slot-<n>`.

Prefer deterministic fixture documents with short labels like `Alpha`,
`Bravo`, `Charlie`, and `Delta` so tests can assert visible order without
depending on generated UUIDs.

## Evidence Loop

When a gesture feels wrong but tests are green, capture a simulator video
or screenshot and reduce the issue to one of:

- resolver math
- gesture recognizer arbitration
- transient visual state
- structural mutation timing

Then add the smallest test at that layer before patching.

## Running XCUITests

The app accepts `--console-ui-testing` and boots directly into a deterministic
fixture document. This avoids the file picker and bookmark restore path.

Run focused iOS UI tests with:

```sh
xcodebuild -project Console.xcodeproj -scheme Console -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Use the generated row labels (`Paragraph: Bravo`, etc.) for interaction and
frame-order assertions.
