// App/Sloop/Cloudflare/AccessLoginView.swift
import SwiftUI
import WebKit

/// Browser SSO for a Cloudflare Access-protected hostname. Loads
/// `https://<hostname>`, lets Access bounce through the IdP, and captures the
/// resulting `CF_Authorization` cookie — which IS the Access JWT — from the
/// web view's cookie store. The default (persistent) store is used on purpose:
/// the IdP session survives, so token renewals need no password re-entry.
struct AccessLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let hostname: String
    let onToken: (String) -> Void

    var body: some View {
        NavigationStack {
            AccessWebView(hostname: hostname) { token in
                onToken(token)
                dismiss()
            }
            .navigationTitle(hostname)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

/// The platform-wrapped WKWebView doing the actual work.
private struct AccessWebView {
    let hostname: String
    let onToken: (String) -> Void

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        if let url = URL(string: "https://\(hostname)") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostname: hostname, onToken: onToken)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let hostname: String
        private let onToken: (String) -> Void
        private var delivered = false

        init(hostname: String, onToken: @escaping (String) -> Void) {
            self.hostname = hostname
            self.onToken = onToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // After every completed navigation (IdP redirects included), look
            // for the Access cookie scoped to our hostname.
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies { [weak self] cookies in
                    guard let self, !self.delivered else { return }
                    let match = cookies.first { cookie in
                        cookie.name == "CF_Authorization" && self.domainMatches(cookie.domain)
                    }
                    if let match {
                        self.delivered = true
                        self.onToken(match.value)
                    }
                }
        }

        /// Cookie domains may be exact ("ssh.example.com") or parent-scoped
        /// (".example.com").
        private func domainMatches(_ cookieDomain: String) -> Bool {
            let domain = cookieDomain.hasPrefix(".")
                ? String(cookieDomain.dropFirst()) : cookieDomain
            return hostname == domain || hostname.hasSuffix("." + domain)
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
