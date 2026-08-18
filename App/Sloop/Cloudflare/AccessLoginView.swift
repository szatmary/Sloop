// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// App/Sloop/Cloudflare/AccessLoginView.swift
import SwiftUI
import WebKit
import SloopKit

/// Browser SSO for a Cloudflare Access-protected hostname. Loads
/// `https://<hostname>`, lets Access bounce through the IdP, and captures the
/// resulting `CF_Authorization` cookie — which IS the Access JWT — from the
/// web view's cookie store. The default (persistent) store is used on purpose:
/// the IdP session survives, so token renewals need no password re-entry.
///
/// Every way the sheet can end without a token — the user cancels, swipes
/// the sheet away, the hostname doesn't parse as a URL, or the navigation
/// itself fails — reports a specific reason via `onFailure` instead of
/// silently leaving the caller waiting.
struct AccessLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let hostname: String
    let onToken: (String) -> Void
    let onFailure: (String) -> Void

    /// The sheet can end in several independent, sometimes-racing ways: a
    /// token arrives, the user taps Cancel, the user swipes the sheet away
    /// (no explicit action at all), or a navigation fails. All of them route
    /// through this one gate so whichever gets there first wins and every
    /// other — including a `getAllCookies` completion that resolves after
    /// the sheet is already gone — is a no-op. See `AccessLoginOutcomeGate`.
    @State private var outcome = AccessLoginOutcomeGate()

    private var noTokenMessage: String { "No Access token was captured for \(hostname)." }

    var body: some View {
        NavigationStack {
            AccessWebView(hostname: hostname, onToken: { token in
                if outcome.commit({ onToken(token) }) { dismiss() }
            }, onFailure: { message in
                if outcome.commit({ onFailure(message) }) { dismiss() }
            })
            .navigationTitle(hostname)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if outcome.commit({ onFailure(noTokenMessage) }) { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .onDisappear {
            // Catches the one exit with no explicit action of its own: an
            // interactive swipe-to-dismiss. Every other exit above already
            // committed the gate before dismissing, so this is a no-op for
            // them — and once the gate is committed here, nothing async
            // arriving later can still succeed or double-report either.
            outcome.commit { onFailure(noTokenMessage) }
        }
    }
}

/// The platform-wrapped WKWebView doing the actual work.
private struct AccessWebView {
    let hostname: String
    let onToken: (String) -> Void
    let onFailure: (String) -> Void

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
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
        /// TLS, connection refused, and the like.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !delivered else { return }
            onFailure("Couldn't reach \(hostname): \(error.localizedDescription)")
        }

        /// A later navigation — somewhere in the IdP redirect chain — failed
        /// after the initial load succeeded.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !delivered else { return }
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
