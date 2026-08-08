import XCTest
@testable import SloopKit

final class OpenSessionsTests: XCTestCase {

    private func session(_ title: String) -> TerminalSession {
        TerminalSession(title: title, transport: EchoTransport())
    }

    func testOpenAppendsAndSelects() {
        var open = OpenSessions()
        XCTAssertTrue(open.isEmpty)
        XCTAssertNil(open.selectedID)

        let a = session("a")
        open.open(a)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.selectedID, a.id)
        XCTAssertEqual(open.selected?.id, a.id)
    }

    func testOpenMultipleSelectsNewest() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b")
        open.open(a); open.open(b)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open.selectedID, b.id)
    }

    func testSelectExistingAndAbsent() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b")
        open.open(a); open.open(b)

        open.select(a.id)
        XCTAssertEqual(open.selectedID, a.id)

        // Selecting an unknown id is a no-op.
        open.select(session("ghost").id)
        XCTAssertEqual(open.selectedID, a.id)
    }

    func testCloseActiveSelectsLeftNeighbor() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b"); let c = session("c")
        open.open(a); open.open(b); open.open(c)   // selected: c

        open.select(b.id)                          // selected: b (middle)
        let removed = open.close(b.id)
        XCTAssertEqual(removed?.id, b.id)
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(open.selectedID, a.id)      // left neighbor
    }

    func testCloseActiveFirstSelectsNewFirst() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b")
        open.open(a); open.open(b)
        open.select(a.id)                          // selected: a (first)

        open.close(a.id)
        XCTAssertEqual(open.selectedID, b.id)      // new first
    }

    func testCloseInactiveKeepsSelection() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b")
        open.open(a); open.open(b)                 // selected: b

        open.close(a.id)                           // close the non-active one
        XCTAssertEqual(open.selectedID, b.id)
        XCTAssertEqual(open.count, 1)
    }

    func testCloseLastLeavesNothingSelected() {
        var open = OpenSessions()
        let a = session("a")
        open.open(a)
        open.close(a.id)
        XCTAssertTrue(open.isEmpty)
        XCTAssertNil(open.selectedID)
        XCTAssertNil(open.selected)
    }

    func testCloseUnknownIsNoOp() {
        var open = OpenSessions()
        let a = session("a")
        open.open(a)
        XCTAssertNil(open.close(session("ghost").id))
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.selectedID, a.id)
    }

    func testSelectNextWraps() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b"); let c = session("c")
        open.open(a); open.open(b); open.open(c)
        open.select(a.id)

        open.selectNext(); XCTAssertEqual(open.selectedID, b.id)
        open.selectNext(); XCTAssertEqual(open.selectedID, c.id)
        open.selectNext(); XCTAssertEqual(open.selectedID, a.id)   // wrap
    }

    func testSelectPreviousWraps() {
        var open = OpenSessions()
        let a = session("a"); let b = session("b"); let c = session("c")
        open.open(a); open.open(b); open.open(c)
        open.select(a.id)

        open.selectPrevious(); XCTAssertEqual(open.selectedID, c.id)   // wrap
        open.selectPrevious(); XCTAssertEqual(open.selectedID, b.id)
        open.selectPrevious(); XCTAssertEqual(open.selectedID, a.id)
    }

    func testSelectNextPreviousEmptyIsNoOp() {
        var open = OpenSessions()
        open.selectNext()
        XCTAssertNil(open.selectedID)
        open.selectPrevious()
        XCTAssertNil(open.selectedID)
    }

    func testSelectNextSingleStaysPut() {
        var open = OpenSessions()
        let a = session("a")
        open.open(a)
        open.selectNext(); XCTAssertEqual(open.selectedID, a.id)
        open.selectPrevious(); XCTAssertEqual(open.selectedID, a.id)
    }
}
