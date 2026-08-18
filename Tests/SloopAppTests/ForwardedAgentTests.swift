// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
import SloopKit

#if canImport(CSSH)
import CSSH

final class ForwardedAgentTests: XCTestCase {
    // MARK: Fixtures

    /// A stand-in ssh-agent wire blob that never matches a real derived
    /// identity. `ForwardedAgent` never inspects its contents beyond
    /// exact-matching against what `AgentSigner` reports, so any
    /// distinguishable byte string works here.
    private let unknownBlob: [UInt8] = Array("unknown-key-blob".utf8)

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

    /// Writes a real ed25519 key with ssh-keygen and returns its PEM — a
    /// stand-in for the host's own key library, so `AgentSigner` derives a
    /// real, verifiable identity rather than a fake one `ForwardedAgent`
    /// would need to special-case.
    private func generateKeyPEM() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", path.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "ssh-keygen failed")

        return try String(contentsOf: path, encoding: .utf8)
    }

    private func makeAgent(confirming: AgentSignConfirming = StubConfirmer { true }) throws
        -> (agent: ForwardedAgent, identity: AgentIdentity, channel: FakeAgentChannel) {
        let signer = AgentSigner(session: session, keys: [NamedKey(name: "k", privateKeyPEM: try generateKeyPEM())])
        let identity = try XCTUnwrap(signer.identities.first)
        let agent = ForwardedAgent(signer: signer, confirming: confirming, endpoint: "h:22")
        let channel = FakeAgentChannel()
        agent.adopt(channel)
        return (agent, identity, channel)
    }

    // MARK: Wire helpers

    /// Length-prefixes a message body the way `AgentFramer` expects it.
    private func frame(_ body: [UInt8]) -> [UInt8] {
        var writer = SSHWireWriter()
        writer.writeUInt32(UInt32(body.count))
        return writer.bytes + body
    }

    private func requestIdentitiesFrame() -> [UInt8] {
        frame([11])   // SSH_AGENTC_REQUEST_IDENTITIES
    }

    private func signRequestFrame(blob: [UInt8], data: [UInt8] = Array("challenge".utf8),
                                  flags: UInt32 = 0) -> [UInt8] {
        var body = SSHWireWriter()
        body.writeByte(13)   // SSH_AGENTC_SIGN_REQUEST
        body.writeString(blob)
        body.writeString(data)
        body.writeUInt32(flags)
        return frame(body.bytes)
    }

    /// Reads the framed replies queued in `channel.outbound` back out as
    /// distinct payloads — the inverse of what `AgentFramer` does on the way
    /// in — so a test can assert on how many replies arrived and what type
    /// each one is, even when several were written in one `service()` pass.
    private func readReplies(_ channel: FakeAgentChannel) throws -> [[UInt8]] {
        var framer = AgentFramer()
        framer.append(channel.outbound[...])
        var payloads: [[UInt8]] = []
        while let payload = try framer.nextPayload() {
            payloads.append(payload)
        }
        return payloads
    }

    // MARK: Tests

    func testIdentitiesRequestIsAnsweredWithTheHostsKeys() throws {
        let (agent, identity, channel) = try makeAgent()
        channel.inbound = [requestIdentitiesFrame()]

        XCTAssertTrue(agent.service())

        let replies = try readReplies(channel)
        XCTAssertEqual(replies, [AgentResponse.identities([identity]).framedPayloadOnly()])
    }

    /// A remote can ask about any blob it likes. Prompting for keys this host
    /// was never given would train the user to approve requests they cannot
    /// evaluate, so the refusal happens before the user is involved at all.
    func testSignRequestForAnUnknownBlobFailsWithoutPrompting() throws {
        var prompted = false
        let confirmer = StubConfirmer { prompted = true; return true }
        let (agent, _, channel) = try makeAgent(confirming: confirmer)
        channel.inbound = [signRequestFrame(blob: unknownBlob)]

        XCTAssertTrue(agent.service())

        XCTAssertFalse(prompted, "the confirmer must never be consulted for a blob the host never offered")
        let replies = try readReplies(channel)
        XCTAssertEqual(replies, [AgentResponse.failure().framedPayloadOnly()])
    }

    func testRefusedConfirmationProducesFailure() throws {
        let confirmer = StubConfirmer { false }
        let (agent, identity, channel) = try makeAgent(confirming: confirmer)
        channel.inbound = [signRequestFrame(blob: identity.blob)]

        XCTAssertTrue(agent.service())

        let replies = try readReplies(channel)
        XCTAssertEqual(replies, [AgentResponse.failure().framedPayloadOnly()])
    }

    func testConfirmedRequestProducesASignResponse() throws {
        let confirmer = StubConfirmer { true }
        let (agent, identity, channel) = try makeAgent(confirming: confirmer)
        channel.inbound = [signRequestFrame(blob: identity.blob)]

        XCTAssertTrue(agent.service())

        let replies = try readReplies(channel)
        // `?? 0` rather than an unguarded index: a mismatched count must fail
        // the assertion below, not crash the test host by indexing an array
        // that turned out empty.
        XCTAssertEqual(replies.map { $0.first ?? 0 }, [14], "SSH_AGENT_SIGN_RESPONSE")
    }

    /// The channel is a byte stream: a read can, and here does, deliver only
    /// half of one message. `ForwardedAgent` must hold the partial bytes
    /// across `service()` calls rather than losing or misreading them.
    func testRequestSplitAcrossTwoServicePassesIsHandled() throws {
        let confirmer = StubConfirmer { true }
        let (agent, identity, channel) = try makeAgent(confirming: confirmer)
        let whole = signRequestFrame(blob: identity.blob)
        let splitPoint = whole.count / 2

        channel.inbound = [Array(whole[..<splitPoint])]
        // `service()` still reports it did something — it consumed bytes off
        // the channel, same as the shell channel counts any bytes read as
        // progress — but half a message is not a complete request, so no
        // reply goes out yet.
        XCTAssertTrue(agent.service())
        XCTAssertTrue(channel.outbound.isEmpty, "no reply until the whole request has arrived")

        channel.inbound = [Array(whole[splitPoint...])]
        XCTAssertTrue(agent.service())

        let replies = try readReplies(channel)
        XCTAssertEqual(replies.map { $0.first ?? 0 }, [14], "SSH_AGENT_SIGN_RESPONSE")
    }

    /// Two independent requests can arrive back to back in a single read —
    /// pipelining, or just an unlucky buffer boundary. Both must be answered,
    /// in order, from one `service()` call.
    func testTwoRequestsDeliveredInOneReadAreBothHandled() throws {
        let confirmer = StubConfirmer { true }
        let (agent, identity, channel) = try makeAgent(confirming: confirmer)
        channel.inbound = [requestIdentitiesFrame() + signRequestFrame(blob: identity.blob)]

        XCTAssertTrue(agent.service())

        let replies = try readReplies(channel)
        XCTAssertEqual(replies.map { $0.first ?? 0 }, [12, 14],
                       "SSH_AGENT_IDENTITIES_ANSWER, then SSH_AGENT_SIGN_RESPONSE, in order")
    }

    /// A remote that cannot frame correctly is not one to keep talking to:
    /// continuing to interpret its bytes risks reading a later message's
    /// content as this one's, an undefined state neither side can recover
    /// from. The channel is closed instead.
    func testMalformedFrameClosesTheChannel() throws {
        let (agent, _, channel) = try makeAgent()
        // A declared length of zero: `AgentFramer` rejects this outright.
        channel.inbound = [[0x00, 0x00, 0x00, 0x00]]

        XCTAssertTrue(agent.service())

        XCTAssertTrue(channel.closed)
    }
}

/// A confirmer whose answer (and whether it was even asked) is fully under a
/// test's control.
private final class StubConfirmer: AgentSignConfirming {
    private let handler: () -> Bool

    init(_ handler: @escaping () -> Bool) {
        self.handler = handler
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        handler()
    }
}

/// A scripted, in-memory `AgentChannel`. `inbound` holds the chunks a test
/// wants delivered — one chunk consumed per `read` call, which is what lets a
/// test control exactly how a message is split across reads and across
/// `service()` passes. `outbound` accumulates whatever `ForwardedAgent`
/// writes back, in order.
private final class FakeAgentChannel: AgentChannel {
    var inbound: [[UInt8]] = []
    private(set) var outbound: [UInt8] = []
    private(set) var closed = false

    func read(into buffer: inout [UInt8]) -> Int {
        guard !inbound.isEmpty else { return -1 }   // EAGAIN: nothing queued right now
        let chunk = inbound.removeFirst()
        precondition(chunk.count <= buffer.count, "test chunk larger than the read buffer")
        for (index, byte) in chunk.enumerated() { buffer[index] = byte }
        return chunk.count
    }

    func write(_ bytes: [UInt8]) -> Int {
        outbound.append(contentsOf: bytes)
        return bytes.count
    }

    func close() {
        closed = true
    }
}

private extension Array where Element == UInt8 {
    /// Strips the 4-byte outer length header a `AgentResponse.*` helper adds,
    /// leaving the same shape `readReplies` decodes replies into — so a
    /// `AgentResponse.*` value and a decoded reply can be compared directly.
    func framedPayloadOnly() -> [UInt8] {
        Array(self.dropFirst(4))
    }
}
#endif
