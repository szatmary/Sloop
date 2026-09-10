// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Whether a `WKNavigationDelegate` failure means the sign-in failed, or just
/// that a navigation was replaced by another one.
///
/// `NSURLErrorCancelled` (-999) is what a web view reports when a load in
/// flight is superseded — a page's `window.location` assignment, a
/// `<meta http-equiv="refresh">`, a form POST that starts before the previous
/// provisional load finished. An identity provider's redirect chain is made of
/// exactly those, so treating -999 as fatal aborted ordinary, working sign-ins
/// and reported a failure the user could do nothing about. Nothing is lost by
/// ignoring it: the navigation that replaced it either finishes (and
/// `didFinish` looks for the cookie) or fails on its own terms with a real
/// error.
public func isCancelledNavigationError(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
}

/// What to tell the user when the sign-in page itself never loaded.
///
/// The generic phrasing ("Sign-in to X failed: …") is wrong for the most
/// common cause by far, a mistyped hostname: nothing about signing in is
/// broken, the name simply doesn't resolve, and a message about sign-in sends
/// the user to re-authenticate — which cannot possibly help — instead of to
/// the one field that can. These three URL errors mean the name or the address
/// is wrong, so they say so and point at the setting to fix.
public func accessLoginFailureMessage(hostname: String, error: Error) -> String {
    let error = error as NSError
    let nameOrAddressIsWrong = error.domain == NSURLErrorDomain
        && [NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorCannotConnectToHost].contains(error.code)
    if nameOrAddressIsWrong {
        return "There's nothing at \"\(hostname)\". Check the hostname in this " +
               "host's settings — it should be the Cloudflare Access " +
               "application's public hostname. This isn't a sign-in problem, so " +
               "signing in again won't help."
    }
    return "Couldn't load the sign-in page for \(hostname): \(error.localizedDescription)"
}

/// How a browser SSO sheet ended (see `AccessLoginView` in the app target).
///
/// Three cases, not two, because "the user closed the sheet" and "the sign-in
/// broke" call for opposite treatment: the first is a decision the user just
/// made and needs no acknowledgement, the second is news they can act on. The
/// sheet used to report both through one failure channel, so dismissing it
/// deliberately raised an error alert in the host list — an app arguing with
/// the user about a button they pressed on purpose. Separating them at the
/// type level means a caller cannot conflate them again without deleting a
/// `case`.
public enum AccessLoginOutcome: Equatable {
    /// A usable `CF_Authorization` JWT was captured.
    case token(String)
    /// The user dismissed the sheet — the Cancel button, or a swipe. Nothing
    /// to report.
    case cancelled
    /// The sign-in could not be completed, with a reason worth showing.
    case failed(String)
}

/// Guards the terminal outcome of a browser SSO sheet (see `AccessLoginView`
/// in the app target) so exactly one of several racing exits — success, an
/// explicit cancel, a navigation failure, or an interactive swipe-dismiss —
/// is ever acted on.
///
/// The sheet has several independent ways to end, some driven by the user
/// and some by asynchronous `WKWebView`/`WKNavigationDelegate` callbacks that
/// can still be in flight when another exit already fired. Routing every
/// terminal path through `commit(_:)` on a single shared gate — instead of a
/// separate flag per route — means whichever one gets there first wins, and
/// anything that lands afterward (a cookie lookup that resolves after the
/// user already swiped the sheet away, say) is a safe no-op rather than
/// quietly succeeding after failure was already reported, or reporting
/// failure twice.
///
/// Not thread-safe by itself — the app only ever touches an instance from
/// the main actor, where `AccessLoginView`'s `@State` and
/// `WKNavigationDelegate` callbacks both run, so calls are never actually
/// concurrent.
public final class AccessLoginOutcomeGate {
    public private(set) var isFinished = false

    public init() {}

    /// Runs `action` iff this is the first call `commit` has ever seen;
    /// every later call (whatever action it carries) is dropped. Returns
    /// whether `action` ran, so a caller that also needs to dismiss the
    /// sheet can do that only when it "won".
    @discardableResult
    public func commit(_ action: () -> Void) -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        action()
        return true
    }
}
