// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Somewhere to send a device-authorization URL that a person can act on.
///
/// The dial runs on a worker thread with no view in reach, and the app answers
/// this by raising a sheet. The File Provider extension answers it by doing
/// nothing at all: it has no UI, cannot get one, and runs while the app is
/// closed. That difference is exactly why this is a protocol and not a direct
/// call to the app's prompter — a framework shared with an extension cannot
/// reach into `@MainActor` app state, and pretending otherwise is what makes
/// shared code stop being shareable.
///
/// Declared outside `#if SLOOP_TAILSCALE`, unlike the dialer that uses it: the
/// factories take one as a parameter whether or not this build links tsnet, and
/// a protocol that exists only in some build variants makes every signature
/// mentioning it conditional too.
public protocol TailscaleAuthorizationPresenter: AnyObject, Sendable {
    func presentAuthorization(_ url: URL)
}

/// Discards the URL. What a process with no UI can honestly do — the error
/// thrown alongside it is what actually reaches the user, telling them to open
/// Sloop.
public final class NoAuthorizationPresenter: TailscaleAuthorizationPresenter {
    public init() {}
    public func presentAuthorization(_ url: URL) {}
}
