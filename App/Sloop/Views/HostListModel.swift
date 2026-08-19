// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit
import SloopSSH

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

    /// Why the shared container couldn't be opened, if it couldn't. Shown
    /// instead of a host list: an empty list is what a fresh install looks
    /// like, and telling someone whose hosts are sitting in the App Group
    /// container that they have none is the same mistake `libraryError` exists
    /// to avoid one layer up.
    @Published private(set) var storageError: String?

    /// Why a host couldn't be published to (or withdrawn from) Files.app.
    /// Separate from `storageError` because it is recoverable and narrow: the
    /// host is saved either way, only its Files location is out of step.
    @Published private(set) var filesError: String?

    /// Nil when the shared container couldn't be opened — see `storageError`.
    /// Optional rather than defaulted to a private location: a store pointing
    /// somewhere the extension can't see is worse than no store, because it
    /// accepts writes and looks like it worked.
    private let store: HostStore?
    private let knownHosts: KnownHostsStore?
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

        // The host list and known-hosts database move into the App Group
        // container so the File Provider extension — a separate process, alive
        // when the app is not — reads the same files the app writes. Existing
        // installs have them in the app's private Application Support; they are
        // copied across once, byte for byte. See SloopStorage.migrateLegacyFile
        // for why a copy rather than a decode/re-encode.
        do {
            let shared = try SloopStorage.sharedDirectory()
            let legacy = try? SloopStorage.legacyApplicationSupportDirectory()
            if let legacy {
                try SloopStorage.migrateLegacyFile(
                    from: legacy.appendingPathComponent("sloop-hosts.json"),
                    to: SloopStorage.hostsFile(in: shared))
                try SloopStorage.migrateLegacyFile(
                    from: legacy.appendingPathComponent("sloop-known-hosts.json"),
                    to: SloopStorage.knownHostsFile(in: shared))
            }
            store = HostStore(fileURL: SloopStorage.hostsFile(in: shared))
            knownHosts = KnownHostsStore(fileURL: SloopStorage.knownHostsFile(in: shared))
        } catch {
            store = nil
            knownHosts = nil
            storageError = error.localizedDescription
        }

        hosts = store?.hosts ?? []

        // FIRST: per-host credentials and Access tokens predate the extension
        // and landed in the app's private keychain group, which the extension
        // cannot read at all. Unmigrated, every published host fails to
        // authenticate with what looks like a wrong password — on a host whose
        // password is plainly right in the app.
        //
        // Before the PEM lift below, not after. `credentials` now reads from the
        // shared group, so running the lift first found nothing, lifted nothing,
        // and then recorded itself as complete forever — leaving the key library
        // permanently missing the keys it exists to hold.
        var keychainMigrationFailed = false
        do {
            try SloopKeychainMigration.migrateToSharedAccessGroup()
        } catch {
            keychainMigrationFailed = true
            libraryError = error.localizedDescription
        }

        // Lift legacy per-host PEMs into the library, but only once per
        // device: KeyLibrary.migrate is idempotent in the sense that it never
        // overwrites an existing entry, but it has no way to know a name is
        // missing *because the user removed it*. Running it unconditionally
        // at every launch would resurrect keys removed via `sloop
        // remove-key`. See migratedLegacyPEMsDefaultsKey.
        //
        // Skipped entirely when the host list or the keychain migration is
        // unavailable. With no hosts it trivially "succeeds" over an empty
        // array, and the marker below would then record a migration that never
        // examined anything as done for good.
        if !defaults.bool(forKey: Self.migratedLegacyPEMsDefaultsKey),
           !keychainMigrationFailed, store != nil {
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

    /// Brings Files.app's locations in line with the host list.
    ///
    /// Called from the host list's `.task`, deliberately not from `init`.
    /// `NSFileProviderManager` is a system service, and asking it anything
    /// while the app is still constructing its model puts an XPC round trip on
    /// the launch path — which in an unsigned or ad-hoc build does not merely
    /// fail, it hangs the process before it draws anything. A model's
    /// initializer should not be able to prevent the app from starting.
    func syncFilesDomains() async {
        let hosts = self.hosts
        do {
            try await FilesDomainRegistrar.reconcile(hosts: hosts)
            filesError = nil
        } catch {
            filesError = error.localizedDescription
        }
    }

    /// The host store, or the reason there isn't one.
    ///
    /// Every mutation goes through this rather than silently doing nothing when
    /// the container is unreachable: a save that quietly no-ops is
    /// indistinguishable from a save that worked until the user relaunches and
    /// finds the host gone.
    private func requireStore() throws -> HostStore {
        guard let store else {
            throw SloopStorage.StorageError.appGroupUnavailable(SloopStorage.appGroupIdentifier)
        }
        return store
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
        let store = try requireStore()
        store.upsert(host)
        hosts = store.hosts
        if let credential {
            try credentials.setCredential(credential, for: host.id)
        }
        reconcileFilesDomains()
    }

    /// Kicks off a domain reconcile after the host list changed.
    ///
    /// Deliberately not part of `save`'s throwing contract: a host must save
    /// even if the system refuses the domain, and reporting a File Provider
    /// failure as "couldn't save the host" would send the user looking in the
    /// wrong place entirely.
    private func reconcileFilesDomains() {
        Task { await syncFilesDomains() }
    }

    /// Import hosts from OpenSSH config text, skipping aliases that already
    /// exist. Secrets aren't in the config, so imported hosts use password auth
    /// until the user edits them. Returns the number of new hosts added.
    @discardableResult
    func importConfig(_ text: String) throws -> Int {
        let store = try requireStore()
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
        let store = try requireStore()
        store.remove(host)
        hosts = store.hosts
        // Before the credential goes: a domain outliving its host fails every
        // request with "this host no longer exists" and cannot be removed from
        // Files.app by the user.
        reconcileFilesDomains()
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
        // Resolved here, not inside TransportFactory: this is where the
        // `keys` store lives, and TransportFactory only ever sees a
        // resolved `Credential`, not a store to resolve more keys from.
        let forwardedKeys = try KeyLibrary.forwardedKeys(for: host, keys: keys)
        // Without the known-hosts database there is nothing to check a host key
        // against, and connecting anyway would mean trusting whatever answered.
        guard let knownHosts else {
            throw SloopStorage.StorageError.appGroupUnavailable(SloopStorage.appGroupIdentifier)
        }
        let accessTokens = self.accessTokens

        // Resolves the Access token at call time, so a reconnect after a fresh
        // login picks up the new token.
        let makeSSH: () -> Transport = {
            TransportFactory.ssh(host: host,
                                 credential: credential,
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: HostKeyPrompter.shared,
                                 accessTokens: accessTokens,
                                 forwardedKeys: forwardedKeys,
                                 signConfirmer: AgentSignPrompter.shared,
                                 authorizationPresenter: TailscaleAuthPrompter.shared)
        }

        return TerminalSession(title: host.alias,
                               onConnectCommand: host.trimmedOnConnectCommand,
                               hostID: host.id,
                               suggestsCommands: host.suggestions) {
            // A tunneled method can't carry Mosh's UDP leg (see
            // `ConnectionMethod.carriesMosh`), and the editor won't let the
            // toggle be on for one — this guard covers hosts saved before that
            // was true.
            guard host.useMosh, host.connectionMethod.carriesMosh else { return makeSSH() }
            return MoshOrSSHTransport(
                useMosh: true,
                makeCommandRunner: {
                    CommandRunnerFactory.ssh(host: host,
                                             credential: credential,
                                             knownHosts: knownHosts,
                                             hostKeyVerifier: HostKeyPrompter.shared,
                                             accessTokens: accessTokens,
                                             authorizationPresenter: TailscaleAuthPrompter.shared)
                },
                makeSSHTransport: makeSSH,
                // Nil in a build without mosh.xcframework, which the composite
                // reads as "probe, then use SSH" — the terminal still says which
                // mode the session got.
                makeMoshTransport: MoshTransportFactory.make(for: host))
        }
    }
}
