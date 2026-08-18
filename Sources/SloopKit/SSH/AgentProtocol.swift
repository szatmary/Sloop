// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Message type numbers from draft-miller-ssh-agent. Fixed by the wire.
enum AgentMessage {
    static let failure: UInt8 = 5
    static let success: UInt8 = 6
    static let requestIdentities: UInt8 = 11
    static let identitiesAnswer: UInt8 = 12
    static let signRequest: UInt8 = 13
    static let signResponse: UInt8 = 14
}

/// Flags a `SIGN_REQUEST` may carry.
public enum AgentSignFlags {
    /// Sign an RSA key with SHA-256 rather than SHA-1.
    public static let rsaSHA2_256: UInt32 = 2
    /// Sign an RSA key with SHA-512 rather than SHA-1.
    public static let rsaSHA2_512: UInt32 = 4
}

public enum AgentProtocolError: Error, Equatable {
    case emptyPayload
    /// A frame header naming more than `AgentFramer.maximumFrameLength`.
    case frameTooLarge(UInt32)
    /// A frame header of zero: there is no message without a type byte.
    case emptyFrame
}

/// Accumulates bytes off the agent channel and hands back one complete
/// message payload at a time.
///
/// The channel is a byte stream, so a read can deliver half a message, three
/// messages, or one and a half. This owns that reassembly so `ForwardedAgent`
/// never has to think about it.
public struct AgentFramer {
    /// The cap OpenSSH's own agent uses. A remote host chooses this number, so
    /// it is checked before a single byte is buffered toward it.
    public static let maximumFrameLength: UInt32 = 262_144

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ chunk: ArraySlice<UInt8>) {
        buffer.append(contentsOf: chunk)
    }

    /// The next complete payload (type byte first, length header stripped), or
    /// nil if one has not fully arrived yet.
    public mutating func nextPayload() throws -> [UInt8]? {
        guard buffer.count >= 4 else { return nil }
        let length = (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16)
            | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])

        guard length > 0 else { throw AgentProtocolError.emptyFrame }
        guard length <= Self.maximumFrameLength else {
            throw AgentProtocolError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + Int(length) else { return nil }

        let payload = Array(buffer[4 ..< 4 + Int(length)])
        buffer.removeFirst(4 + Int(length))
        return payload
    }
}

/// A request from the remote host.
public enum AgentRequest: Equatable {
    case requestIdentities
    case sign(keyBlob: [UInt8], data: [UInt8], flags: UInt32)
    /// A well-formed message this agent does not implement — key management,
    /// locking, extensions. Distinct from a parse failure because the answer
    /// is the same (`FAILURE`) but the cause is not a malformed remote.
    case unsupported(type: UInt8)

    public static func parse(_ payload: [UInt8]) throws -> AgentRequest {
        var reader = SSHWireReader(payload)
        guard !payload.isEmpty else { throw AgentProtocolError.emptyPayload }
        let type = try reader.readByte()

        switch type {
        case AgentMessage.requestIdentities:
            return .requestIdentities
        case AgentMessage.signRequest:
            let blob = try reader.readString()
            let data = try reader.readString()
            let flags = try reader.readUInt32()
            return .sign(keyBlob: blob, data: data, flags: flags)
        default:
            return .unsupported(type: type)
        }
    }
}

/// Framed replies, ready to write to the channel.
public enum AgentResponse {
    public static func identities(_ identities: [AgentIdentity]) -> [UInt8] {
        var body = SSHWireWriter()
        body.writeByte(AgentMessage.identitiesAnswer)
        body.writeUInt32(UInt32(identities.count))
        for identity in identities {
            body.writeString(identity.blob)
            body.writeString(Array(identity.comment.utf8))
        }
        return frame(body.bytes)
    }

    /// A signature blob is itself `string algorithm, string signature` — the
    /// same shape for Ed25519, RSA and ECDSA, because libssh2's signers
    /// already emit the inner bytes each algorithm's wire format expects.
    public static func signature(algorithm: String, signature: [UInt8]) -> [UInt8] {
        var blob = SSHWireWriter()
        blob.writeString(Array(algorithm.utf8))
        blob.writeString(signature)

        var body = SSHWireWriter()
        body.writeByte(AgentMessage.signResponse)
        body.writeString(blob.bytes)
        return frame(body.bytes)
    }

    /// The answer to everything Sloop will not do. A remote SSH client treats
    /// it as "that key didn't work" and moves on, which is exactly what a
    /// refused confirmation should look like.
    public static func failure() -> [UInt8] {
        frame([AgentMessage.failure])
    }

    private static func frame(_ body: [UInt8]) -> [UInt8] {
        var writer = SSHWireWriter()
        writer.writeUInt32(UInt32(body.count))
        return writer.bytes + body
    }
}
