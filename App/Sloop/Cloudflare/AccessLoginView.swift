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

    /// Set once a token is delivered, so a subsequent dismissal (the sheet
    /// closing itself after success) isn't also reported as a failure.
    @State private var delivered = false
    /// Set by the Cancel button. The web view's cookie lookup is async, so a
    /// lookup already in flight when the user cancels could otherwise still
    /// land afterward and deliver a token for a connection the user just
    /// called off; this guard closes that race regardless of how the
    /// coordinator's own (separate) `delivered` flag is timed.
    @State private var cancelled = false
    /// The most specific reason available when the sheet disappears without
    /// a token — set by a navigation failure before dismissal, if any.
    @State private var lastFailureReason: String?

    var body: some View {
        NavigationStack {
            AccessWebView(hostname: hostname, onToken: { token in
                guard !cancelled, !delivered else { return }
                delivered = true
                onToken(token)
                dismiss()
            }, onFailure: { message in
                guard !cancelled, !delivered else { return }
                lastFailureReason = message
                dismiss()
            })
            .navigationTitle(hostname)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelled = true
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
        .onDisappear {
            // Covers every non-success path in one place: an explicit Cancel,
            // an interactive swipe-to-dismiss, or a navigation failure that
            // already recorded a specific reason above.
            guard !delivered else { return }
            onFailure(lastFailureReason ?? "No Access token was captured for \(hostname).")
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
            // for the Access cookie scoped to our hostname.
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies { [weak self] cookies in
                    guard let self, !self.delivered else { return }
                    let match = cookies.first { cookie in
                        cookie.name == "CF_Authorization"
                            && accessCookieDomainMatches(cookieDomain: cookie.domain, hostname: self.hostname)
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
