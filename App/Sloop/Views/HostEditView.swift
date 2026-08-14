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
    private let libraryKeys: [NamedKey]
    private let onSaveKey: (NamedKey) throws -> Void
    private let onSave: (SSHHost, Credential?) -> Void

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
         onSaveKey: @escaping (NamedKey) throws -> Void = { _ in },
         onSave: @escaping (SSHHost, Credential?) -> Void) {
        _host = State(initialValue: host)
        self.libraryKeys = libraryKeys
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
                    Stepper("Port: \(host.port)", value: $host.port, in: 1...65535)
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

                Section("Options") {
                    Toggle("Use Mosh", isOn: $host.useMosh)
                }
            }
            .navigationTitle(host.hostname.isEmpty ? "New Host" : host.alias)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Couldn't Save Key", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        switch authKind {
                        case .password:
                            host.auth = .password
                            onSave(host, password.isEmpty ? nil : Credential(password: password))
                            dismiss()
                        case .privateKey:
                            do {
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
                                onSave(host, nil)
                                dismiss()
                            } catch {
                                saveError = error.localizedDescription
                            }
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
