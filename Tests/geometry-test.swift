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
        headerRowsAreNeverSelected()
        movingUpFromTheFirstHistoryRowSkipsOntoTheLastPin()
        movingDownFromTheLastPinSkipsOntoTheFirstHistoryRow()
        movingInAnEmptyListIsANoOp()

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
        expect(bottomFloor > topFloor, "the footer floor is the heavier of the two")
    }

    // MARK: - Header stepping

    static func headerRowsAreNeverSelected() {
        let rows = ListController.rows(from: pinned(2) + history(3))
        expect(rows.count == 7, "two headers lead their sections")
        expect(isHeader(rows[0]), "the pinned section opens with a header")
        expect(isHeader(rows[3]), "the history section opens with a header")
        expect(ListController.firstSelectable(in: rows) == 1, "selection opens on the first pin")

        var index = ListController.firstSelectable(in: rows)
        // Walk the whole list: no step in either direction may land on a header.
        while let next = ListController.step(from: index, delta: 1, in: rows) {
            expect(!isHeader(rows[next]), "stepping down never lands on a header")
            index = next
        }
        while let next = ListController.step(from: index, delta: -1, in: rows) {
            expect(!isHeader(rows[next]), "stepping up never lands on a header")
            index = next
        }
        expect(index == 1, "walking back up ends on the first pin")
    }

    static func movingUpFromTheFirstHistoryRowSkipsOntoTheLastPin() {
        let rows = ListController.rows(from: pinned(2) + history(3))
        // 0 header, 1-2 pins, 3 header, 4-6 history.
        expect(
            ListController.step(from: 4, delta: -1, in: rows) == 2, "up skips the History header")
    }

    static func movingDownFromTheLastPinSkipsOntoTheFirstHistoryRow() {
        let rows = ListController.rows(from: pinned(2) + history(3))
        expect(
            ListController.step(from: 2, delta: 1, in: rows) == 4, "down skips the History header")
        expect(ListController.step(from: 6, delta: 1, in: rows) == nil, "the last row is the end")
    }

    static func movingInAnEmptyListIsANoOp() {
        let rows = ListController.rows(from: [])
        expect(rows.isEmpty, "no sections without entries")
        expect(ListController.firstSelectable(in: rows) == -1, "nothing is selectable")
        expect(ListController.step(from: -1, delta: 1, in: rows) == nil, "down is a no-op")
        expect(ListController.step(from: -1, delta: -1, in: rows) == nil, "up is a no-op")
        // A list of pins only still has one header, and it is still unreachable.
        let onlyPins = ListController.rows(from: pinned(1))
        expect(ListController.step(from: 1, delta: -1, in: onlyPins) == nil, "up off the top stops")
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

    static func isHeader(_ row: ListController.Row) -> Bool {
        if case .header = row { return true }
        return false
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
