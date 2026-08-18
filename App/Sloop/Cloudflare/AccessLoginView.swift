// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// App/Sloop/Cloudflare/AccessLoginView.swift
import SwiftUI
import WebKit
import SloopKit

/// Browser SSO for a Cloudflare Access-protected hostname. Loads
/// `https://<hostname>`, lets Access bounce through the IdP, and captures the
/// resulting `CF_Authorization` cookie — which IS the Access JWT — from the
/// web view's cookie store. That store is deliberately non-persistent; see
/// `AccessWebView.makeWebView`.
///
/// Every way the sheet can end reports exactly one `AccessLoginOutcome`, so
/// the caller is never left waiting — and never told that the user closing
/// the sheet was an error.
struct AccessLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let hostname: String
    let onOutcome: (AccessLoginOutcome) -> Void

    /// The sheet can end in several independent, sometimes-racing ways: a
    /// token arrives, the user taps Cancel, the user swipes the sheet away
    /// (no explicit action at all), or a navigation fails. All of them route
    /// through this one gate so whichever gets there first wins and every
    /// other — including a `getAllCookies` completion that resolves after
    /// the sheet is already gone — is a no-op. See `AccessLoginOutcomeGate`.
    @State private var gate = AccessLoginOutcomeGate()

    var body: some View {
        NavigationStack {
            AccessWebView(hostname: hostname,
                          onToken: { finish(.token($0)) },
                          onFailure: { finish(.failed($0)) })
            .navigationTitle(hostname)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(.cancelled) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .onDisappear {
            // Catches the one exit with no explicit action of its own: an
            // interactive swipe-to-dismiss, which is a cancellation just as
            // much as the button is. Every other exit above already committed
            // the gate before dismissing, so this is a no-op for them — and
            // once the gate is committed here, nothing async arriving later
            // can still succeed or double-report either.
            gate.commit { onOutcome(.cancelled) }
        }
    }

    /// Report the sheet's one outcome and close it, if nothing else got there
    /// first.
    private func finish(_ outcome: AccessLoginOutcome) {
        if gate.commit({ onOutcome(outcome) }) { dismiss() }
    }
}

/// The platform-wrapped WKWebView doing the actual work.
private struct AccessWebView {
    let hostname: String
    let onToken: (String) -> Void
    let onFailure: (String) -> Void

    /// Builds the web view the sheet runs in, on a **non-persistent** website
    /// data store.
    ///
    /// This is the difference between a sign-in and a loop. With `WKWebView`'s
    /// default, persistent store, the browser keeps the `CF_Authorization`
    /// cookie across presentations — so the moment the sheet opened, the very
    /// first `didFinish` re-captured the *same* JWT the app had just decided
    /// was unusable (`TokenClearingDialer` clears a token the edge rejected;
    /// "Sign Out of Cloudflare Access" clears one deliberately), committed it,
    /// and closed the sheet before the user could touch anything. The dial
    /// 403s, the sheet opens again, and around it goes until the JWT's own
    /// `exp` finally passes — with "Sign Out" doing nothing observable in the
    /// meantime.
    ///
    /// A store scoped to this one sheet has no cookie to re-capture, so
    /// whatever comes back is the result of an actual round trip through
    /// Cloudflare Access and the identity provider. The cost is the thing it
    /// buys: the IdP session no longer outlives the sheet, so a renewal asks
    /// the IdP again rather than completing silently. Most IdPs answer that
    /// from their own session and it is a redirect, not a password prompt —
    /// and a token the app cannot escape is a far worse trade.
    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        guard let url = URL(string: "https://\(hostname)") else {
            // Report asynchronously: this runs during the representable's
            // make phase, and mutating the parent's @State synchronously here
            // would be a state-during-view-update violation.
            DispatchQueue.main.async { onFailure("\"\(hostname)\" isn't a valid hostname.") }
            return webView
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(hostname: hostname, onToken: onToken, onFailure: onFailure)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let hostname: String
        private let onToken: (String) -> Void
        private let onFailure: (String) -> Void
        private var delivered = false

        init(hostname: String, onToken: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.hostname = hostname
            self.onToken = onToken
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // After every completed navigation (IdP redirects included), look
            // for the Access cookie scoped to our hostname. Matching also
            // requires the cookie's value to be a currently-usable token
            // (`AccessToken.usable(raw:)` — the same rule `AccessTokenStore`
            // applies at connect time): the browser can still be holding a
            // `CF_Authorization` cookie in its last ~60 s before expiry, and
            // committing that would just hand `TransportFactory` a token it's
            // guaranteed to refuse. Skipping it here leaves the sheet waiting
            // for a better one instead of capturing a token doomed to fail —
            // Cancel and the load-failure delegate methods below still fire
            // independently, so this can't turn into a silent, un-escapable
            // hang.
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies { [weak self] cookies in
                    guard let self, !self.delivered else { return }
                    let match = cookies.first { cookie in
                        cookie.name == "CF_Authorization"
                            && accessCookieDomainMatches(cookieDomain: cookie.domain, hostname: self.hostname)
                            && AccessToken.usable(raw: cookie.value) != nil
                    }
                    if let match {
                        self.delivered = true
                        self.onToken(match.value)
                    }
                }
        }

        /// The initial load of `https://<hostname>` itself failed — DNS,
        /// TLS, connection refused, and the like. A cancellation is not one
        /// of those; see `isCancelledNavigationError`.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !delivered, !isCancelledNavigationError(error) else { return }
            onFailure("Couldn't reach \(hostname): \(error.localizedDescription)")
        }

        /// A later navigation — somewhere in the IdP redirect chain — failed
        /// after the initial load succeeded. Same cancellation rule: an IdP
        /// chain replaces its own navigations constantly, and each of those
        /// arrives here as a -999.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !delivered, !isCancelledNavigationError(error) else { return }
            onFailure("Sign-in to \(hostname) failed: \(error.localizedDescription)")
        }
    }
}

#if os(iOS)
extension AccessWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
extension AccessWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
