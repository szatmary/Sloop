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
    @State private var privateKeyPEM: String = ""
    @State private var passphrase: String = ""
    private let onSave: (SSHHost, Credential?) -> Void

    private enum AuthKind: String, CaseIterable, Identifiable, Hashable {
        case password = "Password"
        case privateKey = "Private Key"
        var id: String { rawValue }
    }

    init(host: SSHHost, onSave: @escaping (SSHHost, Credential?) -> Void) {
        _host = State(initialValue: host)
        self.onSave = onSave
        if case .publicKey = host.auth {
            _authKind = State(initialValue: .privateKey)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Private key (PEM)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $privateKeyPEM)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 120)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                        }
                        SecureField("Key passphrase (optional)", text: $passphrase)
                    }

                    Text("Stored in the keychain, never in the host list. Leave blank to keep the existing secret.")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        host.auth = (authKind == .privateKey) ? .publicKey(name: host.alias) : .password
                        onSave(host, buildCredential())
                        dismiss()
                    }
                    .disabled(host.hostname.isEmpty || host.username.isEmpty)
                }
            }
        }
    }

    /// Build the credential from the entered secret. Returns `nil` when nothing
    /// was entered, meaning "keep the existing keychain secret".
    private func buildCredential() -> Credential? {
        switch authKind {
        case .password:
            return password.isEmpty ? nil : Credential(password: password)
        case .privateKey:
            let pem = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pem.isEmpty else { return nil }
            return Credential(privateKeyPEM: privateKeyPEM,
                              passphrase: passphrase.isEmpty ? nil : passphrase)
        }
    }
}
