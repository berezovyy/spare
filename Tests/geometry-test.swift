// Standalone test for the two bits of palette geometry that are pure: the edge-dissolve ramp and
// the way arrow movement steps over section headers. No window, no pasteboard, no store — both
// live as static functions precisely so a harness can call them without an app around them.
import AppKit
import Foundation

@main
@MainActor
struct GeometryTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        dissolveIsOpaqueWhereNothingHasScrolledPast()
        dissolveMidBandIsBetweenFloorAndFull()
        dissolveSettlesOnTheFloorAtAndPastTheBand()
        dissolveEngagesForAListThatOnlyOverflowsTheInsets()
        steppingStopsAtBothEnds()
        movingInAnEmptyListIsANoOp()
        numberKeysReachTheRowsTheyLabel()
        storeChangesKeepTheSelectionOnTheSameEntry()
        chordsSurviveAnyKeyboardLayout()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Dissolve

    /// Distance 0 means nothing is hidden behind the bar, so the mask is fully opaque there.
    static func dissolveIsOpaqueWhereNothingHasScrolledPast() {
        let top = EdgeDissolve.alpha(
            distance: 0, band: Theme.Dissolve.topBand, floor: Theme.Dissolve.topFloor)
        let bottom = EdgeDissolve.alpha(
            distance: 0, band: Theme.Dissolve.bottomBand, floor: Theme.Dissolve.bottomFloor)
        expect(top == 1, "the top edge is opaque at distance 0")
        expect(bottom == 1, "the bottom edge is opaque at distance 0")
    }

    static func dissolveMidBandIsBetweenFloorAndFull() {
        let band = Theme.Dissolve.topBand
        let floor = Theme.Dissolve.topFloor
        let alpha = EdgeDissolve.alpha(distance: band / 2, band: band, floor: floor)
        expect(alpha > floor, "mid-band is above the floor")
        expect(alpha < 1, "mid-band is below full ink")
        // The ramp is linear, so half a band is exactly half way down it.
        expect(abs(alpha - (1 + floor) / 2) < 0.0001, "mid-band is the midpoint of the ramp")
    }

    static func dissolveSettlesOnTheFloorAtAndPastTheBand() {
        let topBand = Theme.Dissolve.topBand
        let topFloor = Theme.Dissolve.topFloor
        expect(
            isFloor(
                EdgeDissolve.alpha(distance: topBand, band: topBand, floor: topFloor), topFloor),
            "the top edge is at its floor after one band")
        expect(
            isFloor(
                EdgeDissolve.alpha(distance: topBand * 9, band: topBand, floor: topFloor),
                topFloor),
            "scrolling further does not push the top edge past its floor")
        let bottomBand = Theme.Dissolve.bottomBand
        let bottomFloor = Theme.Dissolve.bottomFloor
        expect(
            isFloor(
                EdgeDissolve.alpha(distance: bottomBand, band: bottomBand, floor: bottomFloor),
                bottomFloor),
            "the bottom edge is at its floor after one band")
        expect(
            topFloor == 0 && bottomFloor == 0,
            "no row ghosts through the search text or the key hints")
    }

    /// A list taller than the gap between the bars but shorter than the panel still runs under
    /// the footer. Measured against the full height it looked like it fit, and the mask went
    /// fully opaque — the last row then printed straight through the key hints.
    static func dissolveEngagesForAListThatOnlyOverflowsTheInsets() {
        let height: CGFloat = 420
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 54, left: 0, bottom: 40, right: 0)
        // 398 < 420, but well past the 326 points between the bars.
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 398))
        let dissolve = EdgeDissolve(scrollView: scroll)
        dissolve.update()
        let mask = scroll.layer?.mask as? CAGradientLayer
        expect(mask?.colors?.count == 6, "the mask ramps instead of going fully opaque")
        expect(mask?.frame.height == height, "the mask covers the whole scroll view")
    }

    // MARK: - Stepping and number keys

    static func steppingStopsAtBothEnds() {
        expect(ListController.step(from: 0, delta: 1, count: 3) == 1, "down moves one row")
        expect(ListController.step(from: 2, delta: 1, count: 3) == nil, "the last row is the end")
        expect(ListController.step(from: 0, delta: -1, count: 3) == nil, "up off the top stops")
        expect(ListController.step(from: 1, delta: 0, count: 3) == nil, "no delta, no move")
    }

    static func movingInAnEmptyListIsANoOp() {
        expect(ListController.step(from: -1, delta: 1, count: 0) == nil, "down is a no-op")
        expect(ListController.step(from: -1, delta: -1, count: 0) == nil, "up is a no-op")
    }

    /// The number a row shows while ⌘ is held is the number that pastes it: ⌘1 is the top row.
    static func numberKeysReachTheRowsTheyLabel() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spare-geometry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.load()
        for index in 0..<12 { store.addText("item \(index)", sourceApp: nil) }
        let list = ListController(store: store)
        list.reload()
        expect(list.item(number: 1)?.id == list.rows.first?.id, "⌘1 is the first row")
        expect(list.item(number: 9)?.id == list.rows[8].id, "⌘9 is the ninth row")
        expect(list.item(number: 0) == nil, "there is no ⌘0 row")
        expect(list.item(number: 10) == nil, "the shortcuts stop at nine")
    }

    /// A pin, an unpin or a delete re-renders the list without throwing the user back to the
    /// top. Wired the way `WindowController` wires it — one reload per store change, keeping
    /// whatever is selected at that moment — so a store that fires twice per edit shows up here.
    static func storeChangesKeepTheSelectionOnTheSameEntry() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spare-geometry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.load()
        for index in 0..<5 { store.addText("item \(index)", sourceApp: nil) }
        let list = ListController(store: store)
        store.onChange = { list.reload(keeping: list.selectedItem?.id) }
        list.reload()
        list.move(1)
        list.move(1)
        guard let chosen = list.selectedItem else {
            expect(false, "a row is selected")
            return
        }
        store.togglePinned(chosen)
        expect(list.selectedItem?.id == chosen.id, "pinning keeps the selection on the entry")
        expect(list.selection == 0, "which now leads the list")

        store.addText("arrives while open", sourceApp: nil)
        expect(list.selectedItem?.id == chosen.id, "a new capture does not move the selection")

        guard let pinnedNow = list.selectedItem else { return }
        store.togglePinned(pinnedNow)
        expect(list.selectedItem?.id == chosen.id, "unpinning keeps the selection on the entry")

        list.move(1)
        let position = list.selection
        let next = list.rows[position + 1].id
        if let doomed = list.selectedItem { store.remove(doomed) }
        expect(list.selection == position, "deleting keeps the selection where it was")
        expect(list.selectedItem?.id == next, "on the entry that followed the deleted one")
    }

    /// ⌘P is ⌘P on a Ukrainian or French keyboard too; a Dvorak user keeps their own letters.
    static func chordsSurviveAnyKeyboardLayout() {
        expect(ChordKey.resolve(typed: "p", keyCode: 35) == "p", "US: the letter typed")
        expect(
            ChordKey.resolve(typed: "P", keyCode: 35) == "p", "Caps Lock's capital is the same key")
        expect(ChordKey.resolve(typed: "з", keyCode: 35) == "p", "Cyrillic: the key's US position")
        expect(ChordKey.resolve(typed: "с", keyCode: 8) == "c", "Cyrillic с is not Latin c")
        expect(ChordKey.resolve(typed: "&", keyCode: 18) == "1", "AZERTY's unshifted 1 key is ⌘1")
        expect(ChordKey.resolve(typed: "l", keyCode: 35) == "l", "Dvorak: P's position types L")
        expect(
            ChordKey.resolve(withCommand: "p", typed: "l", keyCode: 35) == "p",
            "Dvorak – QWERTY ⌘: the letter ⌘ turns it into")
        expect(ChordKey.resolve(typed: ";", keyCode: 6) == ";", "Dvorak's ; is not ⌘Z")
        expect(ChordKey.resolve(typed: ".", keyCode: 9) == ".", "nor its . ⌘V")
        expect(ChordKey.resolve(typed: "3", keyCode: 20) == "3", "digits as typed")
        expect(
            ChordKey.resolve(typed: "\u{7f}", keyCode: 51) == "\u{7f}", "unmapped keys pass through"
        )
    }

    // MARK: - Helpers

    /// The ramp multiplies before it subtracts, so the floor arrives one ulp beside itself.
    static func isFloor(_ alpha: CGFloat, _ floor: CGFloat) -> Bool {
        abs(alpha - floor) < 0.0001
    }

    static func pinned(_ count: Int) -> [ClipboardItem] {
        (0..<count).map {
            ClipboardItem(kind: .text, text: "pin \($0)", pinnedAt: Date(timeIntervalSince1970: 1))
        }
    }

    static func history(_ count: Int) -> [ClipboardItem] {
        (0..<count).map { ClipboardItem(kind: .text, text: "item \($0)") }
    }

    static func expect(
        _ condition: Bool, _ label: String, fileID: String = #fileID, line: Int = #line
    ) {
        if condition {
            passes += 1
        } else {
            print("FAIL: \(label) (\(fileID):\(line))")
            failures += 1
        }
    }
}
