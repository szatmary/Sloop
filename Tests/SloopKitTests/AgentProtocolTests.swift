// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class AgentProtocolTests: XCTestCase {
    private let ed25519Blob: [UInt8] = [0x00, 0x00, 0x00, 0x0B]
        + Array("ssh-ed25519".utf8)
        + [0x00, 0x00, 0x00, 0x04] + [0xDE, 0xAD, 0xBE, 0xEF]

    // MARK: Framing

    func testFramerYieldsNothingUntilTheWholeFrameArrives() throws {
        var framer = AgentFramer()
        framer.append([0x00, 0x00, 0x00, 0x02, 0x0B][...])
        XCTAssertNil(try framer.nextPayload())      // payload is 2 bytes, only 1 here
        framer.append([0x00][...])
        XCTAssertEqual(try framer.nextPayload(), [0x0B, 0x00])
    }

    func testFramerYieldsTwoMessagesFromOneChunk() throws {
        var framer = AgentFramer()
        framer.append(([0x00, 0x00, 0x00, 0x01, 0x0B] + [0x00, 0x00, 0x00, 0x01, 0x0B])[...])
        XCTAssertEqual(try framer.nextPayload(), [0x0B])
        XCTAssertEqual(try framer.nextPayload(), [0x0B])
        XCTAssertNil(try framer.nextPayload())
    }

    /// An oversized length must be rejected on sight. Buffering toward it is
    /// an unbounded allocation driven by the remote host.
    func testFramerRejectsAnOversizedFrame() {
        var framer = AgentFramer()
        framer.append([0x00, 0x10, 0x00, 0x01][...])   // 1 MiB + 1
        XCTAssertThrowsError(try framer.nextPayload())
    }

    func testFramerRejectsAZeroLengthFrame() {
        var framer = AgentFramer()
        framer.append([0x00, 0x00, 0x00, 0x00][...])
        XCTAssertThrowsError(try framer.nextPayload())
    }

    // MARK: Request parsing

    func testParsesRequestIdentities() throws {
        XCTAssertEqual(try AgentRequest.parse([11]), .requestIdentities)
    }

    func testParsesSignRequest() throws {
        var writer = SSHWireWriter()
        writer.writeByte(13)
        writer.writeString(ed25519Blob)
        writer.writeString(Array("challenge".utf8))
        writer.writeUInt32(4)

        XCTAssertEqual(try AgentRequest.parse(writer.bytes),
                       .sign(keyBlob: ed25519Blob,
                             data: Array("challenge".utf8),
                             flags: 4))
    }

    func testUnknownRequestTypeIsReportedNotThrown() throws {
        // Add/remove/lock and friends are legitimate agent messages Sloop
        // chooses not to implement; they get a FAILURE, not a parse error.
        XCTAssertEqual(try AgentRequest.parse([17]), .unsupported(type: 17))
    }

    func testEmptyPayloadThrows() {
        XCTAssertThrowsError(try AgentRequest.parse([]))
    }

    func testTruncatedSignRequestThrows() {
        XCTAssertThrowsError(try AgentRequest.parse([13, 0x00, 0x00]))
    }

    // MARK: Response building

    func testIdentitiesAnswerListsEachKey() throws {
        let identity = AgentIdentity(keyName: "id_ed25519",
                                     algorithm: "ssh-ed25519",
                                     blob: ed25519Blob,
                                     comment: "id_ed25519")
        let framed = AgentResponse.identities([identity])

        var outer = SSHWireReader(framed)
        XCTAssertEqual(try outer.readUInt32(), UInt32(framed.count - 4))
        XCTAssertEqual(try outer.readByte(), 12)
        XCTAssertEqual(try outer.readUInt32(), 1)
        XCTAssertEqual(try outer.readString(), ed25519Blob)
        XCTAssertEqual(try outer.readString(), Array("id_ed25519".utf8))
        XCTAssertTrue(outer.isAtEnd)
    }

    func testIdentitiesAnswerForNoKeysIsAValidEmptyAnswer() throws {
        let framed = AgentResponse.identities([])
        var outer = SSHWireReader(framed)
        _ = try outer.readUInt32()
        XCTAssertEqual(try outer.readByte(), 12)
        XCTAssertEqual(try outer.readUInt32(), 0)
        XCTAssertTrue(outer.isAtEnd)
    }

    func testSignatureResponseWrapsAlgorithmAndSignature() throws {
        let framed = AgentResponse.signature(algorithm: "ssh-ed25519",
                                             signature: [0x01, 0x02])
        var outer = SSHWireReader(framed)
        _ = try outer.readUInt32()
        XCTAssertEqual(try outer.readByte(), 14)

        // The signature field is itself a blob of (string alg, string sig).
        var inner = SSHWireReader(try outer.readString())
        XCTAssertEqual(try inner.readString(), Array("ssh-ed25519".utf8))
        XCTAssertEqual(try inner.readString(), [0x01, 0x02])
        XCTAssertTrue(inner.isAtEnd)
        XCTAssertTrue(outer.isAtEnd)
    }

    func testFailureIsAOneByteFramedMessage() throws {
        XCTAssertEqual(AgentResponse.failure(), [0x00, 0x00, 0x00, 0x01, 0x05])
    }
}
