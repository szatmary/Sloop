// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SwiftUI
import SloopKit

/// Add/edit form for a `Host`. Secrets (password or private key) are collected
/// here and stored in the keychain via the `CredentialStore`, never in the
/// plain-JSON host list.
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var authKind: AuthKind = .password
    @State private var password: String = ""
    @State private var selectedKeyName: String = ""
    @State private var pastedPEM: String = ""
    @State private var pastedName: String = ""
    @State private var pastedPassphrase: String = ""
    @State private var saveError: String?
    @State private var showingMoshHelp = false
    @Environment(\.openURL) private var openURL
    /// Where "Open in Files" goes, once this host's domain exists. Resolved
    /// asynchronously because it requires a round trip to the File Provider
    /// system, and held here because a SwiftUI view builder cannot await.
    @State private var filesURL: URL?
    @FocusState private var commandFocused: Bool

    /// Ready-made on-connect commands. Reattaching to a multiplexer is why
    /// this feature exists, so the list covers the two people actually use;
    /// anything else is typed by hand.
    private static let suggestions: [(title: String, command: String)] = [
        ("Reattach to tmux, or start it", "tmux attach || tmux new"),
        ("Reattach to GNU screen, or start it", "screen -RD"),
    ]
    private let libraryKeys: [NamedKey]
    /// Set when the key library couldn't be read at all. Distinct from an empty
    /// library, and shown as such — an empty picker would tell someone whose
    /// keys are safe in iCloud Keychain that they have none.
    private let libraryError: String?
    private let onSaveKey: (NamedKey) throws -> Void
    private let onSave: (SSHHost, Credential?) throws -> Void

    private enum AuthKind: String, CaseIterable, Identifiable, Hashable {
        case password = "Password"
        case privateKey = "Private Key"
        var id: String { rawValue }
    }

    /// Pasted name/PEM with leading/trailing whitespace removed. Used for
    /// both the disabled-check (so a whitespace-only paste doesn't count as
    /// "filled in") and for what actually gets stored, so a stray leading
    /// space or trailing newline from a copy-paste never ends up baked into
    /// the library entry.
    private var trimmedPastedName: String {
        pastedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedPastedPEM: String {
        pastedPEM.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(host: SSHHost,
         libraryKeys: [NamedKey] = [],
         libraryError: String? = nil,
         onSaveKey: @escaping (NamedKey) throws -> Void = { _ in },
         onSave: @escaping (SSHHost, Credential?) throws -> Void) {
        _host = State(initialValue: host)
        self.libraryKeys = libraryKeys
        self.libraryError = libraryError
        self.onSaveKey = onSaveKey
        self.onSave = onSave
        if case .publicKey(let name) = host.auth {
            _authKind = State(initialValue: .privateKey)
            _selectedKeyName = State(initialValue: name)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Alias", text: $host.alias)
                        #if os(iOS)
                        // Host names are lowercase far more often than not, and
                        // iOS capitalising the first letter meant a lowercase
                        // alias could not be typed at all without fighting the
                        // keyboard. Hostname and Username already opt out.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Hostname", text: $host.hostname)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Username", text: $host.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    // Driven by the enum, not by a hand-written pair: a host
                    // saved as .tailscale used to open this editor with no
                    // matching option at all, so the picker showed nothing
                    // selected and saving silently reinterpreted the host.
                    Picker("Connect via", selection: $host.connectionMethod) {
                        ForEach(ConnectionMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    // A switch rather than an if/else, so a new connection
                    // method has to answer "and what does its port mean?"
                    // here rather than inheriting whatever the else branch
                    // happens to do.
                    switch host.connectionMethod {
                    case .direct:
                        Stepper("Port: \(host.port)", value: $host.port, in: 1...65535)
                    case .cloudflareAccess:
                        // No port: wss/443 outside the tunnel, sshd inside it.
                        Text("The hostname above is the Access application's public hostname. A browser sign-in runs on first connect.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .tailscale:
                        // The port is a real port here — the hostname is a
                        // MagicDNS name or tailnet address and sshd listens
                        // on it as usual.
                        Stepper("Port: \(host.port)", value: $host.port, in: 1...65535)
                        Text("For devices without Tailscale installed — Sloop joins the tailnet itself. If you already run the Tailscale app here, choose Direct instead and use the MagicDNS name: the system VPN already routes it, and that path is in use today.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $authKind) {
                        ForEach(AuthKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authKind {
                    case .password:
                        SecureField("Password", text: $password)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    case .privateKey:
                        if let libraryError {
                            Label(libraryError, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Picker("Key", selection: $selectedKeyName) {
                            Text("Paste new key…").tag("")
                            ForEach(libraryKeys) { key in
                                Text(key.name).tag(key.name)
                            }
                        }
                        if selectedKeyName.isEmpty {
                            TextField("Key name (e.g. id_ed25519)", text: $pastedName)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Private key (PEM)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $pastedPEM)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(minHeight: 120)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    #endif
                            }
                            SecureField("Key passphrase (optional)", text: $pastedPassphrase)
                            Text("Saved to the key library (iCloud Keychain), shared by all your hosts and devices. On a Mac, `sloop import-key` is quicker.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Secrets live in the keychain, never in the host list. Leave the password blank to keep the existing one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("No command",
                                  text: Binding(get: { host.onConnectCommand ?? "" },
                                                set: { host.onConnectCommand = $0 }))
                            .font(.system(.body, design: .monospaced))
                            .focused($commandFocused)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif

                        // macOS has no keyboard accessory to hang the
                        // suggestions off, so they live in a menu beside the
                        // field instead.
                        #if os(macOS)
                        Menu {
                            ForEach(Self.suggestions, id: \.command) { suggestion in
                                Button(suggestion.command) {
                                    host.onConnectCommand = suggestion.command
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Common commands")
                        #endif
                    }

                } header: {
                    Text("Run on connect")
                } footer: {
                    Text("Typed into the shell on every connect, including reconnects.")
                }

                Section("Options") {
                    HStack {
                        Toggle("Use Mosh", isOn: $host.useMosh)
                            .disabled(host.connectionMethod == .cloudflareAccess)
                        Button {
                            showingMoshHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("What is Mosh?")
                    }
                    if host.connectionMethod == .cloudflareAccess {
                        Text("Mosh needs UDP, which can't pass through this tunnel — SSH is used instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // Only offered where it could actually work. In a build without
                // libssh2 the extension isn't included at all, and a toggle
                // that adds a permanently broken location to Files.app is worse
                // than no toggle.
                if FilesDomainRegistrar.isAvailable {
                    Section("Files") {
                        Toggle("Show in Files", isOn: $host.showsInFiles)
                        if host.showsInFiles {
                            // Only once the domain actually exists. Offering a
                            // button that opens nothing is worse than not
                            // offering one — registration happens on save, so
                            // a host being switched on right now has no domain
                            // yet and correctly shows nothing.
                            if let filesURL {
                                Button {
                                    openURL(filesURL)
                                } label: {
                                    Label("Open in Files", systemImage: "folder")
                                }
                            }
                            TextField("Folder (optional)",
                                      text: Binding(get: { host.filesRootPath ?? "" },
                                                    set: { host.filesRootPath = $0 }))
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                            Text(host.trimmedFilesRootPath.map { "Opens at \($0)." }
                                 ?? "Opens where a new shell starts, usually your home folder.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            // Everything the extension cannot do for itself.
                            // Saying so here is cheaper than the user meeting
                            // it as a failure inside Files.app later.
                            Text("Files can't answer prompts. Connect to this host in Sloop "
                                 + "once first, so its host key is trusted"
                                 + (host.connectionMethod == .cloudflareAccess
                                    ? " and its Cloudflare Access login is current." : "."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .task(id: host.showsInFiles) {
                filesURL = host.showsInFiles
                    ? await FilesDomainRegistrar.userVisibleURL(for: host)
                    : nil
            }
            .onChange(of: host.connectionMethod) { _, method in
                // Only the Access tunnel rules Mosh out — it carries TCP over a
                // WebSocket and there is nowhere for UDP to go. A tailnet is a
                // network, so Mosh works over it exactly as it does directly,
                // which is a good pairing: Tailscale roams between networks and
                // so does Mosh.
                if method == .cloudflareAccess { host.useMosh = false }
            }
            .navigationTitle(host.hostname.isEmpty ? "New Host" : host.alias)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Couldn't Save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            // Suggestions ride directly above the keyboard rather than sitting
            // in the form. On a tablet the keyboard covers most of the screen,
            // so anything below the field has to be scrolled to — which defeats
            // a suggestion you are meant to take while typing. Here they cannot
            // be scrolled away, and they cost the form no height at all.
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if commandFocused {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.suggestions, id: \.command) { suggestion in
                                    Button(suggestion.command) {
                                        host.onConnectCommand = suggestion.command
                                        commandFocused = false
                                    }
                                    .font(.system(.footnote, design: .monospaced))
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        Spacer()
                        Button("Done") { commandFocused = false }
                    }
                }
            }
            #endif
            .alert("What is Mosh?", isPresented: $showingMoshHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("""
                Mosh keeps a shell alive when the network doesn't. It runs over \
                UDP and survives changing Wi-Fi, moving to cellular, and \
                sleeping the device — the session resumes instead of dying, so \
                you don't lose your work reconnecting.

                It also echoes your typing locally, so the terminal stays \
                responsive on a slow link instead of waiting for the round trip.

                It needs mosh-server installed on the host. Sloop starts it \
                over SSH; if it isn't there, the connection quietly falls back \
                to plain SSH.
                """)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            switch authKind {
                            case .password:
                                host.auth = .password
                                try onSave(host, password.isEmpty ? nil : Credential(password: password))
                            case .privateKey:
                                var name = selectedKeyName
                                if name.isEmpty {
                                    name = trimmedPastedName
                                    guard !libraryKeys.contains(where: { $0.name == name }) else {
                                        throw KeyNameCollisionError(name: name)
                                    }
                                    try onSaveKey(NamedKey(
                                        name: name,
                                        privateKeyPEM: trimmedPastedPEM,
                                        passphrase: pastedPassphrase.isEmpty ? nil : pastedPassphrase))
                                }
                                host.auth = .publicKey(name: name)
                                try onSave(host, nil)
                            }
                            dismiss()
                        } catch {
                            // Stay open on failure. Dismissing here is what let
                            // a password go unstored while the sheet closed as
                            // though it had been saved.
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(host.hostname.isEmpty || host.username.isEmpty
                              || (authKind == .privateKey && selectedKeyName.isEmpty
                                  && (trimmedPastedName.isEmpty || trimmedPastedPEM.isEmpty)))
                }
            }
        }
    }
}

/// Thrown when a pasted key's name matches an existing library entry. The
/// library is synced via iCloud Keychain, so silently overwriting here would
/// silently replace the key on every device — surfaced instead as the same
/// "Couldn't Save Key" alert used for keychain-write failures.
private struct KeyNameCollisionError: LocalizedError {
    let name: String
    var errorDescription: String? {
        "A key named '\(name)' already exists in your library. Pick it from " +
        "the list above instead, or choose a different name — importing " +
        "here never overwrites an existing key."
    }
}
