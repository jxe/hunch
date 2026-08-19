# Editor name landscape

Researched and decided 2026-08-15 for Editor extraction Milestone 6. This is a
naming decision record and preliminary collision screening, not trademark
clearance.

## What is being named

A native SwiftUI block editor for iOS and macOS. It supplies an opinionated,
ready-to-embed editing experience over a nested block tree while leaving
storage, navigation, serialization, product actions, and visual identity with
the host.

The public identity needs to work in four places:

- a distinctive repository slug;
- one matching `UpperCamelCase` Swift package, product, and module;
- natural imports such as `import Brand`;
- search results where the name can be found without appending several
  disambiguating terms.

The name does not need to contain `Swift`, `block`, `text`, or `editor`. The
README, package metadata, and Swift Package Index keywords can carry category
description.

## Selected identity: Quagmire

- Repository slug: `quagmire`
- Swift package, library product, and module: `Quagmire`
- Consumer spelling: `import Quagmire`
- Public types remain role-based: `EditorView`, `Document`, `Block`,
  `EditorTheme`, and related names are not brand-prefixed.

Joe selected `Quagmire` after reviewing the first-pass landscape and its known
tradeoffs. The name deliberately favors memorability, humor, and an honest nod
to the notorious complexity of native rich-text editing over an unoccupied
coined brand.

The accepted tradeoffs are material and should remain visible:

- an active [Python package](https://pypi.org/project/quagmire/) already uses
  the name for a surface-process framework;
- the 2026-08-15 check found 83 GitHub repositories with `Quagmire` in the
  repository name, although no exact Swift Package Index, npm, or crates.io
  package was found;
- the ordinary word means a bog or difficult situation, and the dominant
  popular-culture association is the Family Guy character.

Those results do not create a known Swift module collision. They are accepted
brand/search tradeoffs, not facts that were missed during selection.

## Existing editor naming landscape

### Web and cross-platform editors

| Name | Positioning | Naming construction |
|---|---|---|
| [ProseMirror](https://prosemirror.net/) | Modular toolkit for structured rich-text editors | Evocative compound tied to prose and representation |
| [Tiptap](https://tiptap.dev/product/editor) | Extensible editor framework with optional UI | Short, playful coined word |
| [Lexical](https://lexical.dev/) | Lean, modular editor framework | Ordinary linguistic adjective used as a brand |
| [Slate](https://docs.slatejs.org/) | Customizable framework with a nested document model | Short writing-material metaphor |
| [Plate](https://platejs.org/docs) | React framework and UI built around Slate | Short material metaphor and ecosystem rhyme |
| [Remirror](https://www.remirror.io/docs/) | ProseMirror abstraction for React | Derived compound that signals its underlying ecosystem |
| [Milkdown](https://milkdown.dev/docs) | Plugin-driven WYSIWYG Markdown framework | Playful Markdown-derived coinage |
| [BlockNote](https://www.blocknotejs.org/docs) | Ready-to-use block-based React editor | Literal category compound |
| [Editor.js](https://editorjs.io/) | Block-style editor with JSON output | Maximally generic category plus platform suffix |
| [Gutenberg](https://github.com/WordPress/gutenberg) | WordPress block editor | Historical proper-name metaphor |

### Apple-platform editor libraries

| Name/module | Positioning | Naming construction |
|---|---|---|
| [Lexical iOS](https://github.com/facebook/lexical-ios) / `Lexical` | Swift/TextKit implementation of the Lexical philosophy | Cross-platform brand reuse |
| [Proton](https://github.com/rajdeep/proton) | Native extensible rich-text component | Short scientific metaphor |
| [RichTextKit](https://swiftpackageindex.com/danielsaidi/RichTextKit) | SwiftUI rich-text editing across Apple platforms | Literal category plus `Kit` |
| [AztecEditor](https://github.com/wordpress-mobile/AztecEditor-iOS) / `Aztec` | Native HTML editor used by WordPress | Standalone brand plus descriptive repository name |
| [MarkupEditor](https://github.com/stevengharris/MarkupEditor) | WYSIWYG editing for SwiftUI and UIKit | Literal category compound |
| [InfomaniakRichHTMLEditor](https://github.com/Infomaniak/swift-rich-html-editor) | HTML-backed WYSIWYG editor for Apple platforms | Vendor prefix plus exact category |
| [STTextView](https://github.com/krzyzanowskim/STTextView) | TextKit 2 `NSTextView`/`UITextView` replacement | Initials plus native component class |

## What the landscape suggests

1. **The generic namespace is crowded.** `Editor`, `BlockEditor`,
   `RichTextEditor`, and `RichTextKit`-like constructions are difficult to find
   and easy to confuse. `Lexical` is also already a Swift module, not only a web
   project.
2. **A metaphor or coinage is normal for serious editor infrastructure.**
   ProseMirror, Tiptap, Lexical, Slate, Proton, Milkdown, and Gutenberg do not
   need `Editor` in the import name.
3. **Literal compounds trade distinctiveness for immediate comprehension.**
   BlockNote communicates its category immediately but occupies obvious
   `Block*`/`*Note` territory. Generic Apple-library names do the same.
4. **The package is a productized component, not a broad toolkit.** A `Kit`
   suffix would undersell the coherent editing experience and imply a wider
   collection of independently adoptable utilities than the planned `0.1.0`
   exposes.
5. **The strongest semantic territory is structure plus writing.** The editor's
   unusual combination is a nested block tree, native interaction, and a
   host-neutral document boundary. A name can evoke assembling or structuring
   writing without promising Markdown storage, collaboration, or a general
   plugin platform.

## Alternatives considered

These checks covered exact or close results in GitHub repository names, Swift
Package Index search, npm, PyPI, crates.io, and general web/product results on
2026-08-15. Counts and availability can change and must be repeated before the
name is adopted.

| Candidate | Why it fits | Preliminary result | Concern |
|---|---|---|---|
| `ProseLoom` | Evokes assembling many typed strands into one structured document; sounds like a component rather than an app | No exact GitHub repository name or exact npm, PyPI, crates.io, or Swift Package Index result found | `Prose` is narrower than image and subpage blocks; `loom` is a familiar software metaphor |
| `ProseTree` | Directly describes the package's recursive document model | No exact GitHub repository name or exact npm, PyPI, crates.io, or Swift Package Index result found | More literal and less ownable-sounding; visually close to the established ProseMirror naming family |
| `ProseWeave` | Names the act of assembling structured writing and appears unoccupied in the checked developer registries | No exact GitHub repository name or exact npm, PyPI, crates.io, or Swift Package Index result found | Reads more like a feature or verb than a durable module noun |

`ProseLoom` was the strongest research-led alternative, but Quagmire was selected
instead.

## Attractive names rejected in the first pass

| Name | Reason not to advance |
|---|---|
| [`Tessera`](https://swiftpackageindex.com/SwiftedMind/Tessera) | Exact active Swift package/module, plus several current software products |
| [`Ashlar`](https://play.google.com/store/apps/details?id=com.munchyapps.ashlar) | Existing code editor and longstanding Ashlar-Vellum software brand |
| [`Quire`](https://quire.io/) | Established collaborative project-management and documents product |
| [`Asterism`](https://github.com/robb/Asterism) | Existing Objective-C library and many active repository uses |
| [`Manicule`](https://manicule.dev/) | Active developer-documentation company and existing manuscript software |
| [`TypeWell`](https://typewell.com/) | Longstanding transcription-software brand with a registered software trademark |
| [`Blockleaf`](https://dockets.justia.com/docket/nevada/nvdce/2%3A2023cv01703/165023) | Semantically appealing, but an active `Blockleaf LLC` and unrelated uses make it needlessly noisy |
| [`Linefold`](https://www.npmjs.com/package/linefold) | Exact active npm package for text line folding |
| [`Siglum`](https://github.com/SiglumProject/siglum) | Exact active LaTeX/WebAssembly project and other developer-tool uses |
