// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit
import UniformTypeIdentifiers

/// Root screen: the saved hosts. Opening one adds a tab to the shared
/// `SessionsModel` and pushes the tabbed terminal view; the `+` toolbar item
/// adds a host, and each row's ⓘ button (or its context menu) edits an
/// existing one.
struct HostListView: View {
    @StateObject private var model = HostListModel()
    @ObservedObject private var sessions = SessionsModel.shared
    @ObservedObject private var hostKeyPrompter = HostKeyPrompter.shared
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var editing: SSHHost?
    @State private var showingSupport = false
    @State private var showingSettings = false
    @State private var showingTerminal = false
    @State private var showingImport = false
    @State private var showingExport = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section("Open") {
                        Button {
                            showingTerminal = true
                        } label: {
                            Label("^[\(sessions.count) session](inflect: true)",
                                  systemImage: "rectangle.on.rectangle")
                        }
                    }
                }

                Section("Hosts") {
                    if model.hosts.isEmpty {
                        EmptyHosts()
                    }
                    ForEach(model.hosts) { host in
                        HStack {
                            Button { open(model.connect(host)) } label: {
                                HostRow(host: host, isUnderway: isUnderway(host))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { editing = host } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(host.alias)")
                        }
                        .contextMenu {
                            Button { editing = host } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            Button(role: .destructive) { model.delete(host) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: model.delete)
                }
            }
            .navigationTitle("Sloop")
            .toolbar {
                ToolbarItem {
                    Button { showingSettings = true } label: {
                        Image(systemName: "textformat.size")
                    }
                }
                ToolbarItem {
                    Button { showingSupport = true } label: {
                        Image(systemName: "heart")
                    }
                }
                ToolbarItem {
                    Menu {
                        Button {
                            editing = model.newHost()
                        } label: {
                            Label("New Host", systemImage: "plus")
                        }
                        Button {
                            showingImport = true
                        } label: {
                            Label("Import from SSH Config…", systemImage: "square.and.arrow.down")
                        }
                        if !model.hosts.isEmpty {
                            Button {
                                showingExport = true
                            } label: {
                                Label("Export SSH Config…", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host,
                             libraryKeys: model.libraryKeys(),
                             onSaveKey: { try model.saveLibraryKey($0) }) {
                    model.save($0, credential: $1)
                }
            }
            .sheet(isPresented: $showingSupport) {
                SupportView()
            }
            .sheet(isPresented: $showingSettings) {
                TerminalSettingsView(store: appearance)
            }
            .sheet(item: $hostKeyPrompter.prompt) { prompt in
                HostKeyPromptView(prompt: prompt)
            }
            .fileImporter(isPresented: $showingImport,
                          allowedContentTypes: [.text, .plainText, .data]) { result in
                importResult = importConfig(from: result)
            }
            .fileExporter(isPresented: $showingExport,
                          document: ConfigTextDocument(text: SSHConfigParser.format(model.hosts)),
                          contentType: .plainText,
                          defaultFilename: "sloop-hosts.config") { result in
                if case .failure(let error) = result {
                    importResult = error.localizedDescription
                }
            }
            .alert("Import SSH Config", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } })
            ) {
                Button("OK", role: .cancel) { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
            .navigationDestination(isPresented: $showingTerminal) {
                TerminalTabsView(model: sessions)
            }
            // Show the terminal when a tab opens (including via the ⌘T menu
            // command from anywhere), and pop back when the last tab closes.
            .onChange(of: sessions.count) { old, new in
                if new > old { showingTerminal = true }
                else if new == 0 { showingTerminal = false }
            }
        }
    }

    /// Open a session as a new tab and navigate to the terminal.
    private func open(_ session: TerminalSession) {
        sessions.openSession(session)
        showingTerminal = true
    }

    /// Whether a live session is already open for this host. Sessions are
    /// titled with the host's alias, which is what the terminal tab shows.
    private func isUnderway(_ host: SSHHost) -> Bool {
        sessions.sessions.contains { $0.title == host.alias }
    }

    /// Read the picked SSH config file and import its hosts. Returns a short
    /// user-facing result message.
    private func importConfig(from result: Result<URL, Error>) -> String {
        switch result {
        case .failure(let error):
            return error.localizedDescription
        case .success(let url):
            // The picked URL is security-scoped on iOS/macOS; access it briefly.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return "Couldn't read that file as text."
            }
            let count = model.importConfig(text)
            switch count {
            case 0: return "No new hosts found in that config."
            case 1: return "Imported 1 host."
            default: return "Imported \(count) hosts."
            }
        }
    }
}

/// A minimal plain-text document so the host list can be exported as an OpenSSH
/// config via `.fileExporter`.
private struct ConfigTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct HostRow: View {
    let host: SSHHost
    var isUnderway: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // A colour rail, not decoration: it's how you tell prod from
            // staging at a glance, before typing something destructive into
            // the wrong shell. Derived from the alias so it is stable without
            // anyone having to configure it.
            RoundedRectangle(cornerRadius: 2)
                .fill(HostPalette.color(for: host.alias))
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.alias).font(.headline)
                    if host.useMosh {
                        Text("mosh")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    if isUnderway {
                        // Underway: this host already has a live session.
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Underway")
                    }
                }
                // Monospace, because this is a terminal address and should
                // read like one.
                Text(host.connectionSummary)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Stable per-host accent colours, picked by hashing the alias.
///
/// Chosen to stay legible on both light and dark backgrounds and to sit
/// alongside the app's teal without clashing.
private enum HostPalette {
    private static let colors: [Color] = [
        SloopStyle.deepTeal,                         // the house colour
        Color(red: 0.36, green: 0.60, blue: 0.90),   // blue
        Color(red: 0.60, green: 0.50, blue: 0.88),   // violet
        Color(red: 0.90, green: 0.55, blue: 0.30),   // amber
        Color(red: 0.87, green: 0.42, blue: 0.48),   // coral
        Color(red: 0.45, green: 0.72, blue: 0.40),   // green
    ]

    static func color(for alias: String) -> Color {
        // A deliberate, stable hash: Swift's `hashValue` is seeded per process
        // and would repaint every host on each launch.
        var hash: UInt64 = 5381
        for byte in alias.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// The empty state, and the one place the app's mark is allowed to show up.
///
/// The sail sits above a waterline of "command line" rules — the same idea as
/// the app icon, where a terminal prompt doubles as the water the boat sits on.
private struct EmptyHosts: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sailboat")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(SloopStyle.teal)

            Waterline(width: 92)

            Text("No hosts yet")
                .font(.headline)
            Text("Tap + to add one, or import your ~/.ssh/config.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
    }
}
