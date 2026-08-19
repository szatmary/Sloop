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

    /// A denial is a normal, expected outcome — the user said no to *this*
    /// request, not "hang up on this host forever." The channel, and the
    /// session behind it, must keep working afterward.
    func testRefusedConfirmationDoesNotCloseTheChannel() throws {
        let confirmer = StubConfirmer { false }
        let (agent, identity, channel) = try makeAgent(confirming: confirmer)
        channel.inbound = [signRequestFrame(blob: identity.blob)]

        XCTAssertTrue(agent.service())
        XCTAssertFalse(channel.closed, "a refusal is not a reason to close the channel")

        // Prove the session is still live, not just technically un-closed: a
        // fresh, unrelated request on the same channel gets answered.
        channel.inbound = [requestIdentitiesFrame()]
        XCTAssertTrue(agent.service())
        XCTAssertFalse(channel.closed)

        let replies = try readReplies(channel)
        XCTAssertEqual(replies.count, 2, "the refusal's FAILURE, then this request's real answer")
        XCTAssertEqual(replies.last, AgentResponse.identities([identity]).framedPayloadOnly())
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

    // MARK: Concurrent channels
    //
    // A remote does not multiplex its agent traffic onto one channel — RFC
    // 4254 channels are 1:1 with each CHANNEL_OPEN, so a parallel `git
    // submodule update`, an Ansible run with several forks, or a script
    // backgrounding a few `ssh` calls all open more than one
    // auth-agent@openssh.com channel at once. Ordinary use, not an edge case.

    /// Two channels adopted while both have traffic queued must both be
    /// answered from a single `service()` pass, and neither's arrival may
    /// disturb the other.
    func testTwoConcurrentChannelsAreBothServicedIndependently() throws {
        let confirmer = StubConfirmer { true }
        let (agent, identity, channelA) = try makeAgent(confirming: confirmer)
        let channelB = FakeAgentChannel()
        agent.adopt(channelB)

        channelA.inbound = [requestIdentitiesFrame()]
        channelB.inbound = [signRequestFrame(blob: identity.blob)]

        XCTAssertTrue(agent.service())

        XCTAssertEqual(try readReplies(channelA), [AgentResponse.identities([identity]).framedPayloadOnly()])
        XCTAssertEqual(try readReplies(channelB).map { $0.first ?? 0 }, [14], "SSH_AGENT_SIGN_RESPONSE")
        XCTAssertFalse(channelA.closed, "servicing channel B must not close channel A")
        XCTAssertFalse(channelB.closed, "servicing channel A must not close channel B")
    }

    /// A channel that reports EOF is closed and dropped, but only that one —
    /// a second, still-live channel must be serviced in the very same pass
    /// and must not be touched again once the first is gone.
    func testChannelEOFDropsThatChannelLeavesOthersAlive() throws {
        let (agent, identity, channelA) = try makeAgent()
        let channelB = FakeAgentChannel()
        agent.adopt(channelB)

        channelA.eof = true
        channelB.inbound = [requestIdentitiesFrame()]

        XCTAssertTrue(agent.service())

        XCTAssertTrue(channelA.closed, "EOF must close the channel that reported it")
        XCTAssertFalse(channelB.closed, "channel B never hit EOF and must stay open")
        XCTAssertEqual(try readReplies(channelB), [AgentResponse.identities([identity]).framedPayloadOnly()],
                       "channel B is served in the same pass as channel A's EOF")

        let readsAfterDrop = channelA.readCallCount
        channelB.inbound = [requestIdentitiesFrame()]
        XCTAssertTrue(agent.service())
        XCTAssertEqual(channelA.readCallCount, readsAfterDrop,
                       "a dropped channel must never be read from again")
    }

    /// A well-formed message of a type this agent doesn't implement (key
    /// management, locking, extensions — anything `AgentRequest.parse` maps
    /// to `.unsupported`) still gets an explicit refusal. Silence would look
    /// indistinguishable from a hung connection to whatever's waiting on it.
    func testUnsupportedMessageTypeGetsAFailureReplyNotSilence() throws {
        let (agent, _, channel) = try makeAgent()
        channel.inbound = [frame([20])]   // some type neither 11 nor 13

        XCTAssertTrue(agent.service())

        XCTAssertEqual(try readReplies(channel), [AgentResponse.failure().framedPayloadOnly()])
    }

    /// Each channel reassembles its own byte stream. A partial message
    /// sitting on channel A must not be corrupted, completed early, or
    /// otherwise affected by an unrelated, complete message arriving on
    /// channel B in the same `service()` pass.
    func testFramersAreIndependentPerChannel() throws {
        let confirmer = StubConfirmer { true }
        let (agent, identity, channelA) = try makeAgent(confirming: confirmer)
        let channelB = FakeAgentChannel()
        agent.adopt(channelB)

        let whole = signRequestFrame(blob: identity.blob)
        let splitPoint = whole.count / 2

        channelA.inbound = [Array(whole[..<splitPoint])]         // half a message
        channelB.inbound = [requestIdentitiesFrame()]             // a complete, unrelated one

        XCTAssertTrue(agent.service())

        XCTAssertTrue(channelA.outbound.isEmpty, "channel A's message is still incomplete")
        XCTAssertEqual(try readReplies(channelB), [AgentResponse.identities([identity]).framedPayloadOnly()],
                       "channel B's complete request is answered on its own")

        channelA.inbound = [Array(whole[splitPoint...])]
        XCTAssertTrue(agent.service())

        XCTAssertEqual(try readReplies(channelA).map { $0.first ?? 0 }, [14],
                       "channel A's message reassembles correctly despite B's unrelated traffic in between")
    }

    // MARK: Channel cap

    /// Channels beyond `ForwardedAgent.maximumConcurrentChannels` are refused
    /// outright — closed without ever being read — rather than left to
    /// accumulate. The already-adopted channels under the cap must be
    /// completely unaffected.
    func testChannelsBeyondTheCapAreRefusedWithoutBeingServiced() throws {
        let (agent, identity, firstChannel) = try makeAgent()
        var underCap = [firstChannel]
        for _ in 1..<ForwardedAgent.maximumConcurrentChannels {
            let channel = FakeAgentChannel()
            agent.adopt(channel)
            underCap.append(channel)
        }
        XCTAssertEqual(underCap.count, ForwardedAgent.maximumConcurrentChannels)

        let overflow = FakeAgentChannel()
        overflow.inbound = [requestIdentitiesFrame()]
        agent.adopt(overflow)

        // Give every under-cap channel a real request too, so the test can
        // tell "serviced normally" apart from "just never touched".
        for channel in underCap { channel.inbound = [requestIdentitiesFrame()] }

        XCTAssertTrue(agent.service())

        XCTAssertTrue(overflow.closed, "a channel beyond the cap is refused")
        XCTAssertEqual(overflow.readCallCount, 0,
                       "refused outright — never read from, let alone answered")
        XCTAssertTrue(overflow.outbound.isEmpty)
        XCTAssertEqual(overflow.lastCloseWasRetrying, false,
                       "an over-cap channel is already an abnormal case and must not be waited on")

        for (index, channel) in underCap.enumerated() {
            XCTAssertFalse(channel.closed, "channel \(index) is under the cap and must stay open")
            XCTAssertEqual(try readReplies(channel), [AgentResponse.identities([identity]).framedPayloadOnly()],
                           "channel \(index) is under the cap and must still be answered normally")
        }
    }

    /// A protocol error's close must not wait on the remote either — same
    /// reasoning as the over-cap path, same policy.
    func testMalformedFrameCloseDoesNotRetry() throws {
        let (agent, _, channel) = try makeAgent()
        channel.inbound = [[0x00, 0x00, 0x00, 0x00]]

        XCTAssertTrue(agent.service())

        XCTAssertEqual(channel.lastCloseWasRetrying, false)
    }

    /// The real hazard `libssh2_channel_close` can trigger: it can re-enter
    /// packet processing and fire the AUTHAGENT callback again mid-close,
    /// appending a brand-new session to `sessions` while the over-cap block
    /// is still closing the channel that arrived before it. A `removeLast`
    /// computed from the array's size *after* that append could target the
    /// wrong tail element — dropping the brand-new, never-closed session
    /// from tracking without ever calling `close` on it: a leaked channel
    /// nobody reads, writes to, or frees.
    func testSessionAppendedDuringAnOverCapCloseIsNotSilentlyDroppedUnclosed() throws {
        let (agent, _, _) = try makeAgent()   // adopts one channel already
        for _ in 1..<ForwardedAgent.maximumConcurrentChannels {
            agent.adopt(FakeAgentChannel())
        }

        let overflow = FakeAgentChannel()
        let reentrant = FakeAgentChannel()
        overflow.onClose = { [weak agent] in agent?.adopt(reentrant) }
        agent.adopt(overflow)

        XCTAssertTrue(agent.service())

        XCTAssertTrue(overflow.closed, "the original over-cap channel is refused as expected")
        XCTAssertFalse(reentrant.closed,
                       "not yet closed — it only just arrived and hasn't been serviced or refused yet")

        // The buggy position-based removal drops `reentrant` from `sessions`
        // entirely at this point without ever calling `close` on it — gone
        // for good, never read, never closed, never freed. The fix keeps it
        // tracked, so the *next* pass — which still sees the cap exceeded by
        // exactly the one channel that just arrived — closes it through the
        // ordinary over-cap path, exactly as it would have if it had simply
        // arrived on its own instead of via this re-entrant append.
        XCTAssertTrue(agent.service())
        XCTAssertTrue(reentrant.closed,
                      "must still be tracked, not leaked — even though it's the one that ends up refused next")
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
    /// When true and `inbound` is empty, `read` reports EOF (0) instead of
    /// EAGAIN (-1) — lets a test simulate the remote closing its end.
    var eof = false
    private(set) var outbound: [UInt8] = []
    private(set) var closed = false
    /// Counts `read` calls, so a test can prove a channel `ForwardedAgent`
    /// has dropped (after EOF or a protocol error) is never touched again —
    /// not just marked closed, but actually removed from what gets serviced.
    private(set) var readCallCount = 0
    /// What `retrying` was on the most recent `close` call, so a test can
    /// confirm a given path chose the policy it was supposed to.
    private(set) var lastCloseWasRetrying: Bool?
    /// Fires once, the first time `close` is called, then clears itself —
    /// lets a test simulate the real hazard a libssh2-backed channel's close
    /// has and a fake one otherwise couldn't: `libssh2_channel_close` can
    /// re-enter packet processing and fire the AUTHAGENT callback again
    /// mid-close, appending a brand-new session to the very agent that is
    /// doing the closing.
    var onClose: (() -> Void)?

    func read(into buffer: inout [UInt8]) -> Int {
        readCallCount += 1
        guard !inbound.isEmpty else { return eof ? 0 : -1 }
        let chunk = inbound.removeFirst()
        precondition(chunk.count <= buffer.count, "test chunk larger than the read buffer")
        for (index, byte) in chunk.enumerated() { buffer[index] = byte }
        return chunk.count
    }

    func write(_ bytes: [UInt8]) -> Int {
        outbound.append(contentsOf: bytes)
        return bytes.count
    }

    func close(retrying: Bool) {
        closed = true
        lastCloseWasRetrying = retrying
        let callback = onClose
        onClose = nil
        callback?()
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
