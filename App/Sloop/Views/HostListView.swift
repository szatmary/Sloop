import SwiftUI
import SloopKit

/// Root screen: saved hosts plus a quick "local terminal" action. Selecting a
/// host opens a `TerminalScreen`; the `+` toolbar item adds a host.
struct HostListView: View {
    @StateObject private var model = HostListModel()
    @ObservedObject private var hostKeyPrompter = HostKeyPrompter.shared
    @ObservedObject private var appearance = AppearanceStore.shared
    @State private var editing: SSHHost?
    @State private var session: TerminalSession?
    @State private var showingSupport = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section("Quick") {
                    Button {
                        session = .localEcho()
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
                        Button { session = model.connect(host) } label: {
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
            .navigationDestination(item: $session) { session in
                TerminalScreen(session: session)
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
