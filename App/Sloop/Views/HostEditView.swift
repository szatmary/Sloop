import SwiftUI
import SloopKit

/// Add/edit form for a `Host`. Secrets are intentionally not collected here yet;
/// that belongs behind a keychain flow (see Docs/ROADMAP.md).
struct HostEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    private let onSave: (Host) -> Void

    init(host: Host, onSave: @escaping (Host) -> Void) {
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
                    Button("Save") { onSave(host); dismiss() }
                        .disabled(host.hostname.isEmpty || host.username.isEmpty)
                }
            }
        }
    }
}
