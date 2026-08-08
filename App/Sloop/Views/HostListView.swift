import SwiftUI
import SloopKit
import UniformTypeIdentifiers

/// Root screen: saved hosts plus a quick "local terminal" action. Opening a host
/// or the local terminal adds a tab to the shared `SessionsModel` and pushes the
/// tabbed terminal view; the `+` toolbar item adds a host.
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
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section("Open") {
                        Button {
                            showingTerminal = true
                        } label: {
                            Label("Terminals (\(sessions.count))", systemImage: "rectangle.on.rectangle")
                        }
                    }
                }

                Section("Quick") {
                    Button {
                        open(.localEcho())
                    } label: {
                        Label("Local terminal", systemImage: "terminal")
                    }
                }

                Section("Hosts") {
                    if model.hosts.isEmpty {
                        Text("No hosts yet. Tap + to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.hosts) { host in
                        Button { open(model.connect(host)) } label: {
                            HostRow(host: host)
                        }
                        .buttonStyle(.plain)
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
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host) { model.save($0, credential: $1) }
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

private struct HostRow: View {
    let host: SSHHost
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(host.alias).font(.headline)
                if host.useMosh {
                    Text("mosh")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
            Text(host.connectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
