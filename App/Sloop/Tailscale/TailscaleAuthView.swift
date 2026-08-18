// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import WebKit

/// The tailnet's device-authorization page, in a sheet.
///
/// Unlike the Cloudflare Access sheet, nothing is captured here: tsnet is
/// running its own login in the background and learns the outcome from the
/// control plane, not from this web view. So there is nothing to watch for and
/// nothing to parse — the sheet exists purely so the user can complete the
/// login, and closing it is the only thing it reports.
struct TailscaleAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            AuthWebView(url: url)
                .navigationTitle("Authorize Sloop")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("Approve this device, then reconnect to the host.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

private struct AuthWebView {
    let url: URL

    func makeWebView() -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }
}

#if os(iOS)
extension AuthWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
extension AuthWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
