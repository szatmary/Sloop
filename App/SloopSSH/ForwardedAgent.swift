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
    /// `retrying`: true allows a brief, BOUNDED wait for the peer's own
    /// CHANNEL_CLOSE before giving up; false makes exactly one best-effort
    /// attempt and returns immediately. See the call sites in
    /// `ForwardedAgent` for which paths choose which, and why: the short
    /// version is that anything reached while the shell is still live and
    /// interactive must never wait on a peer that may not answer.
    func close(retrying: Bool)
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

    /// How many bytes of replies one `service()` pass will queue for a single
    /// channel before it stops answering and gets on with writing what it
    /// already has.
    ///
    /// The remote picks both how many requests it sends and how expensive
    /// each answer is: `REQUEST_IDENTITIES` costs it five bytes on the wire
    /// and is answered with every offered key's blob and comment, so a stream
    /// of them amplifies its input into this app's memory by two or three
    /// orders of magnitude. A pass that parsed to exhaustion before writing a
    /// single byte turned 200 KiB of them against four RSA-3072 keys into
    /// 67 MiB queued on ONE channel, and nothing in that arrangement was the
    /// remote's ceiling — it was simply how much it had chosen to send.
    ///
    /// 256 KiB is `AgentFramer.maximumFrameLength` (`AgentProtocol.swift`),
    /// the size OpenSSH's own agent allows a single message: far more than
    /// the few KiB of answers any real client has outstanding at once, and
    /// with `maximumConcurrentChannels` it puts the reply side under the same
    /// 4 MiB ceiling that cap already puts on buffered input. It bounds the
    /// input side too, because this pass only reads when it has no
    /// reassembled request left to answer: every message it parses produces
    /// at least a nine-byte reply, so a pass cannot read more than roughly
    /// this many bytes of complete requests, plus the one partly-arrived
    /// frame the framer may still be holding. Internal, not private, so a
    /// test can assert against the bound without hardcoding it twice.
    static let maximumQueuedReplyBytes = 256 * 1024

    /// How many signature requests one `service()` pass will act on for a
    /// single channel.
    ///
    /// Each one blocks the SSH thread inside `AgentSignConfirming.shouldSign`
    /// until the user answers a sheet they cannot dismiss. `service()` runs
    /// from `LibSSH2Transport.eventLoop`, which polls `shouldClose` only
    /// between passes — so a pass that answered every queued sign request
    /// would hand the user N sheets to tap through with no way to close the
    /// tab until the last one was answered, which is a remote deciding how
    /// long the user stays trapped. One per pass is the smallest bound that
    /// still makes progress, and a larger one buys nothing: a prompt already
    /// costs a human answer, so batching two before returning to the event
    /// loop adds no throughput and spends exactly the closability this bound
    /// exists to protect. The rest stay framed and are answered on the
    /// following passes, in order.
    static let maximumSignRequestsPerPass = 1

    /// How many times `close()` looks again for channels that arrived while
    /// it was closing others.
    ///
    /// One round covers everything adopted when teardown began; the extra two
    /// are for the re-entrant arrivals a close can trigger, which in practice
    /// is none or one. A remote that produces a fresh channel for every close
    /// it sees is not going to stop being asked nicely, and each further
    /// round is another full pass of libssh2 calls spent on a peer that is
    /// demonstrably not cooperating — so this gives up rather than let the
    /// remote choose when teardown ends. Internal for the same reason as the
    /// caps above.
    static let closeDrainRounds = 3

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
        // are never punished to make room for new ones. `retrying: false`:
        // a channel that showed up over the cap is already an abnormal
        // case, possibly hostile, and must not make `service()` wait on it —
        // see `LibSSH2Transport.closeAttempt`.
        if sessions.count > Self.maximumConcurrentChannels {
            // Snapshotted by reference identity BEFORE closing anything, not
            // removed by position afterward: `session.channel.close` can, in
            // the real libssh2-backed channel, re-enter packet processing
            // and fire the AUTHAGENT callback again mid-close, appending a
            // brand-new session to `sessions` right here. `removeLast(n)`
            // computed from a POST-close `sessions.count` would then target
            // whatever now sits at the tail — possibly that brand-new,
            // never-closed session — while leaving one of the sessions
            // actually closed above still in `sessions`, a dangling
            // reference to a freed channel. Removing by identity against a
            // snapshot taken up front is immune to how many new sessions
            // appeared while closing; any that did just stay tracked and are
            // handled on a later pass, the same as if they'd arrived on
            // their own.
            let overflow = Array(sessions[Self.maximumConcurrentChannels...])
            for session in overflow { session.channel.close(retrying: false) }
            sessions.removeAll { candidate in overflow.contains { $0 === candidate } }
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
            // `retrying: false` here too: EOF and a protocol error both mean
            // the remote is either done or has stopped speaking a protocol
            // we trust, and `service()` must return to the event loop
            // promptly either way — a peer that never sends its own
            // CHANNEL_CLOSE must not be waited on while the shell is live.
            for session in finished { session.channel.close(retrying: false) }
            sessions.removeAll { candidate in finished.contains { $0 === candidate } }
            didWork = true
        }

        return didWork
    }

    /// Tears down every adopted channel — the whole-transport teardown path,
    /// not the per-channel EOF path above, so closing here is unconditional.
    /// This only runs once, from `LibSSH2Transport.run()`'s own teardown
    /// `defer`, after `eventLoop` has already returned.
    ///
    /// Snapshotted and removed by reference identity, exactly like the
    /// over-cap path above, and for exactly the same reason: a close can
    /// re-enter libssh2 packet processing and fire the AUTHAGENT callback
    /// mid-close, appending a brand-new session while this is walking the
    /// old ones. The blanket `removeAll()` this used to end with discarded
    /// that arrival without ever closing it — and an unclosed channel is one
    /// `libssh2_channel_free` never frees, which is what makes
    /// `libssh2_session_free` bail and leak the whole `LIBSSH2_SESSION` (see
    /// `LibSSH2AgentChannel.close`). So each round closes precisely what it
    /// snapshotted, removes precisely that, and looks again for whatever
    /// turned up while it was working.
    func close() {
        for round in 0..<Self.closeDrainRounds {
            guard !sessions.isEmpty else { return }
            let closing = sessions

            // `retrying: true` on the first round only. That round holds the
            // channels that existed when teardown began, and the shell is no
            // longer live to freeze, so a short, BOUNDED wait for each
            // channel's own CHANNEL_CLOSE (see
            // `LibSSH2Transport.closeAttempt`) is worth spending to leave
            // things tidy. A channel that turns up *during* teardown is the
            // same abnormal case as one that arrives over the cap — the peer
            // opening channels at a connection that is visibly going away —
            // and must not be allowed to extend a teardown that has already
            // spent that budget on every channel ahead of it.
            for session in closing { session.channel.close(retrying: round == 0) }
            sessions.removeAll { candidate in closing.contains { $0 === candidate } }
        }
    }

    /// Runs one channel's read/parse/reply passes. Returns whether any work
    /// happened, and whether the channel is finished (EOF or a protocol
    /// error) and should be closed and dropped by the caller.
    ///
    /// Answers what has already been reassembled and reads more off the
    /// channel only once there is nothing left to answer — not the other way
    /// round. Reading is what makes both buffers grow, so a pass that drained
    /// the channel dry first and parsed afterwards let the remote decide how
    /// much of this app's memory its own traffic turned into. This way the
    /// framer never holds more than the one partly-arrived frame it is
    /// waiting to complete, and the two bounds below decide when the pass
    /// stops taking on work: `maximumQueuedReplyBytes` and
    /// `maximumSignRequestsPerPass`, each documented where it is defined.
    ///
    /// Nothing the bounds decline is lost — it stays framed and is answered
    /// on the following pass, which the event loop reaches immediately, since
    /// a pass that did work never sleeps.
    private func service(_ session: Session) -> (didWork: Bool, done: Bool) {
        let channel = session.channel
        var didWork = false
        var signRequests = 0

        while session.outbound.count < Self.maximumQueuedReplyBytes,
              signRequests < Self.maximumSignRequestsPerPass {
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

            guard let payload else {
                // Everything reassembled has been answered: take one more
                // chunk off the channel and come back around.
                var chunk = [UInt8](repeating: 0, count: Self.readChunkSize)
                let n = channel.read(into: &chunk)
                if n > 0 {
                    session.framer.append(chunk[0..<n])
                    didWork = true
                    continue
                }
                if n == 0 { return (didWork, true) }   // EOF: nothing more will ever arrive
                break   // EAGAIN or a transient error: nothing more right now
            }

            let request: AgentRequest
            do {
                request = try AgentRequest.parse(payload)
            } catch {
                return (true, true)
            }
            if case .sign = request { signRequests += 1 }

            session.outbound.append(contentsOf: respond(to: request))
            didWork = true
        }

        // Written last and unconditionally: the loop above stops on a bound
        // rather than on an empty queue, so `outbound` routinely still holds
        // replies the channel has not taken yet. The cap is also what keeps
        // `removeFirst` here cheap — it never shifts more than a capped
        // queue, however much the remote asked for.
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
            // The same reasoning, and the same refusal, for a request this
            // signer would turn down anyway: a bare `ssh-rsa` (SHA-1) or a
            // key whose algorithm it has no signer for. Which of those
            // applies is settled by the algorithm and the flags alone — no
            // key material, nothing that can fail halfway — so settling it
            // here costs nothing, where doing it after the prompt spends the
            // user's attention on a signature that was never going to be
            // produced.
            guard (try? AgentSigner.signingAlgorithm(for: identity.algorithm, flags: flags)) != nil else {
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
    /// Waits for the socket to be ready in whichever direction libssh2 is
    /// blocked on — the same helper `LibSSH2Transport` uses everywhere else
    /// — handed in because this class holds neither a session nor a socket
    /// of its own. Called only between retries `close(retrying:)` has
    /// already decided to make; see `LibSSH2Transport.closeAttempt`.
    private let waitForSocket: () -> Void

    init(channel: OpaquePointer, waitForSocket: @escaping () -> Void) {
        self.channel = channel
        self.waitForSocket = waitForSocket
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

    /// `retrying: true` retries the close against EAGAIN, up to
    /// `LibSSH2Transport.closeRetryAttempts` times, before freeing — a
    /// single un-retried `libssh2_channel_close` ordinarily returns EAGAIN,
    /// and `_libssh2_channel_free` refuses to actually free a channel whose
    /// local side hasn't finished closing, so skipping the retry entirely
    /// would leave the channel stuck in `session->channels` for good:
    /// libssh2 keeps queuing its inbound CHANNEL_DATA into `session->packets`
    /// with nothing left to drain it. `retrying: false` makes exactly one
    /// attempt — for a peer that may never answer, where waiting even a
    /// bounded amount is a self-inflicted freeze of a still-live shell.
    /// Either way `libssh2_channel_free` runs regardless of whether the close
    /// actually completed. Be precise about what that costs when it fails:
    /// `_libssh2_channel_free` returns EAGAIN without freeing while the local
    /// side is still open, and `libssh2_session_free` in turn bails on the
    /// first channel it cannot free — so a teardown against a peer that never
    /// sends CHANNEL_CLOSE leaks the whole `LIBSSH2_SESSION`, not merely one
    /// channel struct. That is still bounded (one session per failed teardown,
    /// not unbounded growth) and it cannot block, because every call here is
    /// non-blocking. A frozen terminal the user cannot even close is worse on
    /// both counts, which is why this trade is made deliberately.
    ///
    /// Only ever called from `ForwardedAgent.service()` or `.close()` — both
    /// run from the event loop, off the AUTHAGENT callback's stack, which is
    /// what makes calling into libssh2 here safe at all. `adopt` never calls
    /// this.
    func close(retrying: Bool) {
        LibSSH2Transport.closeAttempt(retrying: retrying,
                                      maximumAttempts: LibSSH2Transport.closeRetryAttempts,
                                      op: { [channel] in libssh2_channel_close(channel) },
                                      waitForSocket: waitForSocket)
        libssh2_channel_free(channel)
    }
}
#endif
