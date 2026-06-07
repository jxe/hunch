import SwiftUI
import Editor

/// Move-to picker. Shows two grouped sections:
/// - "On this page" — `InDocMoveTarget`s the editor walked out of the
///   current document (headings + toggles, already filtered to legal drop
///   targets). Indented by depth so the page outline is visible. Capped at
///   `inDocCollapsedLimit` rows with a "Show more" reveal so the page list
///   below stays reachable on tall documents.
/// - "Pages" — every other workspace page (workspace's own search rank).
///
/// One search field filters both pools. Typing updates the highlighted row
/// in real time (the cursor jumps to the top match on every query change),
/// so Return commits the best match without taking the keyboard out of the
/// search field. Arrow keys move the cursor across both groups (in-doc
/// first, in document order, then pages).
///
/// Mounted by `ContentView` over the move-request sheet binding. The general
/// `SearchSheet` and `PagePickerView` stay untouched and are still used by
/// the navigation/search surface.
struct MoveDestinationSheet: View {
    let workspace: Workspace
    let inDocCandidates: [InDocMoveTarget]
    let excluding: URL?
    let onActivate: (MoveDestination) -> Void
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var cursor: CursorID?
    @State private var inDocExpanded: Bool = false

    /// One-of cursor across both groups so arrow keys traverse the whole
    /// list seamlessly. Hashable so `List(selection:)` can use it directly.
    enum CursorID: Hashable {
        case block(BlockID)
        case page(String)
    }

    /// Soft-cap for the "On this page" section before showing a "Show more"
    /// reveal. Picked so the Pages section stays visible on first paint for
    /// pages with up to a few-dozen sections.
    private static let inDocCollapsedLimit = 5

    private var filteredInDoc: [InDocMoveTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return inDocCandidates }
        return inDocCandidates.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var displayedInDoc: [InDocMoveTarget] {
        if inDocExpanded { return filteredInDoc }
        return Array(filteredInDoc.prefix(Self.inDocCollapsedLimit))
    }

    private var hiddenInDocCount: Int {
        max(0, filteredInDoc.count - displayedInDoc.count)
    }

    private var pages: [MentionItem] {
        workspace.clamshell?.pages(
            matching: query,
            excluding: excluding,
            filter: .locallyAvailableForWrite
        ) ?? []
    }

    /// Cursor traversal order (excludes the "Show more" disclosure row — that
    /// is a control, not a destination).
    private var orderedCursorIDs: [CursorID] {
        displayedInDoc.map { .block($0.id) } + pages.map { .page($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $cursor) {
                if !displayedInDoc.isEmpty {
                    Section("On this page") {
                        ForEach(displayedInDoc) { target in
                            InDocMoveTargetRow(
                                target: target,
                                isHighlighted: cursor == .block(target.id)
                            )
                            .tag(CursorID.block(target.id))
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(.block(target.id)) }
                        }
                        if hiddenInDocCount > 0 {
                            ShowMoreRow(remaining: hiddenInDocCount) {
                                inDocExpanded = true
                            }
                        }
                    }
                }
                if pages.isEmpty && filteredInDoc.isEmpty {
                    Text("No matching destinations")
                        .font(NotionStyle.body(size: 13))
                        .foregroundStyle(NotionStyle.mutedForeground)
                        .padding(.vertical, 8)
                } else if !pages.isEmpty {
                    Section("Pages") {
                        ForEach(pages) { item in
                            MentionItemRow(
                                item: item,
                                isHighlighted: cursor == .page(item.id)
                            )
                            .tag(CursorID.page(item.id))
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(.page(item.id)) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onAppear {
                if cursor == nil { cursor = orderedCursorIDs.first }
            }
            .onChange(of: query) { _, _ in
                cursor = orderedCursorIDs.first
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let ids = orderedCursorIDs
                guard !ids.isEmpty else { return .ignored }
                let delta = press.key == .downArrow ? 1 : -1
                let idx = cursor.flatMap { c in ids.firstIndex(of: c) }
                let next: Int
                if let idx {
                    next = (idx + delta + ids.count) % ids.count
                } else {
                    next = delta > 0 ? 0 : ids.count - 1
                }
                cursor = ids[next]
                return .handled
            }
            .onKeyPress(.return) {
                guard let cursor else { return .ignored }
                switch cursor {
                case .block(let id): onActivate(.block(id))
                case .page(let id): onActivate(.page(id))
                }
                return .handled
            }
            .navigationTitle("Move to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, placement: .automatic, prompt: "Search destinations")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }
}

/// Row layout for an in-doc move target. Headings get a small `H1`/`H2`/`H3`
/// badge; toggles get a `chevron.right` glyph. Leading padding scales with
/// `target.depth` so deeper sections sit further right and the page outline
/// reads at a glance.
private struct InDocMoveTargetRow: View {
    let target: InDocMoveTarget
    var isHighlighted: Bool = false

    private static let indentPerLevel: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph
                .fixedSize()
                .frame(width: 28, alignment: .center)
            Text(target.title)
                .font(NotionStyle.body(size: 13))
                .foregroundStyle(NotionStyle.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(target.depth) * Self.indentPerLevel)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? NotionStyle.linkForeground.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch target.kind {
        case .heading(let level):
            Text("H\(level.rawValue)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotionStyle.mutedForeground)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(NotionStyle.mutedForeground.opacity(0.12))
                )
        case .toggle:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotionStyle.mutedForeground)
        }
    }
}

/// Disclosure row that reveals the rest of the in-doc destinations when the
/// list is capped. Tap to expand; not in the cursor traversal so arrow keys
/// skip past it.
private struct ShowMoreRow: View {
    let remaining: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotionStyle.mutedForeground)
                    .frame(width: 28, alignment: .center)
                Text("Show \(remaining) more")
                    .font(NotionStyle.body(size: 13))
                    .foregroundStyle(NotionStyle.mutedForeground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
