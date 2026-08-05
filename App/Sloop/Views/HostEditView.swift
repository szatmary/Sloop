import SwiftUI
import SloopKit

/// Add/edit form for a `Host`. Secrets are intentionally not collected here yet;
/// that belongs behind a keychain flow (see Docs/ROADMAP.md).
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var password: String = ""
    private let onSave: (Host, Credential?) -> Void

    init(host: Host, onSave: @escaping (Host, Credential?) -> Void) {
        _host = State(initialValue: host)
        self.onSave = onSave
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
                    SecureField("Password", text: $password)
                        #if os(iOS)
                        .textContentType(.password)
                        #endif
                    Text("Stored in the keychain, never in the host list. Leave blank to keep the existing secret. Key-based auth comes next — see the roadmap.")
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
                        onSave(host, password.isEmpty ? nil : Credential(password: password))
                        dismiss()
                    }
                    .disabled(host.hostname.isEmpty || host.username.isEmpty)
                }
            }
        }
    }
}
