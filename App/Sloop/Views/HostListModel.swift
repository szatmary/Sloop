import SwiftUI
import SloopKit

/// View model backing `HostListView`. Owns the host list, the known-hosts
/// database, and the credential store, and turns a saved `SSHHost` into a live
/// `TerminalSession` at connect time.
@MainActor
final class HostListModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []

    private let store = HostStore()
    private let knownHosts = KnownHostsStore()
    private let credentials: CredentialStore

    init() {
        #if canImport(Security)
        credentials = KeychainCredentialStore()
        #else
        credentials = InMemoryCredentialStore()
        #endif
        hosts = store.hosts
    }

    func newHost() -> SSHHost {
        SSHHost(alias: "new host", hostname: "", username: "")
    }

    /// Save a host and, if a new secret was entered, its credential. A `nil`
    /// credential means "leave the stored secret untouched".
    func save(_ host: SSHHost, credential: Credential?) {
        store.upsert(host)
        if let credential {
            try? credentials.setCredential(credential, for: host.id)
        }
        hosts = store.hosts
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let host = hosts[index]
            try? credentials.removeCredential(for: host.id)
            store.remove(host)
        }
        hosts = store.hosts
    }

    /// Build a session for a host, pulling its credential from the store. The
    /// session holds a factory (not a single transport) so it can reconnect by
    /// building a fresh connection.
    ///
    /// When the host prefers Mosh, the transport is a `MoshOrSSHTransport`: it
    /// probes `mosh-server` and either uses Mosh or falls back to a plain SSH
    /// shell (the Mosh UDP transport isn't wired yet, so today it always falls
    /// back — the terminal shows which mode it got).
    func connect(_ host: SSHHost) -> TerminalSession {
        let credential = credentials.credential(for: host.id) ?? Credential()
        let knownHosts = self.knownHosts

        let makeSSH: () -> Transport = {
            TransportFactory.ssh(host: host,
                                 credential: credential,
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: HostKeyPrompter.shared)
        }

        return TerminalSession(title: host.alias) {
            guard host.useMosh else { return makeSSH() }
            // The real Mosh UDP/SSP transport is only built into the Mosh variant
            // (project.mosh.yml, which defines SLOOP_MOSH); elsewhere
            // `makeMoshTransport` stays nil and the composite transport falls back
            // to SSH after probing.
            var makeMosh: ((MoshBootstrap) -> Transport)? = nil
            #if SLOOP_MOSH
            makeMosh = { bootstrap in
                MoshTransport(host: host.hostname, bootstrap: bootstrap)
            }
            #endif
            return MoshOrSSHTransport(
                useMosh: true,
                makeCommandRunner: {
                    CommandRunnerFactory.ssh(host: host,
                                             credential: credential,
                                             knownHosts: knownHosts,
                                             hostKeyVerifier: HostKeyPrompter.shared)
                },
                makeSSHTransport: makeSSH,
                makeMoshTransport: makeMosh)
        }
    }
}
