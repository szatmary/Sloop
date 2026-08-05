import SwiftUI
import SloopKit

/// An interactive `HostKeyVerifier`. When the SSH loop meets an unknown host
/// key, it blocks that background thread while a SwiftUI sheet asks the user to
/// trust the fingerprint, then returns their decision.
///
/// A single shared instance is observed by the UI and injected into new SSH
/// transports, so any connection's prompt surfaces over the app.
///
/// `shouldTrust` MUST be called off the main thread (it is — from the libssh2
/// connection thread); calling it on main would deadlock the prompt.
final class HostKeyPrompter: ObservableObject, HostKeyVerifier {
    static let shared = HostKeyPrompter()

    struct Prompt: Identifiable {
        let id = UUID()
        let endpoint: String
        let keyType: String
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        DispatchQueue.main.async {
            self.prompt = Prompt(endpoint: endpoint, keyType: keyType, fingerprint: fingerprint) { trusted in
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
