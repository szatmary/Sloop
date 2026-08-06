import SwiftUI
import SloopKit

/// An interactive `HostKeyVerifier`. When the SSH loop meets an unknown host key
/// — or a *changed* key for a known host — it blocks that background thread
/// while a SwiftUI sheet asks the user what to do, then returns their decision.
///
/// A single shared instance is observed by the UI and injected into new SSH
/// transports, so any connection's prompt surfaces over the app.
///
/// The decision methods MUST be called off the main thread (they are — from the
/// libssh2 connection thread); calling them on main would deadlock the prompt.
final class HostKeyPrompter: ObservableObject, HostKeyVerifier {
    static let shared = HostKeyPrompter()

    /// Why we're prompting: a first-time key (trust-on-first-use) or a key that
    /// changed from what we had on record (a possible MITM — a stronger warning).
    enum Kind {
        case unknown
        case changed(previousFingerprint: String)
    }

    struct Prompt: Identifiable {
        let id = UUID()
        let kind: Kind
        let endpoint: String
        let keyType: String
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        ask(kind: .unknown, endpoint: endpoint, keyType: keyType, fingerprint: fingerprint)
    }

    func shouldTrustChangedKey(endpoint: String,
                               keyType: String,
                               fingerprint: String,
                               previousFingerprint: String) -> Bool {
        ask(kind: .changed(previousFingerprint: previousFingerprint),
            endpoint: endpoint, keyType: keyType, fingerprint: fingerprint)
    }

    /// Present a prompt on the main thread and block the calling (SSH) thread
    /// until the user resolves it.
    private func ask(kind: Kind, endpoint: String, keyType: String, fingerprint: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        DispatchQueue.main.async {
            self.prompt = Prompt(kind: kind, endpoint: endpoint, keyType: keyType, fingerprint: fingerprint) { trusted in
                decision.value = trusted
                self.prompt = nil
                semaphore.signal()
            }
        }
        semaphore.wait()
        return decision.value
    }

    /// Carries the decision from the main thread (the sheet) back to the waiting
    /// SSH thread; the semaphore provides the happens-before ordering.
    private final class Decision { var value = false }
}
