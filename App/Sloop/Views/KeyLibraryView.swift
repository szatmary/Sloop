// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit
import UniformTypeIdentifiers

/// The shared key library: what is in it, and the two ways to put something
/// there from a machine iCloud Keychain cannot reach.
///
/// Both sources end at the same confirmation sheet, which is where naming, the
/// passphrase and a name collision are settled — one place, so a key imported
/// from a file and a key pulled off a host cannot behave differently.
///
/// Design: `Docs/superpowers/specs/2026-08-19-key-import-design.md`.
struct KeyLibraryView: View {
    @ObservedObject var model: HostListModel
    @Environment(\.dismiss) private var dismiss

    @State private var pendingImport: PendingImport?
    @State private var hostPicker = false
    @State private var filePicker = false
    @State private var browsing: RemoteBrowse?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.libraryError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if model.libraryKeys.isEmpty {
                        Text("No keys yet. Import one from a file, or pull it off a host you can already reach with a password.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.libraryKeys) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            if let subtitle = subtitle(for: key) {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: remove)
                } footer: {
                    Text("Keys sync to your other Apple devices through iCloud Keychain, end-to-end encrypted.")
                }
            }
            .navigationTitle("Keys")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Menu {
                        Button {
                            filePicker = true
                        } label: {
                            Label("Import from Files…", systemImage: "folder")
                        }
                        Button {
                            hostPicker = true
                        } label: {
                            Label("Import from a Host…", systemImage: "server.rack")
                        }
                        .disabled(model.hosts.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $filePicker,
                          allowedContentTypes: [.data, .text, .plainText]) { result in
                switch result {
                case .success(let url): readPickedFile(url)
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .sheet(isPresented: $hostPicker) {
                HostPickerView(hosts: model.hosts) { host in
                    hostPicker = false
                    browse(host)
                }
            }
            .sheet(item: $browsing) { browse in
                RemoteKeyPickerView(browse: browse) { entry in
                    readRemoteKey(entry, from: browse)
                }
            }
            .sheet(item: $pendingImport) { pending in
                KeyImportSheet(model: model, pending: pending) {
                    pendingImport = nil
                }
            }
            .alert("Couldn't Import Key", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func subtitle(for key: NamedKey) -> String? {
        // The algorithm is the first field of the stored .pub line. Shown
        // because "which of these is my Ed25519 key" is the question a list of
        // names alone cannot answer.
        let algorithm = key.publicKey?.split(separator: " ").first.map(String.init)
        let locked = key.passphrase != nil ? "passphrase stored" : nil
        let parts = [algorithm, locked].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func remove(at offsets: IndexSet) {
        for index in offsets {
            do { try model.removeLibraryKey(named: model.libraryKeys[index].name) }
            catch { failure = error.localizedDescription }
        }
    }

    // MARK: Sources

    private func readPickedFile(_ url: URL) {
        // A file picked outside the app's container is security-scoped, and
        // reading it without this fails with a permissions error that looks
        // like the file is missing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingImport = PendingImport(
                data: data,
                suggestedName: PrivateKeyMaterial.defaultName(forPath: url.lastPathComponent),
                origin: .file(url.lastPathComponent))
        } catch {
            failure = error.localizedDescription
        }
    }

    private func browse(_ host: SSHHost) {
        let browse = RemoteBrowse(host: host)
        browsing = browse
        Task {
            do {
                let client = try await offMain { try model.sftpClient(for: host) }
                let home = try await offMain { try client.defaultDirectory() }
                let entries = try await offMain {
                    try RemoteKeys.candidates(in: client,
                                              sshDirectory: RemoteKeys.directory(in: home))
                }
                browse.finish(client: client, entries: entries)
            } catch {
                browse.fail(error.localizedDescription)
            }
        }
    }

    private func readRemoteKey(_ entry: SFTPEntry, from browse: RemoteBrowse) {
        guard let client = browse.client else { return }
        Task {
            do {
                let data = try await offMain { try RemoteKeys.read(entry, from: client) }
                browse.close()
                browsing = nil
                pendingImport = PendingImport(
                    data: data,
                    suggestedName: PrivateKeyMaterial.defaultName(forPath: entry.name),
                    origin: .host(browse.host.alias))
            } catch {
                browse.fail(error.localizedDescription)
            }
        }
    }
}

/// Bytes that are about to become a library key, and where they came from.
struct PendingImport: Identifiable {
    enum Origin {
        case file(String)
        case host(String)
    }
    let id = UUID()
    let data: Data
    let suggestedName: String
    let origin: Origin
}

/// One remote browse: the connection, what it found, and how it failed.
@MainActor
final class RemoteBrowse: ObservableObject, Identifiable {
    let id = UUID()
    let host: SSHHost
    @Published var entries: [SFTPEntry]?
    @Published var error: String?
    private(set) var client: SFTPClient?

    init(host: SSHHost) { self.host = host }

    func finish(client: SFTPClient, entries: [SFTPEntry]) {
        self.client = client
        self.entries = entries
    }

    func fail(_ message: String) {
        error = message
        close()
    }

    func close() {
        client?.close()
        client = nil
    }
}

/// Runs blocking SSH work off the main thread.
///
/// SFTP connect, list and read all block. Called straight from a SwiftUI action
/// they freeze the interface for as long as the handshake takes, which on a
/// slow link is seconds.
private func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
