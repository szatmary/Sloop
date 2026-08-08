import SwiftUI
import SloopKit

/// Root screen: saved hosts plus a quick "local terminal" action. Opening a host
/// or the local terminal adds a tab to the shared `SessionsModel` and pushes the
/// tabbed terminal view; the `+` toolbar item adds a host.
struct HostListView: View {
    @StateObject private var model = HostListModel()
    @StateObject private var sessions = SessionsModel()
    @ObservedObject private var hostKeyPrompter = HostKeyPrompter.shared
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var editing: SSHHost?
    @State private var showingSupport = false
    @State private var showingSettings = false
    @State private var showingTerminal = false

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
                    Button { editing = model.newHost() } label: {
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
            .navigationDestination(isPresented: $showingTerminal) {
                TerminalTabsView(model: sessions)
            }
            // Popping back to an empty tab set means there's nothing to return to.
            .onChange(of: sessions.isEmpty) { _, empty in
                if empty { showingTerminal = false }
            }
        }
    }

    /// Open a session as a new tab and navigate to the terminal.
    private func open(_ session: TerminalSession) {
        sessions.openSession(session)
        showingTerminal = true
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
