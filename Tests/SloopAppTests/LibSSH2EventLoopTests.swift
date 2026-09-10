// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import XCTest
import CSSH
@testable import SloopSSH

/// The event loop's exit conditions, as pure logic.
///
/// The loop itself needs a live server to run, which is exactly why this bug
/// shipped: every test passed and a dead socket still spun at 100% CPU with the
/// tab reading "Connected". Pulling the decision out of the loop is what makes
/// it answerable without one.
final class LibSSH2ChannelReadOutcomeTests: XCTestCase {

    func testBytesAvailable() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: 42, isEOF: false), .data(42))
    }

    func testEAGAINMeansNothingToReadRightNow() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: Int(LIBSSH2_ERROR_EAGAIN), isEOF: false),
                       .wouldBlock)
    }

    /// The remote closed the channel: the session is over, and nothing is wrong.
    func testZeroWithChannelEOFEndsTheSessionCleanly() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: 0, isEOF: true), .endOfFile)
    }

    func testZeroWithoutEOFIsJustNoData() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: 0, isEOF: false), .wouldBlock)
    }

    /// The finding. A server reboot, an sshd kill, a NAT RST or iOS resuming
    /// after a network reset makes libssh2 return `SOCKET_RECV` and then
    /// `SOCKET_DISCONNECT` — and none of them sets channel EOF, because the
    /// channel never got the chance to close politely. Treating that as "no
    /// data" is what left the loop polling a dead fd.
    func testASocketErrorEndsTheSessionEvenWithoutChannelEOF() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: Int(LIBSSH2_ERROR_SOCKET_RECV), isEOF: false),
                       .failed(Int(LIBSSH2_ERROR_SOCKET_RECV)))
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: Int(LIBSSH2_ERROR_SOCKET_DISCONNECT), isEOF: false),
                       .failed(Int(LIBSSH2_ERROR_SOCKET_DISCONNECT)))
    }

    /// Any other negative return is a failure too. Enumerating the ones seen in
    /// the wild is how the original `if eof` check came to miss the rest.
    func testAnyOtherNegativeReturnIsAFailure() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: Int(LIBSSH2_ERROR_SOCKET_TIMEOUT), isEOF: false),
                       .failed(Int(LIBSSH2_ERROR_SOCKET_TIMEOUT)))
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: -999, isEOF: false), .failed(-999))
    }

    /// A failure reported *with* channel EOF is still the end of the session,
    /// and the clean reading is the honest one: the remote said goodbye.
    func testEOFWinsOverAnErrorCode() {
        XCTAssertEqual(LibSSH2Transport.readOutcome(n: Int(LIBSSH2_ERROR_SOCKET_RECV), isEOF: true),
                       .endOfFile)
    }
}
#endif
