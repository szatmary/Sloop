// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// View model backing `HostListView`. Owns the host list, the known-hosts
/// database, and the credential store, and turns a saved `SSHHost` into a live
/// `TerminalSession` at connect time.
@MainActor
final class HostListModel: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []

    /// The shared key library, re-read whenever it changes. Held here rather
    /// than fetched by the editor because reading it can fail, and a SwiftUI
    /// view builder has nowhere to put an error.
    @Published private(set) var libraryKeys: [NamedKey] = []

    /// Why the key library couldn't be read, if it couldn't. Shown in place of
    /// the key picker: an empty picker would say "you have no keys", which is
    /// what a missing entitlement looks like and is exactly the wrong thing to
    /// tell someone whose keys are sitting in iCloud Keychain.
    @Published private(set) var libraryError: String?

    /// `UserDefaults` key marking that `KeyLibrary.migrate` has already run on
    /// this device. `KeyLibrary.migrate` is pure and never overwrites an
    /// existing library entry, which means it can't distinguish "never
    /// migrated" from "migrated, then the user removed the key via `sloop
    /// remove-key`" — running it again after a removal would silently
    /// re-create the removed key. Gating it behind this once-per-device
    /// marker is what makes `remove-key` an actual, lasting removal.
    private static let migratedLegacyPEMsDefaultsKey = "sloop.keyLibrary.migratedLegacyPEMs"

    private let store = HostStore()
    private let knownHosts = KnownHostsStore()
    private let credentials: CredentialStore
    private let accessTokens: AccessTokenStore
    private let keys: KeyStore
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if canImport(Security)
        credentials = KeychainCredentialStore()
        accessTokens = KeychainAccessTokenStore()
        keys = KeychainKeyStore()
        #else
        credentials = InMemoryCredentialStore()
        accessTokens = InMemoryAccessTokenStore()
        keys = InMemoryKeyStore()
        #endif
        hosts = store.hosts
        // Lift legacy per-host PEMs into the library, but only once per
        // device: KeyLibrary.migrate is idempotent in the sense that it never
        // overwrites an existing entry, but it has no way to know a name is
        // missing *because the user removed it*. Running it unconditionally
        // at every launch would resurrect keys removed via `sloop
        // remove-key`. See migratedLegacyPEMsDefaultsKey.
        if !defaults.bool(forKey: Self.migratedLegacyPEMsDefaultsKey) {
            do {
                try KeyLibrary.migrate(hosts: hosts, credentials: credentials, keys: keys)
                // Only mark it done if it actually finished. A migration that
                // failed on a locked or unreadable keychain must run again next
                // launch, not be recorded as complete.
                defaults.set(true, forKey: Self.migratedLegacyPEMsDefaultsKey)
            } catch {
                libraryError = error.localizedDescription
            }
        }
        refreshLibraryKeys()
    }

    /// Re-read the key library, capturing why if it can't be read.
    private func refreshLibraryKeys() {
        do {
            libraryKeys = try keys.keys()
            libraryError = nil
        } catch {
            libraryKeys = []
            libraryError = error.localizedDescription
        }
    }

    func newHost() -> SSHHost {
        SSHHost(alias: "new host", hostname: "", username: "")
    }

    /// Store a pasted key into the shared library.
    func saveLibraryKey(_ key: NamedKey) throws {
        try keys.setKey(key)
        refreshLibraryKeys()
    }

    /// Save a host and, if a new secret was entered, its credential. A `nil`
    /// credential means "leave the stored secret untouched".
    ///
    /// Throws if the secret can't be stored. Swallowing that wrote the host to
    /// disk and dropped its password on the floor, so the save looked like it
    /// worked and every later connect failed to authenticate.
    func save(_ host: SSHHost, credential: Credential?) throws {
        store.upsert(host)
        hosts = store.hosts
        if let credential {
            try credentials.setCredential(credential, for: host.id)
        }
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

    func delete(at offsets: IndexSet) throws {
        // Resolve hosts up front: `delete(_:)` refreshes `hosts`, which would
        // shift the remaining offsets.
        for host in offsets.map({ hosts[$0] }) {
            try delete(host)
        }
    }

    /// Delete a host and its stored secret. Throws if the secret survives the
    /// host — leaving a password in the keychain for a host that no longer
    /// exists, with nothing in the UI that could ever remove it.
    func delete(_ host: SSHHost) throws {
        store.remove(host)
        hosts = store.hosts
        try credentials.removeCredential(for: host.id)
        // A bearer credential outliving the user's decision to delete the
        // host is wrong on its own: the token is a live means of connecting
        // as this host and must not survive it. But the token is keyed by
        // hostname, so it may belong to hosts that are still here — deleting
        // one entry for a shared Access bastion silently signed the user out
        // of the others. Checked after the store update, so `hosts` is what
        // actually remains.
        if host.connectionMethod == .cloudflareAccess,
           !accessTokenIsStillNeeded(for: host.hostname, by: hosts) {
            try accessTokens.removeToken(for: host.hostname)
        }
    }

    /// True when connecting to this host must be preceded by a Cloudflare
    /// Access browser login (no stored token, or it expired).
    func needsAccessLogin(_ host: SSHHost) throws -> Bool {
        try host.connectionMethod == .cloudflareAccess
            && accessTokens.validToken(for: host.hostname) == nil
    }

    /// Persist a freshly captured Access token for the host's hostname.
    func storeAccessToken(_ raw: String, for host: SSHHost) throws {
        try accessTokens.setRawToken(raw, for: host.hostname)
    }

    /// Clear the stored Cloudflare Access token for this host, so the next
    /// connection attempt opens a fresh browser login. This is the user's
    /// manual escape from a token the edge keeps rejecting (see
    /// `TokenClearingDialer` in `TransportFactory`, which does the same
    /// thing automatically on a rejected dial) — a way out without waiting
    /// for the JWT's own `exp` to pass.
    ///
    /// Hostname-wide, unlike `delete(_:)`: the token is one Access
    /// application's session, and a user asking to sign out of it means all
    /// of it, including any other saved host sitting behind the same Access
    /// hostname.
    ///
    /// Clearing the stored token is enough to make this a real sign-out:
    /// `AccessLoginView` runs on a non-persistent website data store, so the
    /// web view keeps no `CF_Authorization` cookie of its own between
    /// presentations and the next sheet has to go through Access and the IdP
    /// again. (When it kept a persistent store, the sheet re-captured the very
    /// token this method had just removed, which made signing out a no-op.)
    func signOutOfCloudflareAccess(_ host: SSHHost) throws {
        try accessTokens.removeToken(for: host.hostname)
    }

    /// Build a session for a host, pulling its credential from the store. The
    /// session holds a factory (not a single transport) so it can reconnect by
    /// building a fresh connection.
    ///
    /// When the host prefers Mosh, the transport is a `MoshOrSSHTransport`: it
    /// probes `mosh-server` and either uses Mosh or falls back to a plain SSH
    /// shell (the Mosh UDP transport isn't wired yet, so today it always falls
    /// back — the terminal shows which mode it got).
    ///
    /// Throws if the host's key or password can't be read. Connecting anyway
    /// with an empty credential is what turned an unreadable keychain into a
    /// bare "auth failed" on the server side, with nothing pointing at the
    /// actual cause.
    func connect(_ host: SSHHost) throws -> TerminalSession {
        let credential = try KeyLibrary.credential(for: host, keys: keys, credentials: credentials)
            ?? Credential()
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

        return TerminalSession(title: host.alias,
                               onConnectCommand: host.trimmedOnConnectCommand) {
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
