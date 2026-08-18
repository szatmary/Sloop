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
    private let accessTokens: AccessTokenStore

    init() {
        #if canImport(Security)
        credentials = KeychainCredentialStore()
        accessTokens = KeychainAccessTokenStore()
        #else
        credentials = InMemoryCredentialStore()
        accessTokens = InMemoryAccessTokenStore()
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

    /// Import hosts from OpenSSH config text, skipping aliases that already
    /// exist. Secrets aren't in the config, so imported hosts use password auth
    /// until the user edits them. Returns the number of new hosts added.
    @discardableResult
    func importConfig(_ text: String) -> Int {
        let existing = Set(hosts.map(\.alias))
        var added = 0
        for host in SSHConfigParser.parse(text) where !existing.contains(host.alias) {
            store.upsert(host)
            added += 1
        }
        hosts = store.hosts
        return added
    }

    func delete(at offsets: IndexSet) {
        // Resolve hosts up front: `delete(_:)` refreshes `hosts`, which would
        // shift the remaining offsets.
        for host in offsets.map({ hosts[$0] }) {
            delete(host)
        }
    }

    func delete(_ host: SSHHost) {
        try? credentials.removeCredential(for: host.id)
        store.remove(host)
        hosts = store.hosts
    }

    /// True when connecting to this host must be preceded by a Cloudflare
    /// Access browser login (no stored token, or it expired).
    func needsAccessLogin(_ host: SSHHost) -> Bool {
        host.connectionMethod == .cloudflareAccess
            && accessTokens.validToken(for: host.hostname) == nil
    }

    /// Persist a freshly captured Access token for the host's hostname.
    func storeAccessToken(_ raw: String, for host: SSHHost) throws {
        try accessTokens.setRawToken(raw, for: host.hostname)
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
        let accessTokens = self.accessTokens

        // Resolves the Access token at call time, so a reconnect after a fresh
        // login picks up the new token.
        let makeSSH: () -> Transport = {
            TransportFactory.ssh(host: host,
                                 credential: credential,
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: HostKeyPrompter.shared,
                                 accessTokens: accessTokens)
        }

        return TerminalSession(title: host.alias) {
            // Mosh needs UDP, which no tunnel method carries — tunneled hosts
            // are SSH-only regardless of the saved toggle.
            guard host.useMosh, host.connectionMethod == .direct else { return makeSSH() }
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
