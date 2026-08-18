// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Why a wire read failed. Both cases mean the same thing to a caller —
/// refuse the message — but they are distinct so tests can tell an honest
/// short read from a length header that claims more than exists.
public enum SSHWireError: Error, Equatable {
    /// Fewer bytes remain than the fixed-size field needs.
    case truncated
    /// A length header names more bytes than the buffer holds. On a forwarded
    /// agent this is attacker-supplied, so it must never reach an allocation.
    case lengthExceedsRemaining
}

/// Sequential reader for SSH wire encoding (RFC 4251 §5).
public struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var isAtEnd: Bool { offset >= bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SSHWireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHWireError.truncated }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    public mutating func readString() throws -> [UInt8] {
        let length = try readUInt32()
        // Compare against what is actually here before trusting the header.
        // Widening to Int first: a length near UInt32.max would overflow the
        // addition this check replaces.
        guard Int(length) <= remaining else { throw SSHWireError.lengthExceedsRemaining }
        defer { offset += Int(length) }
        return Array(bytes[offset ..< offset + Int(length)])
    }
}

/// Sequential writer for SSH wire encoding.
public struct SSHWireWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeByte(_ value: UInt8) { bytes.append(value) }

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func writeString(_ value: [UInt8]) {
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }
}
