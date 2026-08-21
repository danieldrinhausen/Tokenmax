import Foundation

/// Holds the last successful keychain read in memory, so the app asks macOS for
/// the Claude credentials once rather than once per refresh.
///
/// **Why this exists.** Reading the credential item can raise a consent dialog,
/// and the dialog offers *Allow* as well as *Always Allow*. Only *Always Allow*
/// writes a grant; *Allow* is good for that one read. Without a cache every
/// refresh tick issued a fresh read — every 60s with the popover open, every
/// 300s behind it, and twice over when the token looked expired — so anyone who
/// took the middle button got a dialog a minute, forever. Measured on the live
/// item: the grant is keyed to the build's cdhash because the bundle carries no
/// Team ID, which is a separate problem this cannot fix (see
/// `docs/TROUBLESHOOTING.md`). What it does fix is the *rate*: one read per app
/// launch instead of one per tick.
///
/// **What is deliberately not cached.** Failures — with one exception. Caching
/// a `.notFound` would turn "not logged in when Tokenmax started" into a
/// permanent state that only a relaunch clears, so missing items, malformed
/// payloads and everything transient are retried on the next call. Same rule as
/// everywhere else here: stale data postpones, it never cancels.
///
/// **The exception is an explicit denial.** The user answered the dialog, and
/// that answer *is* a decision — re-asking on the next tick turned one *Deny*
/// into a dialog every five minutes for as long as the app ran, which is the
/// app arguing with the user. A denial is remembered for the rest of the
/// launch and replayed without touching the keychain. The way back is
/// deliberate and visible, not a timer: the popover shows "Keychain access
/// denied", and a *manual* refresh clears the memory so macOS may ask again
/// (see `retryAfterDenial`). Only `KeychainError.accessDenied` gets this —
/// `errSecInteractionNotAllowed` is environmental, not an answer, and is kept
/// out of that case for exactly this reason.
///
/// **Staleness.** Claude Code rotates the token in place, without telling
/// anyone. A cached token stays usable until its own `expiresAt`, which is
/// checked on every hand-out, and a token the endpoint rejects is dropped by
/// the caller through `invalidate()`. Those two together are what keep a
/// rotation from being noticed only at relaunch.
///
/// Nothing here reaches disk. The credentials live in this process and die
/// with it.
final class ClaudeCredentialCache: @unchecked Sendable {
    private let read: @Sendable () throws -> ClaudeKeychain.Credentials
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var stored: ClaudeKeychain.Credentials?
    private var denied = false

    init(
        read: @escaping @Sendable () throws -> ClaudeKeychain.Credentials,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.read = read
        self.now = now
    }

    /// The cached credentials when they are still within their own expiry,
    /// otherwise a fresh read.
    ///
    /// A locally-expired token is dropped rather than handed out, because the
    /// keychain very likely holds a newer one by now. That is not the same as
    /// refusing to *use* an expired token: the provider still tries whatever it
    /// gets against the endpoint, since the clock is only a hint.
    func credentials() throws -> ClaudeKeychain.Credentials {
        lock.lock()
        if denied {
            lock.unlock()
            throw ClaudeKeychain.KeychainError.accessDenied
        }
        if let stored, !stored.isExpired(at: now()) {
            lock.unlock()
            return stored
        }
        stored = nil
        lock.unlock()

        // Read outside the lock: it can block on a consent dialog for as long
        // as the user takes to answer, and holding a lock across that would
        // stall every other caller behind the same dialog.
        do {
            let fresh = try read()
            lock.lock()
            stored = fresh
            lock.unlock()
            return fresh
        } catch ClaudeKeychain.KeychainError.accessDenied {
            lock.lock()
            denied = true
            lock.unlock()
            throw ClaudeKeychain.KeychainError.accessDenied
        }
    }

    /// Drops everything remembered — credentials and denial alike — so the
    /// next call reads the keychain again.
    ///
    /// Called when the endpoint rejects the token — the only reliable signal
    /// that Claude Code has rotated it since we looked.
    func invalidate() {
        lock.lock()
        stored = nil
        denied = false
        lock.unlock()
    }

    /// Forgets a remembered denial, so the next read may raise the dialog
    /// again. Credentials, if any, are untouched.
    ///
    /// Reached only from a *manual* refresh: clicking Refresh is the explicit
    /// "ask me again" the denial backoff waits for. A timer tick never clears
    /// it — that would put the every-five-minutes dialog straight back.
    func retryAfterDenial() {
        lock.lock()
        denied = false
        lock.unlock()
    }
}
