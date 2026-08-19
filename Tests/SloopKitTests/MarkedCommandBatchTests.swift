// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// One shell invocation carrying several commands, and their outputs split back
/// apart. The Mosh bootstrap is the reason this exists: it is the only SSH
/// connection a Mosh session ever has, so anything that wants to ask the host a
/// question has to ask it there, alongside `mosh-server`.
final class MarkedCommandBatchTests: XCTestCase {

    func testTheLeadCommandRunsFirst() {
        let script = MarkedCommandBatch.script(lead: "mosh-server new", commands: ["history"])
        XCTAssertTrue(script.hasPrefix("mosh-server new"))
    }

    func testEveryCommandIsInTheScript() {
        let script = MarkedCommandBatch.script(lead: "lead", commands: ["one", "two"])
        XCTAssertTrue(script.contains("one"))
        XCTAssertTrue(script.contains("two"))
    }

    /// Nothing to ask means nothing appended — a host that wants no extras runs
    /// exactly the command it would have run before this type existed.
    func testTheLeadIsUntouchedWhenThereAreNoCommands() {
        XCTAssertEqual(MarkedCommandBatch.script(lead: "mosh-server new", commands: []),
                       "mosh-server new")
    }

    func testEachCommandsOutputComesBackSeparately() {
        let script = MarkedCommandBatch.script(lead: "lead", commands: ["a", "b"])
        _ = script
        let output = """
        banner line
        \(MarkedCommandBatch.marker(0))
        first output
        \(MarkedCommandBatch.marker(1))
        second output
        """
        let split = MarkedCommandBatch.split(output, count: 2)
        XCTAssertEqual(split.lead, "banner line")
        XCTAssertEqual(split.outputs, ["first output", "second output"])
    }

    /// A command that printed nothing ran and said nothing. That is not the
    /// same as a command whose output never arrived, and the two must not
    /// collapse into one answer — "no shell history on this host" and "we never
    /// got to ask" call for different things.
    func testACommandThatPrintsNothingAnswersWithEmptyNotNil() {
        let output = "banner\n\(MarkedCommandBatch.marker(0))\n"
        XCTAssertEqual(MarkedCommandBatch.split(output, count: 1).outputs, [""])
    }

    func testOutputWithoutAnyMarkerIsAllLead() {
        let split = MarkedCommandBatch.split("MOSH CONNECT 60001 key==", count: 1)
        XCTAssertEqual(split.lead, "MOSH CONNECT 60001 key==")
        XCTAssertEqual(split.outputs, [nil])
    }

    /// A connection cut halfway through leaves the later markers unprinted.
    /// Everything after the last marker seen belongs to the command that was
    /// running; the ones that never started answer nil.
    func testCommandsAfterATruncatedBatchAnswerNil() {
        let output = "banner\n\(MarkedCommandBatch.marker(0))\npartial"
        let split = MarkedCommandBatch.split(output, count: 3)
        XCTAssertEqual(split.outputs, ["partial", nil, nil])
    }

    func testAskingForNoOutputsReturnsTheWholeThingAsLead() {
        let split = MarkedCommandBatch.split("just a banner", count: 0)
        XCTAssertEqual(split.lead, "just a banner")
        XCTAssertTrue(split.outputs.isEmpty)
    }
}
