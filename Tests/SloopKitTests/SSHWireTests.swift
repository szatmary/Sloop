// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SSHWireTests: XCTestCase {
    func testReadsBigEndianUInt32() throws {
        var reader = SSHWireReader([0x00, 0x00, 0x01, 0x02])
        XCTAssertEqual(try reader.readUInt32(), 258)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadsLengthPrefixedString() throws {
        var reader = SSHWireReader([0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63])
        XCTAssertEqual(try reader.readString(), [0x61, 0x62, 0x63])
    }

    func testTruncatedUInt32Throws() {
        var reader = SSHWireReader([0x00, 0x00])
        XCTAssertThrowsError(try reader.readUInt32())
    }

    /// A length header claiming more than the buffer holds must fail rather
    /// than allocate — this is the shape of the attack a remote host can
    /// mount on a forwarded agent.
    func testStringLengthBeyondBufferThrows() {
        var reader = SSHWireReader([0xFF, 0xFF, 0xFF, 0xFF, 0x61])
        XCTAssertThrowsError(try reader.readString()) { error in
            XCTAssertEqual(error as? SSHWireError, .lengthExceedsRemaining)
        }
    }

    func testZeroLengthStringIsEmptyNotAnError() throws {
        var reader = SSHWireReader([0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(try reader.readString(), [])
        XCTAssertTrue(reader.isAtEnd)
    }

    func testWriterRoundTripsThroughReader() throws {
        var writer = SSHWireWriter()
        writer.writeByte(12)
        writer.writeUInt32(1)
        writer.writeString(Array("hello".utf8))

        var reader = SSHWireReader(writer.bytes)
        XCTAssertEqual(try reader.readByte(), 12)
        XCTAssertEqual(try reader.readUInt32(), 1)
        XCTAssertEqual(try reader.readString(), Array("hello".utf8))
        XCTAssertTrue(reader.isAtEnd)
    }
}
