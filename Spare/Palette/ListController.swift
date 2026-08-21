import AppKit

/// The results list. `NSTableView`'s row index *is* the palette's selection index, so there is no
/// flat-index model here; headers are rows that refuse selection and arrows step over them.
@MainActor
final class ListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A header is a row like any other to the table. `shouldSelectRow` is what makes it inert.
    enum Row: Sendable {
        case header(String)
        case item(ClipboardItem)
    }

    private static let textRowHeight: CGFloat = 44
    private static let imageRowHeight: CGFloat = 84
    private static let headerRowHeight: CGFloat = 26
    private static let textRowID = NSUserInterfaceItemIdentifier("text")
    private static let imageRowID = NSUserInterfaceItemIdentifier("image")
    private static let headerRowID = NSUserInterfaceItemIdentifier("header")

    let scrollView = NSScrollView()

    /// Return, or a click on a row.
    var onActivate: ((ClipboardItem) -> Void)?
    /// Right-click on a row; the owner builds the menu because it owns the actions.
    var onMenu: ((ClipboardItem) -> NSMenu?)?

    private(set) var rows: [Row] = []
    /// -1 when nothing is selectable, which is the empty list and the over-narrow filter.
    private(set) var selection = -1

    private let store: ClipboardStore
    private let tableView = NSTableView()
    private var dissolve: EdgeDissolve?
    private var query = ""
    private var filter: ClipboardFilter = .all

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
        tableView.intercellSpacing = .zero
        // Rows paint `Theme.Colors.selection` themselves; AppKit's blue would ignore the design.
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ThinScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // The bars float over the list, so the insets are what keeps a row from opening under one.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Theme.Size.headerHeight + Theme.Size.headerPadding,
            left: 0,
            bottom: Theme.Size.footerHeight,
            right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(
            top: -scrollView.contentInsets.top, left: 0,
            bottom: -scrollView.contentInsets.bottom, right: 0)
        dissolve = EdgeDissolve(scrollView: scrollView)
    }

    // MARK: - Rows

    /// Pure, so `geometry-test` can build a list without a store or a window.
    static func rows(from results: [ClipboardItem]) -> [Row] {
        let pinned = results.filter(\.isPinned)
        let history = results.filter { !$0.isPinned }
        var rows: [Row] = []
        if !pinned.isEmpty {
            rows.append(.header("Pinned"))
            rows += pinned.map(Row.item)
        }
        if !history.isEmpty {
            rows.append(.header("History"))
            rows += history.map(Row.item)
        }
        return rows
    }

    /// Where `delta` lands, stepping over headers; nil when it would leave the list. Pure.
    static func step(from selection: Int, delta: Int, in rows: [Row]) -> Int? {
        guard delta != 0 else { return nil }
        var next = selection + delta
        while rows.indices.contains(next), case .header = rows[next] { next += delta }
        return rows.indices.contains(next) ? next : nil
    }

    /// The first row a selection may land on, or -1 when the list holds nothing selectable.
    static func firstSelectable(in rows: [Row]) -> Int {
        rows.firstIndex { if case .item = $0 { return true } else { return false } } ?? -1
    }

    func buildRows(query: String, filter: ClipboardFilter) -> [Row] {
        Self.rows(from: store.search(query, filter: filter))
    }

    var selectedItem: ClipboardItem? {
        guard rows.indices.contains(selection), case .item(let item) = rows[selection] else {
            return nil
        }
        return item
    }

    // MARK: - Updating

    /// No debounce: the scan is sub-millisecond and `reloadData` only asks for visible rows.
    func queryChanged(_ query: String) {
        self.query = query
        reload()
    }

    func filterChanged(_ filter: ClipboardFilter) {
        self.filter = filter
        reload()
    }

    /// Also the store's `onChange`: a capture arriving while the panel is open re-renders it.
    func reload() {
        rows = buildRows(query: query, filter: filter)
        selection = Self.firstSelectable(in: rows)
        tableView.reloadData()
        selectAndReveal(selection)
        dissolve?.update()
    }

    /// -1 for up, +1 for down. A move that would leave the list simply does not happen.
    func move(_ delta: Int) {
        guard let next = Self.step(from: selection, delta: delta, in: rows) else { return }
        selection = next
        selectAndReveal(next)
    }

    private func selectAndReveal(_ row: Int) {
        guard rows.indices.contains(row) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        // `contentInsets` are honoured here, which is what keeps the row out from under the bars.
        tableView.scrollRowToVisible(row)
        // Rows paint their own selection, so the ones on screen have to be asked to repaint.
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 {
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.lowerBound..<visible.upperBound),
                columnIndexes: IndexSet(integer: 0))
        }
        dissolve?.update()
    }

    @objc private func rowClicked() {
        let clicked = tableView.clickedRow
        guard rows.indices.contains(clicked), case .item(let item) = rows[clicked] else { return }
        selection = clicked
        selectAndReveal(clicked)
        onActivate?(item)
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return Self.headerRowHeight
        case .item(let item): return item.kind == .image ? Self.imageRowHeight : Self.textRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let view =
                tableView.makeView(withIdentifier: Self.headerRowID, owner: self)
                as? SectionHeaderView ?? SectionHeaderView(frame: .zero)
            view.identifier = Self.headerRowID
            view.configure(title: title)
            return view
        case .item(let item) where item.kind == .image:
            let view =
                tableView.makeView(withIdentifier: Self.imageRowID, owner: self)
                as? ImageRowView ?? ImageRowView(frame: .zero)
            view.identifier = Self.imageRowID
            view.onMenu = { [weak self] in self?.onMenu?(item) }
            view.configure(item: item, selected: row == selection)
            return view
        case .item(let item):
            let view =
                tableView.makeView(withIdentifier: Self.textRowID, owner: self)
                as? TextRowView ?? TextRowView(frame: .zero)
            view.identifier = Self.textRowID
            view.onMenu = { [weak self] in self?.onMenu?(item) }
            view.configure(item: item, selected: row == selection)
            return view
        }
    }
}
