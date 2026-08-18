import Foundation

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
