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
    private let keys: KeyStore
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if canImport(Security)
        credentials = KeychainCredentialStore()
        keys = KeychainKeyStore()
        #else
        credentials = InMemoryCredentialStore()
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

        let makeSSH: () -> Transport = {
            TransportFactory.ssh(host: host,
                                 credential: credential,
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: HostKeyPrompter.shared)
        }

        return TerminalSession(title: host.alias,
                               onConnectCommand: host.trimmedOnConnectCommand) {
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
