# SSH Agent Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a remote host ask Sloop to sign an SSH authentication challenge with a private key that never leaves the device, with every signature confirmed by the user.

**Architecture:** libssh2 accepts the inbound `auth-agent@openssh.com` channel and hands it to a callback; everything above that is ours. The wire protocol lives in SloopKit (Foundation-only, Linux-testable); signing and channel I/O live in the app target behind `#if canImport(CSSH)`, using libssh2's internal crypto functions because they are the only thing available that reads the OpenSSH private-key container.

**Tech Stack:** Swift 5.9, SloopKit (iOS 17 / macOS 14), libssh2 1.11.1_DEV with the OpenSSL 3 backend, CryptoKit for digests, XCTest.

**Spec:** [`Docs/superpowers/specs/2026-08-18-agent-forwarding-design.md`](../specs/2026-08-18-agent-forwarding-design.md)

## Global Constraints

- **Deployment targets:** iOS 17.0, macOS 14.0. SloopKit is `.v17`. No API newer than that.
- **SloopKit is Foundation-only.** It must compile and test on Linux CI. No `import CryptoKit`, no `import Security`, no `import CSSH` anywhere under `Sources/SloopKit/`.
- **App-target SSH sources are gated** `#if canImport(CSSH)`, matching `LibSSH2Transport.swift:15`. Tests for them are gated the same way.
- **Every file starts with the two-line licence header** used throughout the repo:
  ```swift
  // Sloop — Copyright (C) 2026 Matthew Szatmary
  // GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md
  ```
- **`AuthMethod.agent` is not this feature.** It is dead scaffolding for using a *local* ssh-agent to authenticate, which iOS has no concept of. It is already removed on the unmerged `ssh-url-and-agent` branch. Do not touch it, do not reference it, do not extend it. Nothing in this work reads or writes `AuthMethod`.
- **Refuse rather than guess.** Any malformed, unknown, or unmatched agent request answers `SSH_AGENT_FAILURE (5)`. Never crash, never allocate on an attacker-supplied length, never sign something you could not fully parse.
- **No SHA-1.** A `SIGN_REQUEST` for an `ssh-rsa` blob with neither SHA-2 flag set is refused.
- **Agent protocol constants** (from draft-miller-ssh-agent, and fixed by the wire):
  | Name | Value |
  |---|---|
  | `SSH_AGENT_FAILURE` | 5 |
  | `SSH_AGENT_SUCCESS` | 6 |
  | `SSH_AGENTC_REQUEST_IDENTITIES` | 11 |
  | `SSH_AGENT_IDENTITIES_ANSWER` | 12 |
  | `SSH_AGENTC_SIGN_REQUEST` | 13 |
  | `SSH_AGENT_SIGN_RESPONSE` | 14 |
  | `SSH_AGENT_RSA_SHA2_256` (flag) | 2 |
  | `SSH_AGENT_RSA_SHA2_512` (flag) | 4 |
- **SSH wire types:** `byte` = 1 byte; `uint32` = 4 bytes big-endian; `string` = `uint32` length followed by exactly that many bytes. A frame is a `uint32` length followed by a payload whose first byte is the message type.
- **Test commands** (all verified working in this worktree before Task 4 was dispatched):
  - SloopKit: `swift test --filter <TestClass>`, or bare `swift test` for the full suite.
  - App target: `xcodegen generate --spec project.ssh.yml`, then
    ```bash
    xcodebuild test -scheme Sloop_macOS -destination 'platform=macOS' \
      -skipPackagePluginValidation \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""
    ```
    **The signing overrides are required.** Without them the build fails with
    `"Sloop_macOS" requires a provisioning profile` — the target sets
    `CODE_SIGN_ENTITLEMENTS` and `ENABLE_HARDENED_RUNTIME` for release
    signing, and no profile is configured in this environment. This is not a
    code problem and must not be "fixed" by editing the project's signing
    settings.
  - `Vendor/libssh2.xcframework` is gitignored and already present in this
    worktree. If it goes missing, rebuild with `Scripts/build-libssh2.sh` or
    copy it from the main checkout.
  - Baseline before Task 4: SloopKit 258 tests pass; app target 25 tests pass.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/SloopKit/SSH/SSHWire.swift` | Bounds-checked reader/writer for SSH wire primitives. | 1 |
| `Sources/SloopKit/SSH/AgentProtocol.swift` | Frame accumulation, request parsing, response building. | 2 |
| `Sources/SloopKit/SSH/AgentIdentity.swift` | One exposed key: algorithm, public blob, comment, source key name. | 2 |
| `Sources/SloopKit/Model/SSHHost.swift` | Gains `forwardedKeys: [String]`. | 3 |
| `Sources/SloopKit/Model/KeyLibrary.swift` | Resolves selected names to `NamedKey`s. | 3 |
| `App/Sloop/SSH/Sloop-Bridging-Header.h` | Includes the internal prototypes; guard + comment fix. | 4 |
| `project.ssh.yml` | Sets `SWIFT_OBJC_BRIDGING_HEADER`. | 4 |
| `App/Sloop/SSH/libssh2-internal.h` | Prototypes for libssh2's internal crypto. | 4 |
| `App/Sloop/SSH/AgentSigner.swift` | Blob → key → signature. | 5 |
| `App/Sloop/SSH/AgentSignPrompter.swift` | Per-signature confirmation. | 6 |
| `App/Sloop/Views/AgentSignPromptView.swift` | The confirmation sheet. | 6 |
| `App/Sloop/SSH/ForwardedAgent.swift` | Owns the agent channel; drives protocol + signer. | 7 |
| `App/Sloop/SSH/LibSSH2Transport.swift` | Requests forwarding, routes the callback, services two channels. | 7 |
| `App/Sloop/Views/HostEditView.swift` | The per-host key checklist. | 8 |

---

### Task 1: SSH wire primitives

The parsing bugs that matter live here — truncation and attacker-supplied lengths — so this gets its own tests before anything is built on it.

**Files:**
- Create: `Sources/SloopKit/SSH/SSHWire.swift`
- Test: `Tests/SloopKitTests/SSHWireTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SSHWireReader` (`init(_ bytes: [UInt8])`, `mutating func readByte() throws -> UInt8`, `readUInt32() throws -> UInt32`, `readString() throws -> [UInt8]`, `var isAtEnd: Bool`), `SSHWireWriter` (`init()`, `mutating func writeByte(_:)`, `writeUInt32(_:)`, `writeString(_:)`, `var bytes: [UInt8]`), `enum SSHWireError: Error { case truncated, lengthExceedsRemaining }`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter SSHWireTests`
Expected: FAIL — `cannot find 'SSHWireReader' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter SSHWireTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/SSH/SSHWire.swift Tests/SloopKitTests/SSHWireTests.swift
git commit -m "SloopKit: bounds-checked SSH wire reader and writer"
```

---

### Task 2: Agent protocol — framing, requests, responses

**Files:**
- Create: `Sources/SloopKit/SSH/AgentProtocol.swift`, `Sources/SloopKit/SSH/AgentIdentity.swift`
- Test: `Tests/SloopKitTests/AgentProtocolTests.swift`

**Interfaces:**
- Consumes: `SSHWireReader`, `SSHWireWriter`, `SSHWireError` from Task 1.
- Produces:
  - `struct AgentIdentity { let keyName: String; let algorithm: String; let blob: [UInt8]; var comment: String }`
  - `enum AgentRequest: Equatable { case requestIdentities; case sign(keyBlob: [UInt8], data: [UInt8], flags: UInt32); case unsupported(type: UInt8) }`
  - `static func AgentRequest.parse(_ payload: [UInt8]) throws -> AgentRequest`
  - `struct AgentFramer { mutating func append(_ chunk: ArraySlice<UInt8>); mutating func nextPayload() throws -> [UInt8]?; static let maximumFrameLength = 262_144 }`
  - `enum AgentResponse { static func identities(_:) -> [UInt8]; static func signature(algorithm:signature:) -> [UInt8]; static func failure() -> [UInt8] }` — each returns a **framed** message ready to write to the channel.
  - `enum AgentSignFlags { static let rsaSHA2_256: UInt32 = 2; static let rsaSHA2_512: UInt32 = 4 }`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter AgentProtocolTests`
Expected: FAIL — `cannot find 'AgentFramer' in scope`.

- [ ] **Step 3: Write `AgentIdentity.swift`**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One key exposed to a forwarded agent.
///
/// `blob` is the wire-format public key — the same bytes as the base64 middle
/// field of an OpenSSH `.pub` line — and is what a `SIGN_REQUEST` names when
/// it asks for a signature. `keyName` is the library name it was derived from,
/// which is how a signature request gets back to a private key.
public struct AgentIdentity: Equatable {
    public let keyName: String
    public let algorithm: String
    public let blob: [UInt8]
    public var comment: String

    public init(keyName: String, algorithm: String, blob: [UInt8], comment: String) {
        self.keyName = keyName
        self.algorithm = algorithm
        self.blob = blob
        self.comment = comment
    }
}
```

- [ ] **Step 4: Write `AgentProtocol.swift`**

```swift
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
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --filter AgentProtocolTests`
Expected: PASS, 12 tests.

- [ ] **Step 6: Run the whole SloopKit suite**

Run: `swift test`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add Sources/SloopKit/SSH/AgentProtocol.swift Sources/SloopKit/SSH/AgentIdentity.swift Tests/SloopKitTests/AgentProtocolTests.swift
git commit -m "SloopKit: SSH agent protocol framing, requests and responses"
```

---

### Task 3: Per-host forwarded key selection

**Files:**
- Modify: `Sources/SloopKit/Model/SSHHost.swift`
- Modify: `Sources/SloopKit/Model/KeyLibrary.swift`
- Test: `Tests/SloopKitTests/ForwardedKeysTests.swift`

**Interfaces:**
- Consumes: `NamedKey`, `KeyStore` (existing).
- Produces: `SSHHost.forwardedKeys: [String]`, `SSHHost.forwardsAgent: Bool` (computed, `!forwardedKeys.isEmpty`), and `KeyLibrary.forwardedKeys(for:keys:) throws -> [NamedKey]`.

Read `Sources/SloopKit/Model/KeyLibrary.swift` before starting. Note its shape: it is an `enum` used as a namespace of **static** functions taking their stores as parameters (`credential(for:keys:credentials:)`), **not** a class holding a store. The new function follows that pattern exactly — static, with `keys: KeyStore` passed in. There is no `KeyLibrary` instance to create.

- [ ] **Step 1: Write the failing tests**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class ForwardedKeysTests: XCTestCase {
    private func host(forwarding names: [String] = []) -> SSHHost {
        var host = SSHHost(alias: "a", hostname: "h", username: "u")
        host.forwardedKeys = names
        return host
    }

    func testForwardingIsOffByDefault() {
        XCTAssertEqual(SSHHost(alias: "a", hostname: "h", username: "u").forwardedKeys, [])
        XCTAssertFalse(SSHHost(alias: "a", hostname: "h", username: "u").forwardsAgent)
    }

    func testSelectingAKeyTurnsForwardingOn() {
        XCTAssertTrue(host(forwarding: ["id_ed25519"]).forwardsAgent)
    }

    /// Host files written before this field existed must still decode, and
    /// must decode as "not forwarding" rather than failing. HostStore keeps
    /// records it cannot decode, but a whole-fleet decode failure here would
    /// hide every host behind a bug of our own making.
    func testHostWrittenBeforeThisFieldDecodesWithForwardingOff() throws {
        let json = """
        {"id":"\(UUID().uuidString)","alias":"a","hostname":"h","port":22,
         "username":"u","auth":{"password":{}},"useMosh":false}
        """
        let decoded = try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.forwardedKeys, [])
    }

    func testForwardedKeysRoundTrip() throws {
        let original = host(forwarding: ["a", "b"])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SSHHost.self, from: data).forwardedKeys, ["a", "b"])
    }

    func testResolvesSelectedNamesToLibraryKeys() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))
        try store.setKey(NamedKey(name: "b", privateKeyPEM: "PEM-B"))

        let resolved = try KeyLibrary.forwardedKeys(for: host(forwarding: ["b"]), keys: store)
        XCTAssertEqual(resolved.map(\.name), ["b"])
        XCTAssertEqual(resolved.first?.privateKeyPEM, "PEM-B")
    }

    /// Selection order is the user's, and the identity list a remote sees
    /// should follow it rather than the store's alphabetical order.
    func testResolvedKeysFollowSelectionOrderNotStoreOrder() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))
        try store.setKey(NamedKey(name: "b", privateKeyPEM: "PEM-B"))

        XCTAssertEqual(try KeyLibrary.forwardedKeys(for: host(forwarding: ["b", "a"]),
                                                    keys: store).map(\.name),
                       ["b", "a"])
    }

    /// A name with no key behind it is dropped, not fatal. The key may have
    /// been deleted from the library after the host was configured, and that
    /// must not make the host unusable — it forwards what still exists.
    func testMissingKeyNamesAreDropped() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))

        XCTAssertEqual(try KeyLibrary.forwardedKeys(for: host(forwarding: ["a", "gone"]),
                                                    keys: store).map(\.name),
                       ["a"])
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --filter ForwardedKeysTests`
Expected: FAIL — `value of type 'SSHHost' has no member 'forwardedKeys'`.

- [ ] **Step 3: Add the field to `SSHHost`**

Add the stored property after `onConnectCommand` (line 54):

```swift
    /// Names of library keys this host's forwarded agent may use. Empty means
    /// no forwarding at all.
    ///
    /// One list rather than a `Bool` plus a list: those two can disagree, and
    /// the disagreement that matters — forwarding "on" with nothing selected,
    /// or "off" with keys still listed — is exactly the state that would make
    /// the UI and the wire tell different stories.
    public var forwardedKeys: [String]
```

Add to `init`, as the last parameter, defaulted:

```swift
                onConnectCommand: String? = nil,
                forwardedKeys: [String] = []) {
```
```swift
        self.onConnectCommand = onConnectCommand
        self.forwardedKeys = forwardedKeys
```

Add to `CodingKeys`:

```swift
        case onConnectCommand, forwardedKeys
```

Add to `init(from:)`, after `onConnectCommand`:

```swift
        // decodeIfPresent, like connectionMethod above: host files written
        // before this field existed decode as "not forwarding".
        forwardedKeys = try c.decodeIfPresent([String].self, forKey: .forwardedKeys) ?? []
```

Add the computed property beside `trimmedOnConnectCommand`:

```swift
    /// Whether this host forwards an agent at all. Derived, never stored, so
    /// it cannot contradict the selection.
    public var forwardsAgent: Bool { !forwardedKeys.isEmpty }
```

- [ ] **Step 4: Add the resolver to `KeyLibrary`**

```swift
    /// The library keys this host exposes to a forwarded agent, in the order
    /// they were selected. Names with no key behind them are dropped: a key
    /// deleted from the library after the host was configured should cost that
    /// one identity, not the whole connection.
    ///
    /// Throws if the store can't be read, like `credential(for:keys:credentials:)`
    /// above and for the same reason: an unreadable library and an empty one are
    /// not the same answer, and reporting the first as the second would silently
    /// forward nothing.
    public static func forwardedKeys(for host: SSHHost, keys: KeyStore) throws -> [NamedKey] {
        try host.forwardedKeys.compactMap { try keys.key(named: $0) }
    }
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `swift test --filter ForwardedKeysTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run the whole SloopKit suite**

Run: `swift test`
Expected: PASS. `SSHHost` is constructed in many tests; the new parameter is defaulted, so none should need changing. If any fail to compile, the default is missing.

- [ ] **Step 7: Commit**

```bash
git add Sources/SloopKit/Model/SSHHost.swift Sources/SloopKit/Model/KeyLibrary.swift Tests/SloopKitTests/ForwardedKeysTests.swift
git commit -m "SloopKit: per-host selection of keys a forwarded agent may use"
```

---

### Task 4: Build wiring for libssh2's internal crypto

No behavior yet — this makes the internal functions reachable from Swift and fixes the stale claim that hid the problem. It must land before Task 5 compiles.

**Files:**
- Create: `App/Sloop/SSH/libssh2-internal.h`
- Modify: `App/Sloop/SSH/Sloop-Bridging-Header.h`
- Modify: `project.ssh.yml`

**Interfaces:**
- Produces: the C functions listed below, visible to Swift in the SSH and Mosh build variants.

- [ ] **Step 1: Write `App/Sloop/SSH/libssh2-internal.h`**

```c
//
//  libssh2-internal.h
//  Sloop
//
//  Prototypes for libssh2 functions that are NOT part of its public API.
//  They are declared in libssh2's own src/crypto.h, which xcframeworks do not
//  ship, and they are linkable because the static library exports them.
//
//  Why depend on internals at all: agent forwarding has to sign with keys the
//  user imported, and modern ssh-keygen writes them in the OpenSSH container
//  format ("BEGIN OPENSSH PRIVATE KEY"). Neither CryptoKit, nor Security, nor
//  OpenSSL itself reads that container — libssh2 does, and it is already the
//  code path that authenticates every key-auth host today.
//
//  The risk this takes on: these signatures can change between libssh2
//  releases with no deprecation, because they were never public. The tripwire
//  is AgentSignerTests, which signs and then verifies through libssh2's own
//  verify functions — a drifted prototype fails the suite instead of shipping
//  signatures that remotes silently reject.
//

#ifndef LIBSSH2_INTERNAL_H
#define LIBSSH2_INTERNAL_H

#include <libssh2.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque to us. Under USE_OPENSSL_3 — which this build uses — all three are
   EVP_PKEY, and libssh2's own _libssh2_{rsa,ed25519,ecdsa}_free macros all
   expand to EVP_PKEY_free (openssl.h:341-347, 364-372). Those are macros, not
   symbols, so they cannot be linked; the free function is declared below and
   called directly. */
typedef void libssh2_ed25519_ctx;
typedef void libssh2_rsa_ctx;
typedef void libssh2_ecdsa_ctx;

/* Releases a key context from any of the *_new_private_frommemory calls.
   OpenSSL's, not libssh2's, but exported from the same static library. */
void EVP_PKEY_free(void *pkey);

/* Derives the algorithm name and wire-format public key blob from a private
   key in memory. This is how libssh2_userauth_publickey_frommemory works when
   the caller supplies no public key, and it is why Sloop needs no key
   derivation of its own on iOS, where imported keys have no .pub file. */
int _libssh2_pub_priv_keyfilememory(LIBSSH2_SESSION *session,
                                    unsigned char **method, size_t *method_len,
                                    unsigned char **pubkeydata, size_t *pubkeydata_len,
                                    const char *privatekeydata, size_t privatekeydata_len,
                                    const char *passphrase);

int _libssh2_ed25519_new_private_frommemory(libssh2_ed25519_ctx **ctx,
                                            LIBSSH2_SESSION *session,
                                            const char *filedata, size_t filedata_len,
                                            unsigned const char *passphrase);
int _libssh2_ed25519_sign(libssh2_ed25519_ctx *ctx, LIBSSH2_SESSION *session,
                          uint8_t **out_sig, size_t *out_sig_len,
                          const uint8_t *message, size_t message_len);
int _libssh2_ed25519_verify(libssh2_ed25519_ctx *ctx, const uint8_t *s,
                            size_t s_len, const uint8_t *m, size_t m_len);

int _libssh2_rsa_new_private_frommemory(libssh2_rsa_ctx **rsa,
                                        LIBSSH2_SESSION *session,
                                        const char *filedata, size_t filedata_len,
                                        unsigned const char *passphrase);
int _libssh2_rsa_sha2_sign(LIBSSH2_SESSION *session, libssh2_rsa_ctx *rsactx,
                           const unsigned char *hash, size_t hash_len,
                           unsigned char **signature, size_t *signature_len);
int _libssh2_rsa_sha2_verify(libssh2_rsa_ctx *rsa, size_t hash_len,
                             const unsigned char *sig, size_t sig_len,
                             const unsigned char *m, size_t m_len);

int _libssh2_ecdsa_new_private_frommemory(libssh2_ecdsa_ctx **ctx,
                                          LIBSSH2_SESSION *session,
                                          const char *filedata, size_t filedata_len,
                                          unsigned const char *passphrase);
int _libssh2_ecdsa_sign(LIBSSH2_SESSION *session, libssh2_ecdsa_ctx *ctx,
                        const unsigned char *hash, size_t hash_len,
                        unsigned char **signature, size_t *signature_len);
int _libssh2_ecdsa_verify(libssh2_ecdsa_ctx *ctx,
                          const unsigned char *r, size_t r_len,
                          const unsigned char *s, size_t s_len,
                          const unsigned char *m, size_t m_len);

#ifdef __cplusplus
}
#endif

#endif /* LIBSSH2_INTERNAL_H */
```

Note: `_libssh2_rsa_sha2_verify` and `_libssh2_ecdsa_verify` parameter orders were read from `crypto.h`. Before relying on them in Task 5, re-read
`/Users/matthewszatmary/Projects/Sloop/.native/libssh2/src/crypto.h` and correct these declarations to match exactly — a wrong order compiles and then misbehaves at runtime.

- [ ] **Step 2: Update `Sloop-Bridging-Header.h`**

Replace the whole file with:

```c
//
//  Sloop-Bridging-Header.h
//  Sloop
//
//  Objective-C → Swift bridge. project.ssh.yml and project.mosh.yml both set
//  SWIFT_OBJC_BRIDGING_HEADER to this file, so these C symbols are visible to
//  Swift in the SSH-enabled variants and nowhere else — matching the
//  `#if canImport(CSSH)` gate used across the SSH sources.
//
//  Each include is guarded, because the variants layer: the SSH build has
//  libssh2 but no mosh and no tailscale. They cannot be module maps —
//  libssh2.xcframework already ships one, and Xcode copies every xcframework's
//  headers into a single include/ directory where two module.modulemap files
//  collide.
//

#if __has_include("MoshBridge.h")
#import "MoshBridge.h"
#endif

#if __has_include(<libssh2.h>)
#import "libssh2-internal.h"
#endif

#if __has_include(<tailscale.h>)
#include <tailscale.h>
#endif
```

- [ ] **Step 3: Set the bridging header in `project.ssh.yml`**

Replace the `targets:` block:

```yaml
targets:
  Sloop_iOS:
    dependencies:
      - framework: Vendor/libssh2.xcframework
        embed: false
    settings:
      base:
        # Without this, libssh2-internal.h is invisible to Swift and agent
        # forwarding compiles only in the Mosh variant. project.mosh.yml sets
        # the same value; it layers on top of this spec, so the two agree.
        SWIFT_OBJC_BRIDGING_HEADER: App/Sloop/SSH/Sloop-Bridging-Header.h
  Sloop_macOS:
    dependencies:
      - framework: Vendor/libssh2.xcframework
        embed: false
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: App/Sloop/SSH/Sloop-Bridging-Header.h
```

- [ ] **Step 4: Verify both variants still generate and build**

```bash
xcodegen generate --spec project.ssh.yml
xcodebuild build -scheme Sloop_macOS -destination 'platform=macOS' -skipPackagePluginValidation
```
Expected: build succeeds. If `Vendor/libssh2.xcframework` is absent, build it with `Scripts/build-libssh2.sh` or copy it from the main checkout first.

Then confirm the plain (no-SSH) variant is untouched:
```bash
xcodegen generate
xcodebuild build -scheme Sloop_macOS -destination 'platform=macOS' -skipPackagePluginValidation
```
Expected: build succeeds — no bridging header, no libssh2, `canImport(CSSH)` false.

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/SSH/libssh2-internal.h App/Sloop/SSH/Sloop-Bridging-Header.h project.ssh.yml
git commit -m "Build: reach libssh2's internal crypto from the SSH variant

The bridging header claimed project.ssh.yml set SWIFT_OBJC_BRIDGING_HEADER.
Only project.mosh.yml did. Nothing noticed because the header's contents were
the Mosh and Tailscale surfaces, used only where it was set."
```

---

### Task 5: AgentSigner

**Files:**
- Create: `App/Sloop/SSH/AgentSigner.swift`
- Test: `Tests/SloopAppTests/AgentSignerTests.swift`

**Interfaces:**
- Consumes: `AgentIdentity` (Task 2), `NamedKey`, the C functions from Task 4.
- Produces:
  ```swift
  final class AgentSigner {
      init(session: OpaquePointer, keys: [NamedKey])
      var identities: [AgentIdentity] { get }        // derived once at init
      func identity(matching blob: [UInt8]) -> AgentIdentity?
      func sign(identity: AgentIdentity, data: [UInt8], flags: UInt32) throws -> (algorithm: String, signature: [UInt8])
      enum SignError: Error { case unsupportedAlgorithm(String), sha1Refused, keyUnreadable(String), signingFailed(Int32) }
  }
  ```

Whole file wrapped in `#if canImport(CSSH)` / `#endif`.

- [ ] **Step 1: Write the failing tests**

Generate a real key pair per algorithm at test time with `ssh-keygen` into a temp directory (macOS test host, so it is available). Sign, then verify through libssh2's own verify function — the point is proving the signature is real, not non-empty.

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
import SloopKit

#if canImport(CSSH)
import CSSH

final class AgentSignerTests: XCTestCase {
    private var session: OpaquePointer!

    override func setUpWithError() throws {
        XCTAssertEqual(libssh2_init(0), 0)
        session = libssh2_session_init_ex(nil, nil, nil, nil)
        XCTAssertNotNil(session)
    }

    override func tearDownWithError() throws {
        if let session { libssh2_session_free(session) }
        libssh2_exit()
    }

    /// Writes a real key with ssh-keygen and returns its PEM.
    private func generateKey(type: String, bits: String? = nil) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var args = ["-q", "-t", type, "-N", "", "-C", "test", "-f", path.path]
        if let bits { args += ["-b", bits] }
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "ssh-keygen failed for \(type)")

        return try String(contentsOf: path, encoding: .utf8)
    }

    private func signer(pem: String, name: String = "k") -> AgentSigner {
        AgentSigner(session: session, keys: [NamedKey(name: name, privateKeyPEM: pem)])
    }

    func testDerivesAnIdentityWithoutAStoredPublicKey() throws {
        // The iOS import path stores no .pub; the blob must come from the
        // private key alone or forwarding exposes nothing on iPad.
        let signer = signer(pem: try generateKey(type: "ed25519"))
        XCTAssertEqual(signer.identities.count, 1)
        XCTAssertEqual(signer.identities.first?.algorithm, "ssh-ed25519")
        XCTAssertFalse(signer.identities.first?.blob.isEmpty ?? true)
        XCTAssertEqual(signer.identities.first?.keyName, "k")
    }

    func testEd25519SignatureVerifies() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: 0)
        XCTAssertEqual(algorithm, "ssh-ed25519")
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature, message: message))
    }

    func testRSASignatureVerifiesForBothSHA2Sizes() throws {
        let signer = signer(pem: try generateKey(type: "rsa", bits: "2048"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        for (flag, expected) in [(AgentSignFlags.rsaSHA2_256, "rsa-sha2-256"),
                                 (AgentSignFlags.rsaSHA2_512, "rsa-sha2-512")] {
            let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: flag)
            XCTAssertEqual(algorithm, expected)
            XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature,
                                                  message: message, flags: flag))
        }
    }

    func testECDSASignatureVerifies() throws {
        let signer = signer(pem: try generateKey(type: "ecdsa", bits: "256"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: 0)
        XCTAssertEqual(algorithm, "ecdsa-sha2-nistp256")
        XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature, message: message))
    }

    /// Bare ssh-rsa is SHA-1 signed and rejected by OpenSSH 8.8+. There is no
    /// reason for a 2026 client to have that code path at all.
    func testRSAWithNoSHA2FlagIsRefused() throws {
        let signer = signer(pem: try generateKey(type: "rsa", bits: "2048"))
        let identity = try XCTUnwrap(signer.identities.first)
        XCTAssertThrowsError(try signer.sign(identity: identity,
                                             data: Array("x".utf8), flags: 0))
    }

    func testUnknownBlobMatchesNothing() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        XCTAssertNil(signer.identity(matching: [0x00, 0x01, 0x02]))
    }

    func testMatchingIsByExactBlob() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        XCTAssertEqual(signer.identity(matching: identity.blob)?.keyName, "k")
    }
}
#endif
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
xcodegen generate --spec project.ssh.yml
xcodebuild test -scheme Sloop_macOS -destination 'platform=macOS' -skipPackagePluginValidation
```
Expected: FAIL — `cannot find 'AgentSigner' in scope`.

- [ ] **Step 3: Write `AgentSigner.swift`**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Signing for a forwarded agent. Compiles only where libssh2 does, like every
// other file in this directory.
#if canImport(CSSH)
import Foundation
import CryptoKit
import CSSH
import SloopKit

/// Turns a signature request into a signature, using libssh2's own crypto.
///
/// Every key type takes the same three steps — parse the private key from
/// memory, hash if the algorithm wants a digest, sign — and produces the same
/// wire shape. See `Docs/superpowers/specs/2026-08-18-agent-forwarding-design.md`
/// for why libssh2's internals rather than CryptoKit or OpenSSL.
final class AgentSigner {
    enum SignError: Error {
        case unsupportedAlgorithm(String)
        /// A bare `ssh-rsa` request. SHA-1; refused on purpose.
        case sha1Refused
        case keyUnreadable(String)
        case signingFailed(Int32)
    }

    private let session: OpaquePointer
    private let keysByName: [String: NamedKey]
    private(set) var identities: [AgentIdentity] = []

    /// Derives an identity per key up front. A key the crypto cannot read is
    /// dropped rather than fatal: it simply is not offered, and the others
    /// still work.
    init(session: OpaquePointer, keys: [NamedKey]) {
        self.session = session
        self.keysByName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
        self.identities = keys.compactMap { Self.identity(session: session, key: $0) }
    }

    func identity(matching blob: [UInt8]) -> AgentIdentity? {
        identities.first { $0.blob == blob }
    }

    // MARK: Identity derivation

    private static func identity(session: OpaquePointer, key: NamedKey) -> AgentIdentity? {
        var method: UnsafeMutablePointer<UInt8>?
        var methodLength = 0
        var blob: UnsafeMutablePointer<UInt8>?
        var blobLength = 0

        let rc = key.privateKeyPEM.withCString { pemPtr in
            withOptionalPassphrase(key.passphrase) { passPtr in
                _libssh2_pub_priv_keyfilememory(session,
                                                &method, &methodLength,
                                                &blob, &blobLength,
                                                pemPtr, key.privateKeyPEM.utf8.count,
                                                passPtr)
            }
        }
        defer {
            if let method { free(method) }
            if let blob { free(blob) }
        }
        guard rc == 0, let method, let blob else { return nil }

        let algorithm = String(decoding: UnsafeBufferPointer(start: method, count: methodLength),
                               as: UTF8.self)
        return AgentIdentity(keyName: key.name,
                             algorithm: algorithm,
                             blob: Array(UnsafeBufferPointer(start: blob, count: blobLength)),
                             comment: key.name)
    }

    // MARK: Signing

    func sign(identity: AgentIdentity,
              data: [UInt8],
              flags: UInt32) throws -> (algorithm: String, signature: [UInt8]) {
        guard let key = keysByName[identity.keyName] else {
            throw SignError.keyUnreadable(identity.keyName)
        }

        switch identity.algorithm {
        case "ssh-ed25519":
            // Ed25519 hashes internally; it signs the message itself.
            return ("ssh-ed25519", try signEd25519(key: key, message: data))

        case "ssh-rsa":
            if flags & AgentSignFlags.rsaSHA2_512 != 0 {
                return ("rsa-sha2-512",
                        try signRSA(key: key, hash: Array(SHA512.hash(data: data))))
            }
            if flags & AgentSignFlags.rsaSHA2_256 != 0 {
                return ("rsa-sha2-256",
                        try signRSA(key: key, hash: Array(SHA256.hash(data: data))))
            }
            throw SignError.sha1Refused

        case "ecdsa-sha2-nistp256":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA256.hash(data: data))))
        case "ecdsa-sha2-nistp384":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA384.hash(data: data))))
        case "ecdsa-sha2-nistp521":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA512.hash(data: data))))

        default:
            throw SignError.unsupportedAlgorithm(identity.algorithm)
        }
    }

    private func signEd25519(key: NamedKey, message: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_ed25519_new_private_frommemory(ctx, self.session, pem,
                                                    key.privateKeyPEM.utf8.count, pass)
        }
        // Without this the private key leaks on every signature — the one
        // allocation in the app that holds key material.
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        // Ed25519 takes the message, not a digest — it hashes internally.
        let rc = message.withUnsafeBufferPointer { messagePtr in
            _libssh2_ed25519_sign(ctx, session, &signature, &length,
                                  messagePtr.baseAddress, message.count)
        }
        return try collect(rc: rc, signature: signature, length: length)
    }

    private func signRSA(key: NamedKey, hash: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_rsa_new_private_frommemory(ctx, self.session, pem,
                                                key.privateKeyPEM.utf8.count, pass)
        }
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        // libssh2 picks SHA-256 vs SHA-512 from hash_len, so the digest the
        // caller chose from the request flags is what decides the algorithm.
        let rc = hash.withUnsafeBufferPointer { hashPtr in
            _libssh2_rsa_sha2_sign(session, ctx, hashPtr.baseAddress, hash.count,
                                   &signature, &length)
        }
        return try collect(rc: rc, signature: signature, length: length)
    }

    private func signECDSA(key: NamedKey, hash: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_ecdsa_new_private_frommemory(ctx, self.session, pem,
                                                  key.privateKeyPEM.utf8.count, pass)
        }
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = hash.withUnsafeBufferPointer { hashPtr in
            _libssh2_ecdsa_sign(session, ctx, hashPtr.baseAddress, hash.count,
                                &signature, &length)
        }
        // libssh2 emits mpint r ‖ mpint s here, which is already the inner
        // payload an ECDSA signature blob carries — no reformatting.
        return try collect(rc: rc, signature: signature, length: length)
    }

    /// Loads a private key through one of libssh2's `*_new_private_frommemory`
    /// functions. They share a shape — `(ctx**, session, pem, pem_len,
    /// passphrase)` — so the three signers differ only in which one they name.
    ///
    /// The passphrase parameter is `unsigned const char *` on these three but
    /// plain `const char *` on `_libssh2_pub_priv_keyfilememory`, which is why
    /// the rebinding happens here rather than in a shared helper.
    private func loadKey(
        _ key: NamedKey,
        _ load: (UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                 UnsafePointer<CChar>,
                 UnsafePointer<UInt8>?) -> Int32
    ) throws -> UnsafeMutableRawPointer {
        var ctx: UnsafeMutableRawPointer?
        let rc = key.privateKeyPEM.withCString { pemPtr -> Int32 in
            guard let passphrase = key.passphrase else { return load(&ctx, pemPtr, nil) }
            return passphrase.withCString { passPtr in
                load(&ctx, pemPtr,
                     UnsafeRawPointer(passPtr).assumingMemoryBound(to: UInt8.self))
            }
        }
        guard rc == 0, let ctx else { throw SignError.keyUnreadable(key.name) }
        return ctx
    }
```

**Every caller of `loadKey` must free the context.** Each signing function
takes `defer { EVP_PKEY_free(ctx) }` immediately after the `loadKey` call —
without it, a private key is leaked on every signature, and this is the one
allocation in the app that holds key material. Under `USE_OPENSSL_3` all three
context types are `EVP_PKEY`, so one free covers them; confirm the flag is set
in the vendored build before relying on it:

```bash
grep -rn "USE_OPENSSL_3" Scripts/build-libssh2.sh .native/libssh2/src/openssl.h | head
```

```swift

    private func collect(rc: Int32,
                         signature: UnsafeMutablePointer<UInt8>?,
                         length: Int) throws -> [UInt8] {
        guard rc == 0, let signature else { throw SignError.signingFailed(rc) }
        defer { free(signature) }
        return Array(UnsafeBufferPointer(start: signature, count: length))
    }
}

/// Runs `body` with a C string for the passphrase, or NULL when there is none.
/// libssh2 treats NULL and "" differently for some key formats.
private func withOptionalPassphrase<T>(_ passphrase: String?,
                                       _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let passphrase else { return body(nil) }
    return passphrase.withCString { body($0) }
}
#endif
```

- [ ] **Step 4: Add the test-only verify helper**

Verification exists to prove the signatures are real and to catch prototype drift, so it lives beside the signer but is marked as the test affordance it is. Append inside the `AgentSigner` class:

```swift
    /// Verifies a signature through libssh2's own verify functions.
    ///
    /// Test-only, and deliberately so: nothing in the app verifies its own
    /// signatures. It exists because `libssh2-internal.h` declares prototypes
    /// libssh2 never promised to keep — if one drifts, this fails loudly in
    /// CI instead of producing signatures that remotes silently reject.
    func verifyForTesting(identity: AgentIdentity,
                          signature: [UInt8],
                          message: [UInt8],
                          flags: UInt32 = 0) -> Bool
```

Implement it by loading the key the same way `sign` does and calling the matching `_libssh2_*_verify`. For ECDSA, split the `mpint r ‖ mpint s` buffer back into `r` and `s` with `SSHWireReader` before calling `_libssh2_ecdsa_verify`.

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
xcodebuild test -scheme Sloop_macOS -destination 'platform=macOS' -skipPackagePluginValidation
```
Expected: PASS, 7 tests in `AgentSignerTests`.

- [ ] **Step 6: Commit**

```bash
git add App/Sloop/SSH/AgentSigner.swift Tests/SloopAppTests/AgentSignerTests.swift
git commit -m "SSH: sign agent challenges with library keys via libssh2's crypto"
```

---

### Task 6: The confirmation prompt

**Files:**
- Create: `App/Sloop/SSH/AgentSignPrompter.swift`, `App/Sloop/Views/AgentSignPromptView.swift`
- Modify: `App/Sloop/Views/HostListView.swift` — present the sheet (Step 5). Omitting this deadlocks the SSH thread; see that step.
- Test: `Tests/SloopAppTests/AgentSignPrompterTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `protocol AgentSignConfirming { func shouldSign(keyName: String, endpoint: String) -> Bool }` and `final class AgentSignPrompter: AgentSignConfirming`.

Read `App/Sloop/SSH/HostKeyPrompter.swift` in full first. This mirrors it — same semaphore handoff, same threading contract, same doc-comment obligation. Do not invent a different pattern.

- [ ] **Step 1: Write the failing tests**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS

final class AgentSignPrompterTests: XCTestCase {
    /// The SSH thread must not proceed until the user has answered, and must
    /// see the answer they gave. This is the whole point of the type.
    func testBlocksTheCallingThreadUntilAnswered() {
        let prompter = AgentSignPrompter(present: { _, _, respond in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { respond(true) }
        })

        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            XCTAssertTrue(prompter.shouldSign(keyName: "id_ed25519", endpoint: "h:22"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
    }

    func testRefusalIsReportedAsRefusal() {
        let prompter = AgentSignPrompter(present: { _, _, respond in respond(false) })
        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            XCTAssertFalse(prompter.shouldSign(keyName: "k", endpoint: "h:22"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
    }

    func testKeyNameAndEndpointReachThePrompt() {
        // The user cannot judge a signing request without both: which key is
        // being used, and who is asking.
        var seen: (String, String)?
        let prompter = AgentSignPrompter(present: { key, endpoint, respond in
            seen = (key, endpoint)
            respond(false)
        })
        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            _ = prompter.shouldSign(keyName: "id_ed25519", endpoint: "example.com:22")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(seen?.0, "id_ed25519")
        XCTAssertEqual(seen?.1, "example.com:22")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `xcodebuild test -scheme Sloop_macOS -destination 'platform=macOS' -skipPackagePluginValidation`
Expected: FAIL — `cannot find 'AgentSignPrompter' in scope`.

- [ ] **Step 3: Write `AgentSignPrompter.swift`**

Structurally identical to `HostKeyPrompter`, down to the `Decision` box and the comment explaining it. The one addition is the injectable `present` closure, so the tests above need no UI.

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI

/// Asks the user whether a forwarded agent may sign with a given key.
protocol AgentSignConfirming {
    /// Called on the SSH thread. Blocks until the user answers.
    func shouldSign(keyName: String, endpoint: String) -> Bool
}

/// An interactive `AgentSignConfirming`. When a forwarded agent is asked to
/// sign, it blocks the SSH thread while a SwiftUI sheet names the key and the
/// host, then returns the user's decision.
///
/// Mirrors `HostKeyPrompter` — same shared instance observed by the UI, same
/// semaphore handoff, same rule: the decision method MUST be called off the
/// main thread (it is, from the libssh2 connection thread); calling it on main
/// would deadlock the prompt.
///
/// Blocking the SSH thread means the terminal is unresponsive while the sheet
/// is up. That is the design, not a defect. The alternative is signing without
/// asking, and a signature is precisely what the user is being asked about.
final class AgentSignPrompter: ObservableObject, AgentSignConfirming {
    static let shared = AgentSignPrompter()

    struct Prompt: Identifiable {
        let id = UUID()
        let keyName: String
        let endpoint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    /// How the prompt reaches the user. The default publishes it for the sheet
    /// to pick up; tests inject a closure and answer synchronously.
    private let present: (String, String, @escaping (Bool) -> Void) -> Void

    init(present: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil) {
        if let present {
            self.present = present
        } else {
            // Assigned in two steps because the default closure captures self.
            self.present = { _, _, _ in }
            self.present = { [weak self] keyName, endpoint, respond in
                DispatchQueue.main.async {
                    self?.prompt = Prompt(keyName: keyName, endpoint: endpoint) { allowed in
                        respond(allowed)
                        self?.prompt = nil
                    }
                }
            }
        }
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        present(keyName, endpoint) { allowed in
            decision.value = allowed
            semaphore.signal()
        }
        semaphore.wait()
        return decision.value
    }

    /// Carries the decision from the main thread (the sheet) back to the
    /// waiting SSH thread; the semaphore provides the happens-before ordering.
    private final class Decision { var value = false }
}
```

Note the default value is `false`: if anything goes wrong on the way to an answer, the request is refused. A prompt that fails open would sign silently, which is the one outcome this whole task exists to prevent.

The two-step assignment of `self.present` is awkward; if a cleaner formulation compiles (a lazily-created closure, or a private `presentDefault` method referenced after `init`), prefer it — but keep the "no answer means refuse" property.

- [ ] **Step 4: Write `AgentSignPromptView.swift`**

A sheet naming the key and the endpoint, with Allow and Deny. Deny is the default action, and the copy says plainly that allowing lets the remote host authenticate as the user somewhere else. Follow `HostKeyPromptView`'s layout and use `SloopStyle.teal` for the accent, as the rest of the app does.

- [ ] **Step 5: Present the sheet from `HostListView`**

**Without this the app deadlocks.** `shouldSign` blocks the SSH thread on a semaphore that only the sheet's response closure signals. If nothing presents the sheet, that signal never comes and the terminal freezes permanently on the first signature request — not a missing dialog, a hung session with no way out.

`HostListView` already does exactly this for host keys. Mirror it. Beside the existing observed prompter (`HostListView.swift:15`):

```swift
@ObservedObject private var agentSignPrompter = AgentSignPrompter.shared
```

and beside the existing host-key sheet (`HostListView.swift:201-203`):

```swift
.sheet(item: $agentSignPrompter.prompt) { prompt in
    AgentSignPromptView(prompt: prompt)
}
```

This means `AgentSignPrompter.Prompt` must be `Identifiable`, as `HostKeyPrompter.Prompt` is — it carries `let id = UUID()` for exactly this reason.

- [ ] **Step 6: Add a test that the refusal path cannot hang**

The deadlock above is the failure mode that matters, so pin it: assert that a prompter whose `present` closure never calls `respond` does NOT block forever when the caller gives up. If the design has no timeout — and it should not have one, since silently refusing after a delay is worse than waiting for a human — then instead assert the contract that makes it safe: `shouldSign` returns exactly what `respond` was called with, and returns promptly once it is called. Document in the test why no timeout exists.

- [ ] **Step 5: Run the tests and confirm they pass**

Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add App/Sloop/SSH/AgentSignPrompter.swift App/Sloop/Views/AgentSignPromptView.swift Tests/SloopAppTests/AgentSignPrompterTests.swift
git commit -m "SSH: confirm every forwarded-agent signature with the user"
```

---

### Task 7: ForwardedAgent and transport integration

The riskiest task. `ForwardedAgent` is a separate type with a narrow surface so the two-channel logic is testable without a network, and so the existing loop gains three calls rather than a rewrite.

**Files:**
- Create: `App/Sloop/SSH/ForwardedAgent.swift`
- Modify: `App/Sloop/SSH/LibSSH2Transport.swift`
- Modify: `App/Sloop/SSH/TransportFactory.swift`
- Test: `Tests/SloopAppTests/ForwardedAgentTests.swift`

**Interfaces:**
- Consumes: `AgentFramer`, `AgentRequest`, `AgentResponse` (Task 2), `AgentSigner` (Task 5), `AgentSignConfirming` (Task 6), `KeyLibrary.forwardedKeys(for:)` (Task 3).
- Produces:
  ```swift
  /// The channel operations ForwardedAgent needs. Top-level, NOT nested in the
  /// class — Swift 5.9 does not allow protocols nested in types, and this
  /// project builds at 5.9. A libssh2-backed conformance ships in the same
  /// file; tests use a scripted fake, so none of them need a real connection.
  protocol AgentChannel: AnyObject {
      /// >0 bytes read, 0 EOF, negative for EAGAIN or error.
      func read(into buffer: inout [UInt8]) -> Int
      func write(_ bytes: [UInt8]) -> Int
      func close()
  }

  final class ForwardedAgent {
      init(signer: AgentSigner, confirming: AgentSignConfirming, endpoint: String)
      func adopt(_ channel: AgentChannel)
      @discardableResult func service() -> Bool   // true if it did work this pass
      func close()
  }
  ```

- [ ] **Step 1: Write the failing tests**

Drive `ForwardedAgent` through a fake `Channel` holding scripted inbound bytes and capturing outbound ones. Cover: an identities request answered with the host's keys; a sign request for an unknown blob answered `FAILURE` **without** consulting the confirmer; a refused confirmation answered `FAILURE`; a confirmed request answered `SIGN_RESPONSE`; a request split across two `service()` passes; and two requests delivered in one read.

```swift
func testSignRequestForAnUnknownBlobFailsWithoutPrompting() {
    // A remote can ask about any blob it likes. Prompting for keys this host
    // was never given would train the user to approve prompts they cannot
    // evaluate, so the refusal happens before the user is involved.
    var prompted = false
    let confirmer = StubConfirmer { prompted = true; return true }
    // ... assert the reply is AgentResponse.failure() and prompted == false
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Expected: FAIL — `cannot find 'ForwardedAgent' in scope`.

- [ ] **Step 3: Write `ForwardedAgent.swift`**

`service()` reads what is available, feeds `AgentFramer`, and for each complete payload parses a request, dispatches it, and queues the framed reply. Requests other than identities/sign answer `AgentResponse.failure()`. A protocol error closes the channel — a remote that cannot frame correctly is not one to keep talking to.

- [ ] **Step 4: Wire the callback and the loop in `LibSSH2Transport.swift`**

First, the pieces the changes below refer to. `LibSSH2Transport.init` (line 39) gains two defaulted parameters, so no existing caller breaks:

```swift
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier(),
         forwardedKeys: [NamedKey] = [],
         signConfirmer: AgentSignConfirming = AgentSignPrompter.shared) {
```

and a stored property for the agent, since the C callback has to find it:

```swift
    /// Non-nil only while a forwarded agent is running. Touched solely on the
    /// SSH thread — the callback that sets it is invoked by libssh2 from inside
    /// packet processing, which happens on that same thread.
    private var forwardedAgent: ForwardedAgent?
```

The agent is constructed in `run()` AFTER authentication succeeds (the session must exist and be usable before `AgentSigner` can derive identities from it) and BEFORE `openShell`, because `openShell` is where forwarding is requested:

```swift
        if !forwardedKeys.isEmpty {
            forwardedAgent = ForwardedAgent(
                signer: AgentSigner(session: session, keys: forwardedKeys),
                confirming: signConfirmer,
                endpoint: "\(host.hostname):\(host.port)")
        }
```

Then four changes:

1. `libssh2_session_init_ex(nil, nil, nil, nil)` (line 90) passes an abstract pointer to `self` as its fourth argument: `Unmanaged.passUnretained(self).toOpaque()`. That parameter is a `void *` value; the callback receives `void **`, so it reads `abstract.pointee` to get it back. `passUnretained` is correct rather than a leak-forever `passRetained` because the session is freed by `run()`'s own `defer` before the transport can go away — `run()` is a method executing on `self`, so `self` is alive for the whole session lifetime.
2. Register the callback after the session is created and before the handshake. The vendored header (`libssh2.h:656`) declares:
   ```c
   typedef void (libssh2_cb_generic)(void);
   LIBSSH2_API libssh2_cb_generic *
   libssh2_session_callback_set2(LIBSSH2_SESSION *session, int cbtype,
                                 libssh2_cb_generic *callback);
   ```
   `libssh2_session_callback_set` is marked `LIBSSH2_DEPRECATED(1.11.1)` — use `set2`. Because it takes a generic `void (*)(void)`, the typed callback has to be cast:
   ```swift
   // The AUTHAGENT callback's real type is
   //   (LIBSSH2_SESSION *, LIBSSH2_CHANNEL *, void **) -> Void
   // but callback_set2 takes a generic void(*)(void), so the cast is required
   // and is the same one libssh2's own examples use.
   let callback: @convention(c) (OpaquePointer?, OpaquePointer?,
                                 UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = {
       _, channel, abstract in
       guard let channel,
             let box = abstract?.pointee else { return }
       let transport = Unmanaged<LibSSH2Transport>.fromOpaque(box).takeUnretainedValue()
       transport.adoptAgentChannel(channel)
   }
   _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_AUTHAGENT,
                                     unsafeBitCast(callback, to: (@convention(c) () -> Void).self))
   ```
3. The callback is a C function pointer, so it captures nothing: recover the transport from the abstract pointer, hand the channel to the `ForwardedAgent`, and return immediately. **It runs inside libssh2 packet processing on the SSH thread — it must not block, prompt, or sign.**
4. In `openShell`, after `libssh2_channel_process_startup` succeeds and only when `host.forwardsAgent`, call `retry(session, sock) { libssh2_channel_request_auth_agent(channel) }`. A failure here is not fatal: log it and carry on with a working shell that cannot forward.

In `eventLoop`, after the shell drain and before the `waitSocket` decision:

```swift
// Service the agent channel in the same pass as the shell. `readData`
// absorbs its result so a loop that only had agent traffic does not sleep
// for 200 ms with a reply already queued.
if let agent, agent.service() { readData = true }
```

- [ ] **Step 5: Resolve forwarded keys at the call site**

The resolution happens in `HostListModel.connect(_:)` (`App/Sloop/Views/HostListModel.swift:199`), which already resolves the credential and holds the `keys` store — not inside `TransportFactory`, which is handed a resolved `Credential` rather than a store:

```swift
let credential = try KeyLibrary.credential(for: host, keys: keys, credentials: credentials)
    ?? Credential()
let forwardedKeys = try KeyLibrary.forwardedKeys(for: host, keys: keys)
```

Thread it through `TransportFactory.ssh(...)` — a new `forwardedKeys: [NamedKey]` parameter — into `LibSSH2Transport.init`. `TransportFactory.ssh` has exactly one caller, this one.

**Do NOT gate this on `host.useMosh`.** An earlier draft of this plan said to pass an empty array for Mosh hosts, and reading the call site shows that is wrong. `HostListModel.connect` falls back to a plain SSH shell whenever Mosh isn't available — and per the comment at line 190, the Mosh UDP transport isn't wired yet, so **today it always falls back**. A `useMosh` host is therefore usually running an ordinary SSH session, which can forward perfectly well. Gating here would silently disable forwarding for those hosts with nothing to explain why.

The correct division: pass the keys unconditionally, let `LibSSH2Transport` request forwarding only when the list is non-empty, and let `MoshTransport` simply never forward — which it does by construction, having no SSH channel to forward over.

- [ ] **Step 6: Run the tests and confirm they pass**

Run the app-target suite plus `swift test`.
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add App/Sloop/SSH/ForwardedAgent.swift App/Sloop/SSH/LibSSH2Transport.swift App/Sloop/SSH/TransportFactory.swift Tests/SloopAppTests/ForwardedAgentTests.swift
git commit -m "SSH: serve a forwarded agent alongside the shell channel"
```

---

### Task 8: Host editor UI

**Files:**
- Modify: `App/Sloop/Views/HostEditView.swift`
- Modify: `Docs/ROADMAP.md`, `Docs/HANDOFF.md`
- Test: `Tests/SloopKitTests/ForwardedKeysTests.swift` (extend)

**Interfaces:**
- Consumes: `SSHHost.forwardedKeys`, `forwardsAgent` (Task 3).

- [ ] **Step 1: Add the section to `HostEditView`**

A "Forward agent" section listing every library key with a checkmark toggle bound to membership in `host.forwardedKeys`. Below it, footer text stating that a forwarded key can be used by anyone with root on that host, and that each use asks first.

**Do NOT hide the section for Mosh hosts, and do NOT clear the selection when Mosh is enabled.** An earlier draft said to do both; reading `HostListModel.connect(_:)` shows it is wrong. A `useMosh` host falls back to a plain SSH shell whenever Mosh is unavailable — and today that is always, since the Mosh UDP transport isn't wired yet. Those sessions forward perfectly well. Hiding the control, or silently emptying the user's selection when they toggle Mosh, would destroy a setting that is doing real work.

Instead, when `host.useMosh` is on, add a line to the section's footer: forwarding applies to SSH sessions, including the SSH fallback a Mosh host uses when `mosh-server` isn't reachable. That is the honest statement, and it needs no behavior change.

When the library is empty, show "No keys in the library" rather than an empty box.

- [ ] **Step 2: Add a test pinning that Mosh does not disturb the selection**

```swift
/// A Mosh host still forwards over its SSH fallback, so enabling Mosh must
/// leave the selection alone. Clearing it here would silently discard a
/// setting that is doing real work on every fallback session.
func testEnablingMoshLeavesForwardedKeysIntact() throws {
    var host = SSHHost(alias: "a", hostname: "h", username: "u")
    host.forwardedKeys = ["id_ed25519"]
    host.useMosh = true
    XCTAssertEqual(host.forwardedKeys, ["id_ed25519"])
    XCTAssertTrue(host.forwardsAgent)
}
```

- [ ] **Step 3: Run all tests**

Run: `swift test` and the app-target suite.
Expected: PASS.

- [ ] **Step 4: Update the docs**

- `Docs/ROADMAP.md` — mark agent forwarding done under the SSH gaps, noting it is unverified against a real host.
- `Docs/HANDOFF.md` — add to the device checklist: forward to a real host, confirm `ssh-add -l` on the remote lists exactly the selected keys, confirm `ssh` from that host to a third prompts on the device and succeeds on approval, and confirm a denial produces a clean auth failure rather than a hang.

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/Views/HostEditView.swift Docs/ROADMAP.md Docs/HANDOFF.md Tests/SloopKitTests/ForwardedKeysTests.swift
git commit -m "Hosts: choose which keys a host's forwarded agent may use"
```

---

## Verification before finishing

- [ ] `swift test` passes with no failures.
- [ ] `xcodegen generate --spec project.ssh.yml && xcodebuild test -scheme Sloop_macOS` passes.
- [ ] `xcodegen generate && xcodebuild build -scheme Sloop_macOS` still passes — the no-SSH variant must be unaffected.
- [ ] No file under `Sources/SloopKit/` imports CryptoKit, Security, or CSSH.
- [ ] Nothing references `AuthMethod.agent`.
