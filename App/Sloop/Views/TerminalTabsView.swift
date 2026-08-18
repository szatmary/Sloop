// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit
#if os(iOS)
import UIKit
#endif

/// The tabbed terminal container. Shows a strip of open sessions and the active
/// one's terminal. All panes stay in the hierarchy (hidden ones at zero opacity)
/// so background tabs keep their connections live and their output up to date.
struct TerminalTabsView: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject private var appearance = AppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    /// The back chevron is shown briefly on arrival and then fades: it is there
    /// to teach the edge-swipe, not to sit permanently on top of output.
    @State private var showBackHint = true
    /// Live width, for locating the trailing edge in the paging gesture.
    @State private var width: CGFloat = 0

    #if os(iOS)
    /// Safe-area edges the terminal may draw into. The top inset survives
    /// hiding the status bar only to clear a sensor housing, which iPads don't
    /// have — so they get the space and notch/island iPhones keep it.
    private static var terminalEdgesToFill: Edge.Set {
        UIDevice.current.userInterfaceIdiom == .pad ? [.top, .bottom] : .bottom
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if !os(iOS)
            if model.count > 1 {
                TabStrip(model: model)
                Divider()
            }
            #endif
            ZStack {
                ForEach(model.sessions) { session in
                    if let controller = model.controller(for: session) {
                        let active = session.id == model.selectedID
                        TerminalPane(controller: controller,
                                     closeTab: { model.close(session.id) })
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                    }
                }
            }
        }
        #if os(iOS)
        // Measure the screen so the trailing-edge swipe knows where "the right
        // edge" is; a gesture can only compare against a width it has.
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
        )
        #endif
        // Restyle every open terminal when appearance settings change.
        .onChange(of: appearance.appearance) { _, new in model.applyAppearance(new) }
        .navigationTitle(model.selectedTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // With the status bar hidden, the remaining top inset exists only to
        // clear a sensor housing. iPads have none, so that strip is dead space
        // a terminal can use; on a notch/Dynamic Island iPhone it is load-
        // bearing and must stay, or the top row of output hides behind it.
        .ignoresSafeArea(.container, edges: Self.terminalEdgesToFill)
        // A terminal wants every row it can get. The navigation bar (back
        // chevron + host name) and the status bar (clock, battery) together
        // cost ~70pt of a screen whose whole job is showing text, so both go
        // and `BackChevron` becomes the way out.
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        // Edge swipes page through the screens, which lie in a line with the
        // host list pinned at the far left:
        //
        //     hosts │ tab 1 │ tab 2 │ …
        //
        // Swiping in from the left edge steps left (and off the first tab,
        // back to the host list); from the right edge, right. This replaces
        // the tab strip, whose row of chips cost space on every screen to
        // solve a problem you only have while switching.
        //
        // `simultaneousGesture` (not `gesture`) so the terminal still receives
        // the same touches — a gesture that swallowed them would break text
        // selection along the margins. Filtering on `startLocation` keeps
        // ordinary drags mid-screen from paging.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { drag in
                    guard abs(drag.translation.height) < 80 else { return }
                    let fromLeftEdge = drag.startLocation.x < 24
                    let fromRightEdge = width > 0 && drag.startLocation.x > width - 24

                    if fromLeftEdge, drag.translation.width > 80 {
                        // Off the first tab is the host list.
                        if !model.selectRelative(-1) { dismiss() }
                    } else if fromRightEdge, drag.translation.width < -80 {
                        model.selectRelative(1)
                    }
                }
        )
        .overlay(alignment: .topLeading) {
            if showBackHint { BackChevron { dismiss() } }
        }
        // The edge-swipe gesture above and the fading `BackChevron` are both
        // unreachable under VoiceOver or Switch Control — neither can start a
        // drag from a screen edge, and once the chevron fades there is no
        // control left to activate. `.escape` is the first-class route those
        // technologies already know how to trigger (a two-finger scrub under
        // VoiceOver, or a configured Switch Control gesture), so it must work
        // regardless of whether the chevron is still on screen.
        .accessibilityAction(.escape) { dismiss() }
        .task {
            // Long enough to notice, short enough to stay out of the way.
            try? await Task.sleep(for: .seconds(3))
            // VoiceOver users navigate by swiping between elements, not by
            // starting drags from a screen edge, so the chevron is their only
            // on-screen way back (the `.escape` action above is the other,
            // but it's not discoverable without exploring). Don't fade out
            // from under them.
            guard !UIAccessibility.isVoiceOverRunning else { return }
            withAnimation(.easeOut(duration: 0.4)) { showBackHint = false }
        }
        #endif
    }
}

#if os(iOS)
/// A transient hint that swiping in from the left edge goes back.
///
/// Shown for a few seconds on arrival, then faded out: a permanent button in
/// this corner covers terminal output, which is exactly what hiding the
/// navigation bar was meant to stop. The edge swipe remains available after it
/// disappears.
private struct BackChevron: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .padding(9)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(DimmedButtonStyle())
        .padding(.leading, 6)
        .padding(.top, 4)
        .accessibilityLabel("Back to hosts")
    }
}

private struct DimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

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
