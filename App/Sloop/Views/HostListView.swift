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
    #if SLOOP_TAILSCALE
    @ObservedObject private var tailscaleAuth = TailscaleAuthPrompter.shared
    #endif
    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.openURL) private var openURL
    @State private var editing: SSHHost?
    @State private var accessLogin: SSHHost?
    /// What to do once the Access login sheet has actually finished closing.
    ///
    /// Acting the moment the sheet reports its outcome doesn't work: setting an
    /// alert or pushing the terminal while a sheet is mid-dismissal gets dropped
    /// by SwiftUI, so a sign-in that failed looked exactly like nothing at all
    /// happening — the sheet flashed and vanished with no explanation. Held here
    /// and run from the sheet's `onDismiss` instead, where the presentation is
    /// free again.
    @State private var accessFollowUp: AccessFollowUp?

    private enum AccessFollowUp {
        case connect(SSHHost)
        case failed(String)
    }
    @State private var showingSupport = false
    @State private var showingSettings = false
    @State private var showingTerminal = false
    @State private var showingImport = false
    @State private var showingExport = false
    @State private var importResult: String?
    /// A store operation that failed — saving, deleting, or resolving the
    /// credential for a connect. Surfaced rather than dropped: each of these
    /// used to fail silently and reappear later as an unexplained auth failure.
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    // One row per open session, not a count: with several tabs
                    // open, "3 sessions" only gets you to whichever one happens
                    // to be selected, and finding the right one means paging
                    // through the terminal. Here you go straight to it.
                    Section("Open") {
                        ForEach(sessions.sessions) { session in
                            Button {
                                sessions.select(session.id)
                                showingTerminal = true
                            } label: {
                                if let controller = sessions.controller(for: session) {
                                    SessionRow(session: session,
                                               controller: controller,
                                               isCurrent: session.id == sessions.selectedID)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sessions.close(session.id)
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    sessions.close(session.id)
                                } label: {
                                    Label("Close Session", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }

                Section("Hosts") {
                    if model.hosts.isEmpty {
                        EmptyHosts()
                    }
                    ForEach(model.hosts) { host in
                        HStack {
                            Button { connect(host) } label: {
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
                            if host.showsInFiles {
                                // Resolved on tap rather than up front: the URL
                                // needs a round trip to the File Provider
                                // system, and doing that for every row on every
                                // list render would be one per host for a menu
                                // nobody may open.
                                Button {
                                    Task {
                                        guard let url = await FilesDomainRegistrar
                                            .userVisibleURL(for: host) else { return }
                                        openURL(url)
                                    }
                                } label: {
                                    Label("Open in Files", systemImage: "folder")
                                }
                            }
                            if host.connectionMethod == .cloudflareAccess {
                                Button {
                                    run { try model.signOutOfCloudflareAccess(host) }
                                } label: {
                                    Label("Sign Out of Cloudflare Access",
                                          systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                            Button(role: .destructive) { delete(host) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        run { try model.delete(at: offsets) }
                    }
                }
            }
            .navigationTitle("Sloop")
            // Off the launch path on purpose — see HostListModel.syncFilesDomains.
            // Also the repair for domains that drifted while Sloop wasn't
            // running: a host deleted on another device, or a domain the system
            // dropped.
            .task { await model.syncFilesDomains() }
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
                             libraryKeys: model.libraryKeys,
                             libraryError: model.libraryError,
                             onSaveKey: { try model.saveLibraryKey($0) },
                             onSave: { try model.save($0, credential: $1) })
            }
            .sheet(item: $accessLogin, onDismiss: runAccessFollowUp) { host in
                AccessLoginView(hostname: host.hostname) { outcome in
                    switch outcome {
                    case .token(let token):
                        // The keychain write is safe to do now; connecting is
                        // not, because it pushes the terminal.
                        do {
                            try model.storeAccessToken(token, for: host)
                            accessFollowUp = .connect(host)
                        } catch {
                            accessFollowUp = .failed(
                                "Couldn't store the Access token: \(error.localizedDescription)")
                        }
                    case .cancelled:
                        // The user closed the sheet. They know; telling them
                        // so in an alert is the app arguing with a button
                        // they pressed on purpose.
                        accessFollowUp = nil
                    case .failed(let message):
                        accessFollowUp = .failed(message)
                    }
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
            #if SLOOP_TAILSCALE
            .sheet(item: $tailscaleAuth.url) { pending in
                TailscaleAuthView(url: pending.url)
            }
            #endif
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
            .alert("Sloop", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } })
            ) {
                Button("OK", role: .cancel) { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
            .alert("Couldn't Connect", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
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
            .onOpenURL { handle($0) }
        }
    }


    private func delete(_ host: SSHHost) {
        run { try model.delete(host) }
    }

    /// Act on the Access login's outcome, now that its sheet is gone.
    private func runAccessFollowUp() {
        let followUp = accessFollowUp
        accessFollowUp = nil
        switch followUp {
        case .connect(let host):
            run { open(try model.connect(host)) }
        case .failed(let message):
            actionError = message
        case nil:
            break
        }
    }

    /// Run a store operation, showing why it failed rather than dropping it.
    private func run(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Open a session as a new tab and navigate to the terminal.
    private func open(_ session: TerminalSession) {
        sessions.openSession(session)
        showingTerminal = true
    }

    /// Connect, first running the Cloudflare Access browser login when the host
    /// needs a (fresh) token.
    ///
    /// Anything that can't be read stops the connect and says why. Going ahead
    /// without a credential produces an authentication failure on the far side
    /// that says nothing about the actual cause, and going ahead without being
    /// able to check for a token sends the user to a browser login that cannot
    /// fix a keychain.
    private func connect(_ host: SSHHost) {
        run {
            if try model.needsAccessLogin(host) {
                accessLogin = host
            } else {
                open(try model.connect(host))
            }
        }
    }

    /// Open an `ssh://user@host` link.
    ///
    /// A link that names a host you already saved connects to it — it is a host
    /// you have already trusted, with a credential you already stored. A link
    /// that matches nothing opens the editor prefilled instead of connecting,
    /// so adding a host stays a thing the user does rather than a thing a link
    /// does to them. Anything that isn't a usable ssh:// URL is ignored: the
    /// system only hands us the scheme we registered, so this is a malformed
    /// link rather than a mistake worth interrupting anyone about.
    private func handle(_ url: URL) {
        guard let ssh = SSHURL(string: url.absoluteString) else { return }
        if let existing = model.hosts.first(where: { ssh.matches($0) }) {
            connect(existing)
        } else {
            editing = ssh.makeHost()
        }
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
            do {
                switch try model.importConfig(text) {
                case 0: return "No new hosts found in that config."
                case 1: return "Imported 1 host."
                case let count: return "Imported \(count) hosts."
                }
            } catch {
                return error.localizedDescription
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

/// One open session on the home screen. Reads as a live counterpart to
/// `HostRow`: the same colour rail (keyed on the same name, so a session sits
/// visually under the host it came from), with the address line replaced by
/// what only a live session has — how the connection is doing.
private struct SessionRow: View {
    let session: TerminalSession
    @ObservedObject var controller: TerminalController
    /// The tab the terminal is showing right now. Marked by weight and a fully
    /// lit rail rather than a word, so the list stays scannable.
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(HostPalette.color(for: session.title))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .opacity(isCurrent ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(session.title)
                        .font(.headline)
                        .fontWeight(isCurrent ? .bold : .regular)
                }
                Text(statusText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(statusText)"
                            + (isCurrent ? ", current tab" : ""))
    }

    private var statusColor: Color {
        switch controller.state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch controller.state {
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .disconnected(let reason): return reason ?? "disconnected"
        }
    }
}

/// A small capsule beside a host's name: how it connects, and whether it uses
/// Mosh. Colour carries the meaning at a glance — the row is scanned, not read.
private struct Flair: View {
    private let text: String
    private let tint: AnyShapeStyle

    init(_ text: String, _ tint: some ShapeStyle) {
        self.text = text
        self.tint = AnyShapeStyle(tint)
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.2), in: Capsule())
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
                    // Gated on the Access tunnel rather than on .direct: that
                    // tunnel carries TCP over a WebSocket and cannot carry Mosh,
                    // so a host decoded with both set (JSON predating the
                    // editor's reset-on-change) really does connect over SSH and
                    // "mosh" would misrepresent it. A tailnet carries UDP like
                    // any other network, so there the badge is true.
                    if host.useMosh && host.connectionMethod != .cloudflareAccess {
                        Flair("mosh", .tint)
                    }
                    // A switch, so a new connection method has to answer "and
                    // what does the row say about it?" here. The hand-written
                    // `if` this replaces covered exactly one case, and Tailscale
                    // hosts were left showing nothing at all.
                    switch host.connectionMethod {
                    case .direct:
                        EmptyView()
                    case .cloudflareAccess:
                        Flair("cloudflare", .orange)
                    case .tailscale:
                        Flair("tailnet", .purple)
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
