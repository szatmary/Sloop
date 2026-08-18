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

/// Speaks the ssh-agent wire protocol over a second SSH channel, answering
/// from a fixed, host-approved set of keys rather than a real ssh-agent
/// socket.
///
/// Deliberately separate from `LibSSH2Transport`: everything here is
/// reasoned about — and tested — through `AgentChannel` alone, with no
/// socket and no real libssh2 channel involved. The two calls that do touch
/// libssh2 (deriving identities, producing a signature) are already isolated
/// inside `AgentSigner`.
final class ForwardedAgent {
    private let signer: AgentSigner
    private let confirming: AgentSignConfirming
    private let endpoint: String

    private var channel: AgentChannel?
    private var framer = AgentFramer()
    private var outbound: [UInt8] = []

    /// Comfortably larger than any single agent message this app produces or
    /// expects to receive in one read; OpenSSH's own agent client reads in
    /// similarly-sized chunks.
    private static let readChunkSize = 4096

    init(signer: AgentSigner, confirming: AgentSignConfirming, endpoint: String) {
        self.signer = signer
        self.confirming = confirming
        self.endpoint = endpoint
    }

    /// Called with the channel libssh2 just opened for the remote's
    /// forwarding request. Closes and replaces whatever channel was
    /// previously adopted, resetting reassembly state with it, so a
    /// re-adopted agent never mixes bytes from two different channels.
    func adopt(_ channel: AgentChannel) {
        close()
        self.channel = channel
    }

    /// Reads what's available, answers whatever complete requests arrived,
    /// and flushes whatever replies fit. Returns true if it did anything —
    /// read a byte, produced a reply, or wrote one — so the caller's poll
    /// loop can tell a serviced pass from an idle one, and not sleep for
    /// 200 ms with a reply already sitting in `outbound`.
    @discardableResult
    func service() -> Bool {
        guard let channel else { return false }
        var didWork = false
        var eof = false

        while true {
            var chunk = [UInt8](repeating: 0, count: Self.readChunkSize)
            let n = channel.read(into: &chunk)
            if n > 0 {
                framer.append(chunk[0..<n])
                didWork = true
            } else if n == 0 {
                eof = true
                break
            } else {
                break   // EAGAIN or a transient error: nothing more right now
            }
        }

        while true {
            let payload: [UInt8]?
            do {
                payload = try framer.nextPayload()
            } catch {
                // The remote's byte stream no longer means anything we can
                // trust — guessing at a "recovery" risks reading a later
                // message's bytes as this one's tail. A remote that cannot
                // frame correctly is not one to keep talking to.
                close()
                return true
            }
            guard let payload else { break }

            let request: AgentRequest
            do {
                request = try AgentRequest.parse(payload)
            } catch {
                close()
                return true
            }

            outbound.append(contentsOf: respond(to: request))
            didWork = true
        }

        while !outbound.isEmpty {
            let n = channel.write(outbound)
            guard n > 0 else { break }
            outbound.removeFirst(n)
            didWork = true
        }

        if eof {
            close()
            return true
        }
        return didWork
    }

    func close() {
        channel?.close()
        channel = nil
        outbound.removeAll()
        framer = AgentFramer()
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

    init(channel: OpaquePointer) {
        self.channel = channel
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

    /// Best-effort, unlike the shell channel's teardown in
    /// `LibSSH2Transport.run()`: this has no `sock` to retry an EAGAIN close
    /// against without threading one through from the transport. A single
    /// close attempt, then freeing the local channel struct regardless, is
    /// enough — freeing doesn't depend on the close packet having actually
    /// gone out, and this channel is never the last thing standing between
    /// the app and a clean disconnect; the shell channel's own teardown, and
    /// the session disconnect after it, still run.
    func close() {
        _ = libssh2_channel_close(channel)
        libssh2_channel_free(channel)
    }
}
#endif
