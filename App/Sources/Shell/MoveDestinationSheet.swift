import SwiftUI
import Editor

/// Move-to destination picker. The interaction model lives in
/// `NativeSearchablePicker`; this view only builds the two destination pools:
/// in-page headings/toggles and writable workspace pages.
struct MoveDestinationSheet: View {
    let workspace: Workspace
    let inDocCandidates: [InDocMoveTarget]
    let excluding: URL?
    let onActivate: (MoveDestination) -> Void
    let onClose: () -> Void

    private static let inDocCollapsedLimit = 5

    var body: some View {
        NativeSearchablePicker(
            title: "Move to",
            searchPrompt: "Search destinations",
            emptyTitle: "No matching destinations",
            sections: { query in makeSections(query: query) },
            onActivate: activate(_:),
            onClose: onClose
        )
    }

    private func makeSections(query: String) -> [NativePickerSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredInDoc = inDocCandidates
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }

        let inDocItems = filteredInDoc
            .map { target in
                NativePickerItem(
                    id: .block(target.id),
                    title: target.title,
                    glyph: glyph(for: target.kind)
                )
            }

        let pageItems: [NativePickerItem]
        if let clamshell = workspace.clamshell {
            let home = clamshell.homeRelativePath
            pageItems = clamshell.pages(
                matching: query,
                excluding: excluding,
                filter: .locallyAvailableForWrite
            ).map { entry in
                let item = entry.asMentionItem(homeRelativePath: home)
                return NativePickerItem(
                    id: .page(item.id),
                    title: item.title,
                    subtitle: item.subtitle,
                    glyph: .page(isHome: item.isHome)
                )
            }
        } else {
            pageItems = []
        }

        return [
            NativePickerSection(
                title: "On this page",
                items: inDocItems,
                collapsedItemLimit: Self.inDocCollapsedLimit
            ),
            NativePickerSection(title: "Pages", items: pageItems)
        ]
    }

    private func glyph(for kind: InDocMoveTarget.Kind) -> NativePickerItem.Glyph {
        switch kind {
        case .heading(let level):
            return .heading(level.rawValue)
        case .toggle:
            return .toggle
        }
    }

    private func activate(_ id: NativePickerItemID) {
        switch id {
        case .block(let blockID):
            onActivate(.block(blockID))
        case .page(let pageID):
            onActivate(.page(pageID))
        }
    }
}
