import SwiftUI
import SloopKit

/// The tabbed terminal container. Shows a strip of open sessions and the active
/// one's terminal. All panes stay in the hierarchy (hidden ones at zero opacity)
/// so background tabs keep their connections live and their output up to date.
struct TerminalTabsView: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if model.count > 1 {
                TabStrip(model: model)
                Divider()
            }
            ZStack {
                ForEach(model.sessions) { session in
                    if let controller = model.controller(for: session) {
                        let active = session.id == model.selectedID
                        TerminalPane(controller: controller)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                    }
                }
            }
        }
        // Restyle every open terminal when appearance settings change.
        .onChange(of: appearance.appearance) { _, new in model.applyAppearance(new) }
        .navigationTitle(model.selectedTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}

/// The horizontal strip of tab chips: tap to switch, ✕ to close.
private struct TabStrip: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    let active = session.id == model.selectedID
                    HStack(spacing: 5) {
                        Text(session.title)
                            .font(.footnote)
                            .lineLimit(1)
                        Button {
                            model.close(session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        active ? Color.accentColor.opacity(0.22)
                               : Color.gray.opacity(0.15),
                        in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { model.select(session.id) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private extension SessionsModel {
    /// Title of the active tab, for the navigation bar.
    var selectedTitle: String {
        guard let id = selectedID,
              let session = sessions.first(where: { $0.id == id }) else { return "Terminal" }
        return session.title
    }
}
