import SwiftUI
import Editor

/// Move-to picker. Shows two grouped sections:
/// - "On this page" — `InDocMoveTarget`s the editor walked out of the
///   current document (headings + toggles, already filtered to legal drop
///   targets). Indented by depth so the page outline is visible.
/// - "Pages" — every other workspace page (workspace's own search rank).
///
/// One search field filters both pools. Arrow keys move a single cursor
/// across both groups (in-doc first, in document order, then pages); Return
/// or click commits.
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

    /// One-of cursor across both groups so arrow keys traverse the whole
    /// list seamlessly. Hashable so `List(selection:)` can use it directly.
    enum CursorID: Hashable {
        case block(BlockID)
        case page(String)
    }

    private var filteredInDoc: [InDocMoveTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return inDocCandidates }
        return inDocCandidates.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var pages: [MentionItem] {
        workspace.pages(matching: query, excluding: excluding)
    }

    private var orderedCursorIDs: [CursorID] {
        filteredInDoc.map { .block($0.id) } + pages.map { .page($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $cursor) {
                if !filteredInDoc.isEmpty {
                    Section("On this page") {
                        ForEach(filteredInDoc) { target in
                            InDocMoveTargetRow(target: target)
                                .tag(CursorID.block(target.id))
                                .contentShape(Rectangle())
                                .onTapGesture { onActivate(.block(target.id)) }
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
                            MentionItemRow(item: item)
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
