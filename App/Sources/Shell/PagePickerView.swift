import SwiftUI
import Editor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum NativePickerItemID: Hashable {
    case page(String)
    case block(BlockID)
}

struct NativePickerItem: Identifiable, Hashable {
    enum Glyph: Hashable {
        case page(isHome: Bool)
        case heading(Int)
        case toggle
    }

    let id: NativePickerItemID
    let title: String
    let subtitle: String?
    let glyph: Glyph
    /// Optional SF Symbol shown as a muted trailing accessory (e.g. an orphan
    /// warning). Generic so the picker stays reusable; most callers pass nil.
    let trailingSymbol: String?
    let typeSelectText: String

    init(
        id: NativePickerItemID,
        title: String,
        subtitle: String? = nil,
        glyph: Glyph,
        trailingSymbol: String? = nil,
        typeSelectText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.trailingSymbol = trailingSymbol
        self.typeSelectText = typeSelectText ?? [title, subtitle].compactMap(\.self).joined(separator: " ")
    }
}

struct NativePickerSection: Hashable {
    let title: String?
    let items: [NativePickerItem]
    let collapsedItemLimit: Int?

    init(
        title: String?,
        items: [NativePickerItem],
        collapsedItemLimit: Int? = nil
    ) {
        self.title = title
        self.items = items
        self.collapsedItemLimit = collapsedItemLimit
    }
}

/// Monotonic token used by native picker controllers to reject an async
/// response after any newer reload, including a refresh of the same query.
struct PickerQueryGeneration {
    private var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}

struct NativePickerContextAction {
    enum Role {
        case normal
        case destructive
    }

    let title: String
    let systemImage: String
    let role: Role
    let handler: () -> Void

    init(
        title: String,
        systemImage: String,
        role: Role = .normal,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.handler = handler
    }
}

/// Cross-platform searchable chooser.
///
/// The public shape is shared, but the implementation underneath is native:
/// `NSTableView` with AppKit type-select on macOS, and `UITableViewController`
/// with `UISearchController` on iOS. The search field is optional in practice:
/// neither platform focuses it on open. macOS leaves the table focused so
/// type-select is the default; iOS keeps search tucked into the navigation bar
/// until the user pulls down or taps it.
struct NativeSearchablePicker: View {
    let title: String
    let searchPrompt: String
    let emptyTitle: String
    let sections: (String) async -> [NativePickerSection]
    let contextActions: (NativePickerItem) -> [NativePickerContextAction]
    let onActivate: (NativePickerItemID) -> Void
    let onClose: () -> Void

    init(
        title: String,
        searchPrompt: String,
        emptyTitle: String,
        sections: @escaping (String) async -> [NativePickerSection],
        contextActions: @escaping (NativePickerItem) -> [NativePickerContextAction] = { _ in [] },
        onActivate: @escaping (NativePickerItemID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.sections = sections
        self.contextActions = contextActions
        self.onActivate = onActivate
        self.onClose = onClose
    }

    var body: some View {
        #if os(macOS)
        MacNativeSearchablePicker(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
        .frame(minWidth: 420, minHeight: 560)
        #elseif os(iOS)
        IOSNativeSearchablePicker(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
        #endif
    }
}

struct PageSearchSheet: View {
    let workspace: Workspace
    let excluding: URL?
    var title: String = "Search"
    let onActivate: (MentionItem) -> Void
    var onSetHome: ((MentionItem) -> Void)? = nil
    var onMoveToTrash: ((MentionItem) -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        // Read (and warm) the link graph in `body` so Observation registers and
        // the picker re-renders when the async build lands; the graph value is
        // then captured by the `sections` closure below. Nil → no badges yet.
        // Also touch `entries` so a background title warm (which the same build
        // performs) re-renders the open list with corrected titles.
        let graph = workspace.clamshell?.linkGraphOrBuild()
        _ = workspace.clamshell?.entries
        return NativeSearchablePicker(
            title: title,
            searchPrompt: "Search pages",
            emptyTitle: "No matching pages",
            sections: { query in
                guard let clamshell = workspace.clamshell else { return [] }
                let home = clamshell.homeRelativePath
                let results = await clamshell.searchPages(matching: query)
                let items = results
                    .filter { result in
                        guard let excluding else { return true }
                        return clamshell.url(for: result.relativePath) != excluding.standardizedFileURL
                    }
                    .map { result in
                        let isHome = result.relativePath == home
                        let isOrphan = graph?.isOrphan(result.relativePath) ?? false
                        return NativePickerItem(
                            id: .page(result.relativePath),
                            title: result.title,
                            subtitle: result.snippet,
                            glyph: .page(isHome: isHome),
                            trailingSymbol: isOrphan ? "exclamationmark.triangle.fill" : nil
                        )
                    }
                return [NativePickerSection(title: nil, items: items)]
            },
            contextActions: { item in
                guard case .page(let id) = item.id else { return [] }
                let mention = MentionItem(
                    id: id,
                    title: item.title,
                    subtitle: nil,
                    isHome: {
                        if case .page(let isHome) = item.glyph { return isHome }
                        return false
                    }()
                )
                var actions: [NativePickerContextAction] = []
                if let onSetHome {
                    actions.append(NativePickerContextAction(
                        title: "Set as Home",
                        systemImage: "house"
                    ) { onSetHome(mention) })
                }
                if let onMoveToTrash {
                    actions.append(NativePickerContextAction(
                        title: "Move to Trash",
                        systemImage: "trash",
                        role: .destructive
                    ) { onMoveToTrash(mention) })
                }
                return actions
            },
            onActivate: { id in
                guard case .page(let pageID) = id else { return }
                guard let clamshell = workspace.clamshell else { return }
                let item = clamshell.entry(at: pageID)?
                    .asMentionItem(homeRelativePath: clamshell.homeRelativePath)
                    ?? MentionItem(id: pageID, title: pageID)
                onActivate(item)
            },
            onClose: onClose
        )
    }
}

#if os(macOS)
private struct MacNativeSearchablePicker: NSViewControllerRepresentable {
    let title: String
    let searchPrompt: String
    let emptyTitle: String
    let sections: (String) async -> [NativePickerSection]
    let contextActions: (NativePickerItem) -> [NativePickerContextAction]
    let onActivate: (NativePickerItemID) -> Void
    let onClose: () -> Void

    func makeNSViewController(context: Context) -> MacNativeSearchablePickerController {
        MacNativeSearchablePickerController(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
    }

    func updateNSViewController(_ controller: MacNativeSearchablePickerController, context: Context) {
        controller.update(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
    }
}

@MainActor
private final class MacNativeSearchablePickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row {
        case section(String)
        case item(NativePickerItem)
        case showMore(sectionKey: String, title: String)
        case empty(String)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let tableView = PickerNSTableView()
    private let scrollView = NSScrollView()

    private var pickerTitle: String
    private var searchPrompt: String
    private var emptyTitle: String
    private var makeSections: (String) async -> [NativePickerSection]
    private var makeContextActions: (NativePickerItem) -> [NativePickerContextAction]
    private var activate: (NativePickerItemID) -> Void
    private var close: () -> Void
    private var rows: [Row] = []
    private var expandedSectionKeys: Set<String> = []
    private var queryTask: Task<Void, Never>?
    private var queryGeneration = PickerQueryGeneration()
    private var appliedQuery = ""

    init(
        title: String,
        searchPrompt: String,
        emptyTitle: String,
        sections: @escaping (String) async -> [NativePickerSection],
        contextActions: @escaping (NativePickerItem) -> [NativePickerContextAction],
        onActivate: @escaping (NativePickerItemID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pickerTitle = title
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.makeSections = sections
        self.makeContextActions = contextActions
        self.activate = onActivate
        self.close = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        searchPrompt: String,
        emptyTitle: String,
        sections: @escaping (String) async -> [NativePickerSection],
        contextActions: @escaping (NativePickerItem) -> [NativePickerContextAction],
        onActivate: @escaping (NativePickerItemID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pickerTitle = title
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.makeSections = sections
        self.makeContextActions = contextActions
        self.activate = onActivate
        self.close = onClose
        titleLabel.stringValue = title
        searchField.placeholderString = searchPrompt
        reload(selectFirst: false)
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = pickerTitle
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        searchField.placeholderString = searchPrompt
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .regular

        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.allowsTypeSelect = true
        tableView.allowsEmptySelection = false
        tableView.rowHeight = 30
        tableView.rowSizeStyle = .small
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.onReturn = { [weak self] in self?.activateSelection() }
        tableView.onCancel = { [weak self] in self?.close() }
        tableView.onFocusSearch = { [weak self] in self?.view.window?.makeFirstResponder(self?.searchField) }
        tableView.contextMenuForRow = { [weak self] row in self?.menu(forRow: row) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let spacer = NSView()
        let header = NSStackView(views: [titleLabel, spacer, searchField, cancelButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.setCustomSpacing(14, after: searchField)

        let stack = NSStackView(views: [header, scrollView])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 220),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload(selectFirst: true)
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func cancel() {
        close()
    }

    @objc private func searchChanged() {
        reload(selectFirst: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        reload(selectFirst: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            selectFirstItem()
            view.window?.makeFirstResponder(tableView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            return activateSoleResult()
        default:
            return false
        }
    }

    private func reload(selectFirst: Bool) {
        let query = searchField.stringValue
        queryTask?.cancel()
        let generation = queryGeneration.begin()
        let makeSections = self.makeSections
        queryTask = Task { @MainActor [weak self] in
            let renderedSections = await makeSections(query).filter { !$0.items.isEmpty }
            guard !Task.isCancelled, let self,
                  self.queryGeneration.accepts(generation),
                  self.searchField.stringValue == query else { return }
            self.apply(renderedSections, query: query, selectFirst: selectFirst)
        }
    }

    private func apply(_ renderedSections: [NativePickerSection], query: String, selectFirst: Bool) {
        appliedQuery = query
        let itemRows = renderedSections.enumerated().flatMap { index, section in
            visibleItems(for: section, key: sectionKey(for: index, section: section), query: query)
        }
        if itemRows.isEmpty {
            rows = [.empty(emptyTitle)]
        } else {
            rows = renderedSections.enumerated().flatMap { index, section -> [Row] in
                let key = sectionKey(for: index, section: section)
                let visibleItems = visibleItems(for: section, key: key, query: query)
                let hiddenCount = section.items.count - visibleItems.count
                var sectionRows: [Row] = []
                if let title = section.title, !title.isEmpty {
                    sectionRows.append(.section(title))
                }
                sectionRows.append(contentsOf: visibleItems.map(Row.item))
                if hiddenCount > 0 {
                    sectionRows.append(.showMore(sectionKey: key, title: "Show \(hiddenCount) more"))
                }
                return sectionRows
            }
        }
        tableView.reloadData()
        if selectFirst {
            selectFirstItem()
        } else if tableView.selectedRow < 0 || tableView.selectedRow >= rows.count || !isSelectable(row: tableView.selectedRow) {
            selectFirstItem()
        }
    }

    private func selectFirstItem() {
        guard let index = rows.indices.first(where: isSelectable(row:)) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func item(at row: Int) -> NativePickerItem? {
        guard rows.indices.contains(row) else { return nil }
        if case .item(let item) = rows[row] { return item }
        return nil
    }

    private func sectionKey(for index: Int, section: NativePickerSection) -> String {
        "\(index):\(section.title ?? "")"
    }

    private func visibleItems(for section: NativePickerSection, key: String, query: String) -> [NativePickerItem] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let limit = section.collapsedItemLimit,
              section.items.count > limit,
              !expandedSectionKeys.contains(key) else {
            return section.items
        }
        return Array(section.items.prefix(limit))
    }

    @objc private func showMore(_ sender: ShowMoreButton) {
        guard let key = sender.sectionKey else { return }
        expandedSectionKeys.insert(key)
        reload(selectFirst: false)
    }

    private func isSelectable(row: Int) -> Bool {
        item(at: row) != nil
    }

    private func activateSelection() {
        guard let item = item(at: tableView.selectedRow) else { return }
        activate(item.id)
    }

    private func activateSoleResult() -> Bool {
        guard appliedQuery == searchField.stringValue else { return false }
        let items = rows.compactMap { row -> NativePickerItem? in
            if case .item(let item) = row { return item }
            return nil
        }
        guard items.count == 1, let item = items.first else { return false }
        activate(item.id)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section: 22
        case .showMore: 30
        case .empty: 32
        case .item: 30
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isSelectable(row: row)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        item(at: row)?.typeSelectText
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, !isSelectable(row: tableView.selectedRow) else { return }
        selectFirstItem()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(let title):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
            ])
            return cell
        case .empty(let title):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title)
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        case .showMore(let sectionKey, let title):
            return MacShowMoreCellView(sectionKey: sectionKey, title: title, target: self, action: #selector(showMore(_:)))
        case .item(let item):
            return MacPickerCellView(item: item)
        }
    }

    /// Build the right-click / control-click menu for `row`. Invoked from the
    /// table's `menu(for:)` override (NOT a delegate callback — `NSTableView`
    /// has no `menuForRows:`, which is why the menu never appeared). Selects the
    /// clicked row so the menu's target is unambiguous.
    fileprivate func menu(forRow row: Int) -> NSMenu? {
        guard let item = item(at: row) else { return nil }
        let actions = makeContextActions(item)
        guard !actions.isEmpty else { return nil }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = NSMenu()
        for action in actions {
            let menuItem = NSMenuItem(title: action.title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            menuItem.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: action.title)
            menuItem.representedObject = ContextActionBox(action)
            menuItem.target = self
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ContextActionBox)?.action.handler()
    }
}

@MainActor
private final class ContextActionBox: NSObject {
    let action: NativePickerContextAction

    init(_ action: NativePickerContextAction) {
        self.action = action
    }
}

private final class PickerNSTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusSearch: (() -> Void)?
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return contextMenuForRow?(row)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            onFocusSearch?()
            return
        }
        switch event.keyCode {
        case 36, 76:
            onReturn?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class MacPickerCellView: NSTableCellView {
    init(item: NativePickerItem) {
        super.init(frame: .zero)

        let icon = item.glyph.macView
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(title)

        if let subtitle = item.subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(subtitleLabel)
        }

        addSubview(icon)
        addSubview(textStack)

        var constraints: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let symbol = item.trailingSymbol {
            let accessory = NSImageView(image: NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil
            ) ?? NSImage())
            accessory.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            accessory.contentTintColor = .systemOrange
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8)
            ]
        } else {
            constraints.append(textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class MacShowMoreCellView: NSTableCellView {
    init(sectionKey: String, title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)

        let button = ShowMoreButton()
        button.sectionKey = sectionKey
        button.target = target
        button.action = action
        button.isBordered = false
        button.imagePosition = .imageLeft
        button.alignment = .left
        button.contentTintColor = .secondaryLabelColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(button)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),

            button.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ShowMoreButton: NSButton {
    var sectionKey: String?
}

@MainActor
private extension NativePickerItem.Glyph {
    var macView: NSView {
        switch self {
        case .page(let isHome):
            let view = NSImageView(image: NSImage(
                systemSymbolName: isHome ? "house" : "doc.text",
                accessibilityDescription: nil
            ) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            view.contentTintColor = .secondaryLabelColor
            return view
        case .heading(let level):
            let label = NSTextField(labelWithString: "H\(level)")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        case .toggle:
            let view = NSImageView(image: NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: nil
            ) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            view.contentTintColor = .secondaryLabelColor
            return view
        }
    }
}
#elseif os(iOS)
private struct IOSNativeSearchablePicker: UIViewControllerRepresentable {
    let title: String
    let searchPrompt: String
    let emptyTitle: String
    let sections: (String) async -> [NativePickerSection]
    let contextActions: (NativePickerItem) -> [NativePickerContextAction]
    let onActivate: (NativePickerItemID) -> Void
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = IOSNativeSearchablePickerController(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ navigationController: UINavigationController, context: Context) {
        guard let controller = navigationController.viewControllers.first as? IOSNativeSearchablePickerController else { return }
        controller.update(
            title: title,
            searchPrompt: searchPrompt,
            emptyTitle: emptyTitle,
            sections: sections,
            contextActions: contextActions,
            onActivate: onActivate,
            onClose: onClose
        )
    }
}

@MainActor
private final class IOSNativeSearchablePickerController: UITableViewController, UISearchResultsUpdating {
    private let typeSelectTableView = TypeSelectTableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)

    private var pickerTitle: String
    private var searchPrompt: String
    private var emptyTitle: String
    private var makeSections: (String) async -> [NativePickerSection]
    private var makeContextActions: (NativePickerItem) -> [NativePickerContextAction]
    private var activate: (NativePickerItemID) -> Void
    private var close: () -> Void
    private var renderedSections: [NativePickerSection] = []
    private var expandedSectionKeys: Set<String> = []
    private var currentQuery = ""
    private var queryTask: Task<Void, Never>?
    private var queryGeneration = PickerQueryGeneration()

    init(
        title: String,
        searchPrompt: String,
        emptyTitle: String,
        sections: @escaping (String) async -> [NativePickerSection],
        contextActions: @escaping (NativePickerItem) -> [NativePickerContextAction],
        onActivate: @escaping (NativePickerItemID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pickerTitle = title
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.makeSections = sections
        self.makeContextActions = contextActions
        self.activate = onActivate
        self.close = onClose
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        tableView = typeSelectTableView
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pickerTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = searchPrompt
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.allowsSelection = true
        tableView.allowsFocus = true
        tableView.selectionFollowsFocus = true
        typeSelectTableView.typeSelectHandler = { [weak self] string in
            self?.selectTypeMatch(for: string)
        }

        reload(selectFirst: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        typeSelectTableView.becomeFirstResponder()
    }

    func update(
        title: String,
        searchPrompt: String,
        emptyTitle: String,
        sections: @escaping (String) async -> [NativePickerSection],
        contextActions: @escaping (NativePickerItem) -> [NativePickerContextAction],
        onActivate: @escaping (NativePickerItemID) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pickerTitle = title
        self.searchPrompt = searchPrompt
        self.emptyTitle = emptyTitle
        self.makeSections = sections
        self.makeContextActions = contextActions
        self.activate = onActivate
        self.close = onClose
        self.title = title
        searchController.searchBar.placeholder = searchPrompt
        reload(selectFirst: false)
    }

    @objc private func cancel() {
        close()
    }

    func updateSearchResults(for searchController: UISearchController) {
        reload(selectFirst: false)
        tableView.selectRow(at: nil, animated: false, scrollPosition: .none)
    }

    private func reload(selectFirst: Bool) {
        let query = searchController.searchBar.text ?? ""
        currentQuery = query
        queryTask?.cancel()
        let generation = queryGeneration.begin()
        let makeSections = self.makeSections
        queryTask = Task { @MainActor [weak self] in
            let sections = await makeSections(query).filter { !$0.items.isEmpty }
            guard !Task.isCancelled, let self,
                  self.queryGeneration.accepts(generation),
                  self.currentQuery == query else { return }
            self.renderedSections = sections
            self.tableView.reloadData()
            if selectFirst { self.selectFirstItem() }
        }
    }

    private func selectFirstItem() {
        guard let indexPath = firstItemIndexPath() else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    private func firstItemIndexPath() -> IndexPath? {
        for section in renderedSections.indices where !visibleItems(in: section).isEmpty {
            return IndexPath(row: 0, section: section)
        }
        return nil
    }

    private func item(at indexPath: IndexPath) -> NativePickerItem? {
        guard renderedSections.indices.contains(indexPath.section),
              visibleItems(in: indexPath.section).indices.contains(indexPath.row) else { return nil }
        return visibleItems(in: indexPath.section)[indexPath.row]
    }

    private func sectionKey(for index: Int, section: NativePickerSection) -> String {
        "\(index):\(section.title ?? "")"
    }

    private func visibleItems(in sectionIndex: Int) -> [NativePickerItem] {
        guard renderedSections.indices.contains(sectionIndex) else { return [] }
        let section = renderedSections[sectionIndex]
        let key = sectionKey(for: sectionIndex, section: section)
        guard currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let limit = section.collapsedItemLimit,
              section.items.count > limit,
              !expandedSectionKeys.contains(key) else {
            return section.items
        }
        return Array(section.items.prefix(limit))
    }

    private func hiddenItemCount(in sectionIndex: Int) -> Int {
        guard renderedSections.indices.contains(sectionIndex) else { return 0 }
        let section = renderedSections[sectionIndex]
        return max(0, section.items.count - visibleItems(in: sectionIndex).count)
    }

    @objc private func showMore(_ sender: UIButton) {
        guard renderedSections.indices.contains(sender.tag) else { return }
        expandedSectionKeys.insert(sectionKey(for: sender.tag, section: renderedSections[sender.tag]))
        reload(selectFirst: false)
    }

    private func selectTypeMatch(for string: String) {
        let lower = string.lowercased()
        guard !lower.isEmpty else { return }
        let selected = tableView.indexPathForSelectedRow
        let all = renderedSections.indices.flatMap { section in
            visibleItems(in: section).indices.map { row in IndexPath(row: row, section: section) }
        }
        guard !all.isEmpty else { return }
        let start = selected.flatMap { all.firstIndex(of: $0) }.map { ($0 + 1) % all.count } ?? 0
        let ordered = all[start...] + all[..<start]
        guard let match = ordered.first(where: { item(at: $0)?.typeSelectText.lowercased().hasPrefix(lower) == true }) else { return }
        tableView.selectRow(at: match, animated: true, scrollPosition: .middle)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        max(renderedSections.count, 1)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !renderedSections.isEmpty else { return 1 }
        return visibleItems(in: section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !renderedSections.isEmpty else { return nil }
        return renderedSections[section].title
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let hiddenCount = hiddenItemCount(in: section)
        guard hiddenCount > 0 else { return nil }

        var configuration = UIButton.Configuration.plain()
        configuration.title = "Show \(hiddenCount) more"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.tag = section
        button.addTarget(self, action: #selector(showMore(_:)), for: .touchUpInside)

        let view = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        hiddenItemCount(in: section) > 0 ? 38 : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        guard !renderedSections.isEmpty, let item = item(at: indexPath) else {
            var config = cell.defaultContentConfiguration()
            config.text = emptyTitle
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        }

        var config = cell.defaultContentConfiguration()
        config.text = item.title
        config.secondaryText = item.subtitle
        config.image = item.glyph.uiImage
        config.textProperties.font = .preferredFont(forTextStyle: .body)
        config.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        cell.accessoryType = .none
        if let symbol = item.trailingSymbol {
            let accessory = UIImageView(image: UIImage(systemName: symbol))
            accessory.tintColor = .systemOrange
            accessory.sizeToFit()
            cell.accessoryView = accessory
        } else {
            cell.accessoryView = nil
        }
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        guard typeSelectTableView.isTouchSelecting || tableView.isTracking else { return }
        activate(item.id)
    }

    override func tableView(_ tableView: UITableView, performPrimaryActionForRowAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        activate(item.id)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let actions = makeContextActions(item).reversed().map { action in
            UIContextualAction(
                style: action.role == .destructive ? .destructive : .normal,
                title: action.title
            ) { _, _, completion in
                action.handler()
                completion(true)
            }
        }
        guard !actions.isEmpty else { return nil }
        return UISwipeActionsConfiguration(actions: actions)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let actions = makeContextActions(item)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: actions.map { action in
                UIAction(
                    title: action.title,
                    image: UIImage(systemName: action.systemImage),
                    attributes: action.role == .destructive ? [.destructive] : []
                ) { _ in action.handler() }
            })
        }
    }
}

private final class TypeSelectTableView: UITableView {
    var typeSelectHandler: ((String) -> Void)?
    private(set) var isTouchSelecting = false
    private var buffer = ""
    private var resetTask: Task<Void, Never>?

    override var canBecomeFirstResponder: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        isTouchSelecting = true
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        resetTouchSelecting()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        resetTouchSelecting()
    }

    private func resetTouchSelecting() {
        DispatchQueue.main.async { [weak self] in
            self?.isTouchSelecting = false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key,
              key.modifierFlags.isEmpty,
              key.characters.count == 1,
              key.characters.rangeOfCharacter(from: .alphanumerics) != nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        buffer += key.characters
        typeSelectHandler?(buffer)
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            self?.buffer = ""
        }
    }
}

private extension NativePickerItem.Glyph {
    var uiImage: UIImage? {
        switch self {
        case .page(let isHome):
            UIImage(systemName: isHome ? "house" : "doc.text")
        case .heading:
            UIImage(systemName: "textformat.size")
        case .toggle:
            UIImage(systemName: "chevron.right")
        }
    }
}
#endif
