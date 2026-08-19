// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Serves a forwarded ssh-agent alongside the shell channel. Compiles only
// where libssh2 does, like `AgentSigner`: it names `AgentSigner` directly,
// and the concrete `AgentChannel` conformance at the bottom of this file
// needs CSSH's channel functions.
#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit

/// The channel operations `ForwardedAgent` needs. Top-level, NOT nested in
/// the class — Swift 5.9 does not allow protocols nested in types, and this
/// project builds at 5.9. `LibSSH2AgentChannel` below is the libssh2-backed
/// conformance used in production; tests drive a scripted fake instead, so
/// none of them need a network or a real channel.
protocol AgentChannel: AnyObject {
    /// >0 bytes read, 0 EOF, negative for EAGAIN or error.
    func read(into buffer: inout [UInt8]) -> Int
    func write(_ bytes: [UInt8]) -> Int
    func close()
}

/// Speaks the ssh-agent wire protocol over one or more forwarded-agent
/// channels, answering from a fixed, host-approved set of keys rather than a
/// real ssh-agent socket.
///
/// A remote host does not multiplex its agent traffic onto one channel:
/// RFC 4254 channels are 1:1 with each `CHANNEL_OPEN`, and every
/// `auth-agent@openssh.com` request a remote program makes opens its own.
/// Ordinary concurrent use of a forwarded agent — a parallel `git submodule
/// update`, an Ansible run with several forks, a script backgrounding a few
/// `ssh` calls — opens more than one at once. So `ForwardedAgent` tracks a
/// collection of adopted channels, each with its own `AgentFramer`: sharing
/// one framer across channels would interleave two remotes' byte streams
/// into garbage neither could parse.
///
/// Deliberately separate from `LibSSH2Transport`: everything here is
/// reasoned about — and tested — through `AgentChannel` alone, with no
/// socket and no real libssh2 channel involved. The two calls that do touch
/// libssh2 (deriving identities, producing a signature) are already isolated
/// inside `AgentSigner`.
final class ForwardedAgent {
    /// Per-channel state. A class (not a struct) so `service()` can hold a
    /// stable reference to each entry across the read/parse/write passes
    /// without juggling array indices that shift as sessions are removed.
    private final class Session {
        let channel: AgentChannel
        var framer = AgentFramer()
        var outbound: [UInt8] = []

        init(channel: AgentChannel) {
            self.channel = channel
        }
    }

    private let signer: AgentSigner
    private let confirming: AgentSignConfirming
    private let endpoint: String

    private var sessions: [Session] = []

    /// Comfortably larger than any single agent message this app produces or
    /// expects to receive in one read; OpenSSH's own agent client reads in
    /// similarly-sized chunks.
    private static let readChunkSize = 4096

    /// Caps how many forwarded-agent channels can be adopted at once. Each
    /// session carries its own `AgentFramer`, which will buffer up to
    /// `AgentFramer.maximumFrameLength` (256 KiB, `AgentProtocol.swift`) of
    /// unreassembled input before it ever sees one complete message — so N
    /// adopted channels is an N × 256 KiB worst case with nothing yet to show
    /// for it. 16 caps that at 4 MiB: comfortably above anything an ordinary
    /// interactive session opens at once (a handful of parallel git/ssh
    /// subprocesses is a large one), while keeping a single misbehaving or
    /// hostile forwarding client from growing this without bound. Internal,
    /// not private, so a test can adopt exactly this many channels plus one
    /// without hardcoding the number twice.
    static let maximumConcurrentChannels = 16

    init(signer: AgentSigner, confirming: AgentSignConfirming, endpoint: String) {
        self.signer = signer
        self.confirming = confirming
        self.endpoint = endpoint
    }

    /// Called with a channel libssh2 just opened for a remote forwarding
    /// request. This runs on the SSH thread from **inside** the AUTHAGENT C
    /// callback — which itself runs from inside libssh2 packet processing,
    /// already on the stack of the `libssh2_channel_read_ex` call that
    /// discovered the new channel. So this does the one thing that is safe
    /// there: append a new `Session` and return. It must never close a
    /// channel (closing calls into libssh2, which would re-enter libssh2
    /// from inside libssh2 — undefined behaviour, not just a bug) and must
    /// never do any of the actual protocol work; `service()` does all of
    /// that later, off this call's stack, from the event loop.
    func adopt(_ channel: AgentChannel) {
        sessions.append(Session(channel: channel))
    }

    /// Services every adopted channel: reads what's available, answers
    /// whatever complete requests arrived, and flushes whatever replies fit.
    /// A channel that hit EOF or a protocol error is closed and dropped here
    /// — safe because this runs from the event loop, not from inside a
    /// libssh2 callback — without disturbing any other channel still open.
    ///
    /// Returns true if it did anything on any channel — read a byte, produced
    /// a reply, wrote one, or closed a finished channel — so the caller's
    /// poll loop can tell a serviced pass from an idle one, and not sleep for
    /// 200 ms with a reply already sitting in some session's `outbound`.
    @discardableResult
    func service() -> Bool {
        guard !sessions.isEmpty else { return false }
        var didWork = false

        // Enforce the cap here, not in `adopt` — `adopt` runs from inside the
        // AUTHAGENT callback and must never call into libssh2, which closing
        // a channel does. A channel that arrives over the cap just sits in
        // `sessions`, unserviced, until this runs; then it's refused outright
        // — closed without ever being read — so a flood of channels can't
        // make each one buffer partial input first. The oldest
        // `maximumConcurrentChannels` sessions are kept; only the newest
        // arrivals beyond the cap are refused, so already-working sessions
        // are never punished to make room for new ones.
        if sessions.count > Self.maximumConcurrentChannels {
            let overflow = sessions[Self.maximumConcurrentChannels...]
            for session in overflow { session.channel.close() }
            sessions.removeLast(sessions.count - Self.maximumConcurrentChannels)
            didWork = true
        }

        // Collected rather than removed in place: `sessions` is being walked
        // right now, and removing a finished entry mid-iteration would skip
        // or re-visit a neighbour. Closing and dropping happens in a second
        // pass over this list once the walk is done.
        var finished: [Session] = []

        for session in sessions {
            let (worked, done) = service(session)
            if worked { didWork = true }
            if done { finished.append(session) }
        }

        if !finished.isEmpty {
            for session in finished { session.channel.close() }
            sessions.removeAll { candidate in finished.contains { $0 === candidate } }
            didWork = true
        }

        return didWork
    }

    /// Tears down every adopted channel — the whole-transport teardown path,
    /// not the per-channel EOF path above, so closing here is unconditional.
    func close() {
        for session in sessions { session.channel.close() }
        sessions.removeAll()
    }

    /// Runs one channel's read/parse/reply passes. Returns whether any work
    /// happened, and whether the channel is finished (EOF or a protocol
    /// error) and should be closed and dropped by the caller.
    private func service(_ session: Session) -> (didWork: Bool, done: Bool) {
        let channel = session.channel
        var didWork = false

        while true {
            var chunk = [UInt8](repeating: 0, count: Self.readChunkSize)
            let n = channel.read(into: &chunk)
            if n > 0 {
                session.framer.append(chunk[0..<n])
                didWork = true
            } else if n == 0 {
                return (didWork, true)   // EOF: nothing more will ever arrive
            } else {
                break   // EAGAIN or a transient error: nothing more right now
            }
        }

        while true {
            let payload: [UInt8]?
            do {
                payload = try session.framer.nextPayload()
            } catch {
                // The remote's byte stream no longer means anything we can
                // trust — guessing at a "recovery" risks reading a later
                // message's bytes as this one's tail. A remote that cannot
                // frame correctly is not one to keep talking to, but this is
                // one channel among possibly several, so only this one goes.
                return (true, true)
            }
            guard let payload else { break }

            let request: AgentRequest
            do {
                request = try AgentRequest.parse(payload)
            } catch {
                return (true, true)
            }

            session.outbound.append(contentsOf: respond(to: request))
            didWork = true
        }

        while !session.outbound.isEmpty {
            let n = channel.write(session.outbound)
            guard n > 0 else { break }
            session.outbound.removeFirst(n)
            didWork = true
        }

        return (didWork, false)
    }

    private func respond(to request: AgentRequest) -> [UInt8] {
        switch request {
        case .requestIdentities:
            return AgentResponse.identities(signer.identities)

        case .sign(let keyBlob, let data, let flags):
            // A remote can ask about any blob it likes. Refusing before the
            // confirmer sees it means a request for a key this host was
            // never given can't be used to train the user into approving
            // prompts they have no way to evaluate.
            guard let identity = signer.identity(matching: keyBlob) else {
                return AgentResponse.failure()
            }
            guard confirming.shouldSign(keyName: identity.keyName, endpoint: endpoint) else {
                return AgentResponse.failure()
            }
            guard let signed = try? signer.sign(identity: identity, data: data, flags: flags) else {
                return AgentResponse.failure()
            }
            return AgentResponse.signature(algorithm: signed.algorithm, signature: signed.signature)

        case .unsupported:
            return AgentResponse.failure()
        }
    }
}

/// The production `AgentChannel`: a thin forward onto the same libssh2 calls
/// `LibSSH2Transport`'s shell channel already uses, so a second channel costs
/// three functions instead of a second event loop.
final class LibSSH2AgentChannel: AgentChannel {
    private let channel: OpaquePointer
    /// Retries a libssh2 call against EAGAIN, waiting on the underlying
    /// socket between attempts — the same helper `LibSSH2Transport` uses for
    /// every other libssh2 call, handed in because `LibSSH2AgentChannel`
    /// doesn't hold a session or a socket of its own.
    private let retryUntilReady: (@escaping () -> Int32) -> Int32

    init(channel: OpaquePointer, retry: @escaping (@escaping () -> Int32) -> Int32) {
        self.channel = channel
        self.retryUntilReady = retry
    }

    func read(into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { raw in
            Int(libssh2_channel_read_ex(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, raw.count))
        }
    }

    func write(_ bytes: [UInt8]) -> Int {
        bytes.withUnsafeBytes { raw in
            Int(libssh2_channel_write_ex(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, raw.count))
        }
    }

    /// Retries the close against EAGAIN before freeing, the same as the shell
    /// channel's own teardown in `LibSSH2Transport.run()` — a single
    /// un-retried `libssh2_channel_close` ordinarily returns EAGAIN, and
    /// `_libssh2_channel_free` refuses to actually free a channel whose local
    /// side hasn't finished closing. Skip the retry and the channel is stuck
    /// in `session->channels` for good: libssh2 keeps queuing its inbound
    /// CHANNEL_DATA into `session->packets` with nothing left to drain it —
    /// unbounded, and worst on exactly the protocol-error close path where
    /// the remote is still writing.
    ///
    /// Only ever called from `ForwardedAgent.service()` or `.close()` — both
    /// run from the event loop, off the AUTHAGENT callback's stack, which is
    /// what makes calling into libssh2 here safe. `adopt` never calls this.
    func close() {
        _ = retryUntilReady { [channel] in libssh2_channel_close(channel) }
        libssh2_channel_free(channel)
    }
}
#endif
