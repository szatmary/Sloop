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

    /// Build a session for a host, pulling its credential from the store.
    func connect(_ host: SSHHost) -> TerminalSession {
        let credential = credentials.credential(for: host.id) ?? Credential()
        let transport = TransportFactory.ssh(host: host,
                                             credential: credential,
                                             knownHosts: knownHosts)
        return TerminalSession(title: host.alias, transport: transport)
    }
}
