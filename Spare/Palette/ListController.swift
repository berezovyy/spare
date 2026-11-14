import AppKit

/// The results list. `NSTableView`'s row index *is* the palette's selection index; pinned
/// entries lead the list (the store orders them) and carry a pin glyph instead of a header.
@MainActor
final class ListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("clip")
    /// ⌘1…⌘9: the rows a number key reaches.
    static let shortcutCount = 9

    let scrollView = NSScrollView()
    /// Laid out by the owner over the list's area; shown only while there are no rows.
    let emptyView = EmptyStateView()

    /// Return, or a click on a row.
    var onActivate: ((ClipboardItem) -> Void)?
    /// Right-click on a row; the owner builds the menu because it owns the actions.
    var onMenu: ((ClipboardItem) -> NSMenu?)?

    private(set) var rows: [ClipboardItem] = []
    /// -1 when nothing is selectable: the empty list and the over-narrow filter.
    private(set) var selection = -1
    private(set) var query = ""
    private(set) var filter: ClipboardFilter = .all

    /// While ⌘ is held the first rows show their number instead of their details.
    var showsShortcuts = false {
        didSet {
            guard showsShortcuts != oldValue else { return }
            refreshVisibleRows()
        }
    }

    private let store: ClipboardStore
    private let tableView = NSTableView()
    private let highlight = SelectionHighlight()
    private var dissolve: EdgeDissolve?
    private var resizeObserver: (any NSObjectProtocol)?

    init(store: ClipboardStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Theme.Size.rowHeight
        tableView.intercellSpacing = .zero
        // `SelectionHighlight` paints the selection; AppKit's blue would ignore the design.
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        // Positioned below everything: row views are added later and land on top of it.
        tableView.addSubview(highlight, positioned: .below, relativeTo: nil)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ThinScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // The search row floats over the list, so the insets keep a row from opening under it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Theme.Size.headerHeight + Theme.Size.headerPadding + Theme.Size.listTopGap,
            left: 0,
            bottom: Theme.Size.listBottomInset,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: -scrollView.contentInsets.top, left: 0,
            bottom: -scrollView.contentInsets.bottom, right: 0)
        dissolve = EdgeDissolve(scrollView: scrollView)

        // The highlight is placed in table coordinates, so a table that changes width under it
        // would leave it at the old size.
        tableView.postsFrameChangedNotifications = true
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tableView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeHighlight(animated: false) }
        }
    }

    isolated deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    // MARK: - Pure stepping

    /// Where `delta` lands; nil when it would leave the list. Pure, so a harness can call it.
    static func step(from selection: Int, delta: Int, count: Int) -> Int? {
        guard delta != 0 else { return nil }
        let next = selection + delta
        return (0..<count).contains(next) ? next : nil
    }

    var selectedItem: ClipboardItem? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// The row a number key reaches: 1 is the first row.
    func item(number: Int) -> ClipboardItem? {
        guard (1...Self.shortcutCount).contains(number), rows.indices.contains(number - 1) else {
            return nil
        }
        return rows[number - 1]
    }

    // MARK: - Updating

    /// No debounce: a scan of 1,000 entries stays well inside a frame, under 3.5 ms when every
    /// one is 1.7 KB and 7 ms at the 4 KB search-key cap (measured, worst case of a few thousand
    /// keystrokes), and `reloadData` only asks for visible rows.
    func queryChanged(_ query: String) {
        self.query = query
        reload()
    }

    func filterChanged(_ filter: ClipboardFilter) {
        self.filter = filter
        reload()
    }

    /// A new result set starts at the top. `keeping` is for edits to the set in hand — a pin,
    /// a delete, a capture arriving while the panel is open — where the selection should stay
    /// on the same entry, or failing that the same position.
    func reload(keeping: ClipboardItem.ID? = nil) {
        let previous = selection
        rows = store.search(query, filter: filter)
        if let keeping, let index = rows.firstIndex(where: { $0.id == keeping }) {
            selection = index
        } else if keeping != nil, !rows.isEmpty {
            selection = min(max(previous, 0), rows.count - 1)
        } else {
            selection = rows.isEmpty ? -1 : 0
        }
        tableView.reloadData()
        // A new result set is a new list, not a move: the highlight appears on it in place.
        selectAndReveal(selection, animated: keeping != nil)
        dissolve?.update()
        updateEmptyState()
    }

    /// Back to the full, unfiltered list without reloading; the summon reloads once laid out.
    func reset() {
        query = ""
        filter = .all
    }

    /// Puts the selection on an entry by id, if it is in the list.
    func select(_ id: ClipboardItem.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selection = index
        selectAndReveal(index, animated: true)
    }

    /// -1 for up, +1 for down. A move that would leave the list simply does not happen.
    func move(_ delta: Int) {
        guard let next = Self.step(from: selection, delta: delta, count: rows.count) else {
            return
        }
        selection = next
        selectAndReveal(next, animated: true)
    }

    private func updateEmptyState() {
        emptyView.isHidden = !rows.isEmpty
        guard rows.isEmpty else { return }
        if !query.isEmpty {
            emptyView.configure(
                symbol: "magnifyingglass", headline: "Nothing matches “\(query)”",
                detail: filter == .all ? "" : "Only \(filter.noun) are shown — ⌘F to change")
        } else if filter != .all {
            emptyView.configure(
                symbol: filter.systemImage, headline: "No \(filter.noun) yet",
                detail: "⌘F to show everything")
        } else {
            emptyView.configure(
                symbol: "doc.on.clipboard", headline: "Nothing copied yet",
                detail: "Copy something and it appears here")
        }
    }

    private func placeHighlight(animated: Bool) {
        guard rows.indices.contains(selection) else {
            highlight.isHidden = true
            return
        }
        highlight.move(
            to: RowMetrics.fillFrame(in: tableView.rect(ofRow: selection)), animated: animated)
    }

    private func selectAndReveal(_ row: Int, animated: Bool) {
        placeHighlight(animated: animated)
        guard rows.indices.contains(row) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        // `contentInsets` are honoured here, which is what keeps the row out from under the bar.
        tableView.scrollRowToVisible(row)
        refreshVisibleRows()
        dissolve?.update()
    }

    /// Rows show details only when selected, so the ones on screen are asked again.
    private func refreshVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.lowerBound..<visible.upperBound),
            columnIndexes: IndexSet(integer: 0))
    }

    @objc private func rowClicked() {
        let clicked = tableView.clickedRow
        guard rows.indices.contains(clicked) else { return }
        selection = clicked
        selectAndReveal(clicked, animated: true)
        onActivate?(rows[clicked])
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let item = rows[row]
        let view =
            tableView.makeView(withIdentifier: Self.rowID, owner: self) as? ClipRowView
            ?? ClipRowView(frame: .zero)
        view.identifier = Self.rowID
        view.onMenu = { [weak self] in self?.onMenu?(item) }
        let shortcut = showsShortcuts && row < Self.shortcutCount ? row + 1 : nil
        view.configure(item: item, query: query, selected: row == selection, shortcut: shortcut)
        return view
    }
}

extension ClipboardFilter {
    /// The plural a sentence uses: "No links yet".
    var noun: String {
        switch self {
        case .all: return "clips"
        case .text: return "text clips"
        case .image: return "images"
        case .link: return "links"
        case .email: return "email addresses"
        }
    }
}
