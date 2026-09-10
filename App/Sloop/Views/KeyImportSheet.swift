// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// Where every import ends: name the key, supply a passphrase if it turns out
/// to need one, and store it.
///
/// Shared by both sources deliberately. Naming, the passphrase prompt and a
/// name collision are the three things that can go wrong after the bytes are in
/// hand, and they must not be answered one way for a file and another way for a
/// key pulled off a host.
///
/// The passphrase field appears only once the key has been *asked*, never
/// because its envelope looked encrypted — that inference is the bug this whole
/// pipeline was built to remove.
struct KeyImportSheet: View {
    @ObservedObject var model: HostListModel
    let pending: PendingImport
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var passphrase: String = ""
    @State private var needsPassphrase = false
    @State private var problem: String?
    @State private var checked = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Name in your key library")
                } footer: {
                    Text(originDescription)
                }

                if needsPassphrase {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                    } footer: {
                        Text("This key is encrypted. Sloop stores the passphrase alongside it so you aren't asked on every connection.")
                    }
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { store() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !checked else { return }
                checked = true
                name = pending.suggestedName
                check()
            }
        }
    }

    private var originDescription: String {
        switch pending.origin {
        case .file(let filename):
            return "From \(filename). If that file came through iCloud Drive or a "
                 + "USB stick, delete it once this import succeeds — the copy there "
                 + "is not protected the way your keychain is."
        case .host(let alias):
            return "Copied from \(alias). The private key now exists on this device "
                 + "as well as on that host."
        }
    }

    /// Asks the key whether it is usable, before the user commits to a name.
    /// A bad file is reported here rather than after they have typed one.
    private func check() {
        switch model.inspectKey(pending.data, name: name.isEmpty ? "k" : name, passphrase: nil) {
        case .success:
            needsPassphrase = false
            problem = nil
        case .failure(.needsPassphrase):
            needsPassphrase = true
            problem = nil
        case .failure(let error):
            problem = error.errorDescription
        }
    }

    private func store() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try model.importLibraryKey(pending.data,
                                       name: trimmed,
                                       passphrase: passphrase.isEmpty ? nil : passphrase)
            finish()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

/// Picks which saved host to pull a key from.
struct HostPickerView: View {
    let hosts: [SSHHost]
    let onPick: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(hosts) { host in
                Button {
                    onPick(host)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.alias)
                        Text("\(host.username)@\(host.hostname)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import from a Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Shows what `~/.ssh` holds on the chosen host.
struct RemoteKeyPickerView: View {
    @ObservedObject var browse: RemoteBrowse
    let onPick: (SFTPEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let error = browse.error {
                    ContentUnavailableView("Couldn't Read ~/.ssh", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let entries = browse.entries {
                    if entries.isEmpty {
                        ContentUnavailableView("No Keys in ~/.ssh", systemImage: "key",
                                               description: Text("Nothing in that directory looks like a private key."))
                    } else {
                        List(entries, id: \.path) { entry in
                            Button { onPick(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.path).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Connecting to \(browse.host.alias)…")
                }
            }
            .navigationTitle("Keys on \(browse.host.alias)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        browse.close()
                        dismiss()
                    }
                }
            }
        }
    }
}
