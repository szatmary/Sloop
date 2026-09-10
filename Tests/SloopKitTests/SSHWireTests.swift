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

    /// Every byte position must be correctly shifted and indexed. Swapping shifts
    /// or indices would pass tests that only exercise zero bytes in certain positions.
    func testReadsEveryBytePositionOfAUInt32() throws {
        var reader = SSHWireReader([0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try reader.readUInt32(), 0x12345678)
    }

    /// The length check must use remaining bytes, not total buffer size. If a reader
    /// has already consumed bytes, a string header claiming more than what's left
    /// must be rejected even if it fits within the original buffer.
    func testStringLengthIsCheckedAgainstRemainingNotBufferSize() throws {
        // 10-byte buffer: first 4 bytes are a UInt32, next 4 are a length header claiming 8 bytes, last 2 are data
        let buffer = [UInt8(0x12), UInt8(0x34), UInt8(0x56), UInt8(0x78),  // first UInt32
                      UInt8(0x00), UInt8(0x00), UInt8(0x00), UInt8(0x08),  // length header: claims 8 bytes
                      UInt8(0x01), UInt8(0x02)]  // only 2 bytes of data available
        var reader = SSHWireReader(buffer)
        _ = try reader.readUInt32()  // consume 4 bytes, leaving 6
        // Now attempt readString: it reads length (4 bytes), leaving 2 bytes remaining
        // but the length header claims 8 bytes, which exceeds remaining (2)
        XCTAssertThrowsError(try reader.readString()) { error in
            XCTAssertEqual(error as? SSHWireError, .lengthExceedsRemaining)
        }
    }
}
