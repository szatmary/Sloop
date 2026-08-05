import SwiftUI
import SloopKit

/// View model backing `HostListView`: owns the `HostStore` and turns a saved
/// `Host` into a live `TerminalSession` at connect time.
@MainActor
final class HostListModel: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    private let store = HostStore()

    init() { hosts = store.hosts }

    func newHost() -> Host {
        Host(alias: "new host", hostname: "", username: "")
    }

    func save(_ host: Host) {
        store.upsert(host)
        hosts = store.hosts
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { store.remove(hosts[index]) }
        hosts = store.hosts
    }

    /// Build a session for a host. Credentials come from the keychain later; for
    /// now this hands the SSH transport an empty credential (it will report
    /// `.notImplemented` and the terminal shows the fallback message).
    func connect(_ host: Host) -> TerminalSession {
        let transport = LibSSH2Transport(host: host, credential: Credential())
        return TerminalSession(title: host.alias, transport: transport)
    }
}
