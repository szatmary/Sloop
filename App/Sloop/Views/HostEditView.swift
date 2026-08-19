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
    @State private var showingSuggestionsHelp = false
    @State private var showingConnectionHelp = false
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
                // What this host is called, on its own: it is how the host
                // list reads and which colour rail it gets, and it has nothing
                // to do with reaching the machine.
                Section("Name") {
                    TextField("Name", text: $host.alias)
                        #if os(iOS)
                        // Host names are lowercase far more often than not, and
                        // iOS capitalising the first letter meant a lowercase
                        // alias could not be typed at all without fighting the
                        // keyboard. Hostname and Username already opt out.
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }

                Section("Connection") {
                    // First, because it changes what everything below it means:
                    // a hostname is a machine on Direct, an Access application's
                    // public name on Cloudflare, a MagicDNS name on Tailscale —
                    // and whether there is a port at all depends on it.
                    HStack {
                        Picker("Connect via", selection: $host.connectionMethod) {
                            ForEach(ConnectionMethod.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        Button {
                            showingConnectionHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("About connection methods")
                    }

                    TextField("Hostname", text: $host.hostname)
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    // A switch rather than an if/else, so a new connection
                    // method has to answer "and what does its port mean?"
                    // here rather than inheriting whatever the else branch
                    // happens to do.
                    // A switch rather than an if/else, so a new connection
                    // method has to answer "and what does its port mean?" here
                    // rather than inheriting whatever the else branch happens to
                    // do. The explanations that used to sit underneath are in
                    // the ⓘ beside the picker, where they aren't in the way of
                    // the fields.
                    switch host.connectionMethod {
                    case .direct, .tailscale:
                        // A field, not a stepper. Ports are typed, not walked
                        // to: the useful ones are 22 and whatever four- or
                        // five-digit number someone's sshd listens on, and a
                        // stepper asks for sixty-five thousand taps to reach
                        // the second kind.
                        //
                        // A tailnet host has a real port too — the hostname is
                        // a MagicDNS name and sshd listens on it as usual.
                        LabeledContent("Port") {
                            TextField("22", value: $host.port,
                                      format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                    case .cloudflareAccess:
                        // No port to show: wss/443 outside the tunnel, sshd
                        // inside it, and neither is the user's to choose.
                        EmptyView()
                    }
                }

                Section("Authentication") {
                    // Who you sign in as, beside how you prove it. It sat in
                    // Connection, which is where the machine is described, not
                    // who is knocking.
                    TextField("Username", text: $host.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    // Driven by the enum, not by a hand-written pair: a host
                    // saved as .tailscale used to open this editor with no
                    // matching option at all, so the picker showed nothing
                    // selected and saving silently reinterpreted the host.

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
                        Toggle("Suggest commands", isOn: $host.suggestions)
                        Button {
                            showingSuggestionsHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("About command suggestions")
                    }

                    HStack {
                        Toggle("Use Mosh", isOn: $host.useMosh)
                            .disabled(!host.connectionMethod.carriesMosh)
                        Button {
                            showingMoshHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("What is Mosh?")
                    }
                    if let reason = host.connectionMethod.moshUnavailableReason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: host.connectionMethod) { _, method in
                // Leaving the toggle on while the method can't honor it is how
                // a host ends up quietly running SSH with "Use Mosh" checked.
                if !method.carriesMosh { host.useMosh = false }
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
            .alert("Connecting to This Host", isPresented: $showingConnectionHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("""
                Direct — an ordinary SSH connection to the hostname and port \
                below. Use this on a local network, over a VPN, or for anything \
                reachable from where you are.

                Cloudflare Access — for a host behind a Cloudflare tunnel. The \
                hostname is the Access application's public name, there is no \
                port, and the first connection opens a browser sign-in.

                Tailscale — for a host on your tailnet. Sloop joins the tailnet \
                itself, so the Tailscale app doesn't have to be running; the \
                hostname is the machine's MagicDNS name or its 100.x address.
                """)
            }
            .alert("Command Suggestions", isPresented: $showingSuggestionsHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("""
                As you type, Sloop offers the word that usually comes next, \
                taken from the commands you've run on this host and from the \
                host's own shell history, which it reads once when you connect. \
                Tap a suggestion to use it.

                That list of commands stays on this device. It isn't synced to \
                iCloud, isn't shared with your other devices, and is never sent \
                to a server or to anyone else. There's no account and nothing to \
                opt out of, because there is nowhere for it to go.

                You can clear the list whenever you like, in Terminal settings.
                """)
            }
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
                        // Typed, so it can be anything. A saved 0 or 99999 is a
                        // host that will never connect, failing somewhere far
                        // from the field that caused it.
                        host.port = min(max(host.port, 1), 65535)
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
