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
/// **Staleness.** Claude Code changes the token without telling anyone. A
/// cached token stays usable until its own `expiresAt`, which is
/// checked on every hand-out, and a token the endpoint rejects is dropped by
/// the caller through `invalidate()`. Those two together are what keep a
/// rotation from being noticed only at relaunch.
///
/// **Why a drop does not immediately mean another read.** `invalidate()` says
/// "the endpoint rejected this token", and the obvious next move — go back to
/// the keychain — is wrong whenever Claude Code has not rotated yet: the item
/// still holds the *same* rejected token, so the read costs a dialog and
/// returns nothing new. Measured over a fortnight of real use, 64 of 176 reads
/// were this loop, re-reading every five minutes for hours and stacking
/// consent dialogs minutes apart. So a drop records *when the item was last
/// written*, and the next read waits for that timestamp to move. Attribute
/// reads are not gated by the item's ACL — only reads of the secret data are —
/// so the app can watch for the rotation without ever raising a dialog.
///
/// The gate fails open. No timestamp (an item we could not stat, a test with
/// no probe injected) means read as before: a redundant read costs a dialog,
/// but a gate stuck shut costs monitoring, and the house rule is that stale
/// data postpones rather than cancels. A relaunch clears it, and so does the
/// Refresh button, for the same reason it clears a denial.
///
/// Nothing here reaches disk. The credentials live in this process and die
/// with it.
final class ClaudeCredentialCache: @unchecked Sendable {
    /// What the keychain looked like when the token the endpoint rejected was
    /// read, plus whether that token could still renew itself — the caller
    /// needs the distinction to tell "Claude Code will fix this" from "sign in
    /// again", and the credentials it came from are gone by then.
    private struct RejectedRead {
        let modification: Date
        let canSelfRenew: Bool
    }

    private let read: @Sendable () throws -> ClaudeKeychain.Credentials
    /// When Claude Code last wrote the item. Raises no dialog — see the class
    /// note. Defaults to "unknown", which switches the rotation gate off.
    private let itemModified: @Sendable () -> Date?
    private let now: @Sendable () -> Date
    /// Where the cache narrates itself — why it went to the keychain, what it
    /// dropped and why. Injected so tests can assert the story and production
    /// can point it at `Log.shared`. The lines exist because "when exactly
    /// does the dialog appear" is unanswerable from memory; the log is the
    /// instrument users can actually hand over.
    private let log: @Sendable (String) -> Void
    private let condition = NSCondition()
    private var stored: ClaudeKeychain.Credentials?
    /// The item's write timestamp sampled *before* the read that produced
    /// `stored`. Before, not after: if Claude Code writes during the read, an
    /// earlier stamp makes the gate open one read too often, where a later one
    /// would hold a fresh token back.
    private var storedModification: Date?
    private var rejected: RejectedRead?
    private var denied = false
    private var isReading = false

    init(
        read: @escaping @Sendable () throws -> ClaudeKeychain.Credentials,
        itemModified: @escaping @Sendable () -> Date? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.read = read
        self.itemModified = itemModified
        self.now = now
        self.log = log
    }

    /// The cached credentials when they are still within their own expiry,
    /// otherwise a fresh read.
    ///
    /// A locally-expired token is dropped rather than handed out, because the
    /// keychain very likely holds a newer one by now. That is not the same as
    /// refusing to *use* an expired token: the provider still tries whatever it
    /// gets against the endpoint, since the clock is only a hint.
    func credentials() throws -> ClaudeKeychain.Credentials {
        condition.lock()
        while isReading {
            // Several coordinators can arrive together on launch. The first
            // one owns the system dialog; the rest wait for its answer instead
            // of presenting the same question in parallel.
            condition.wait()
        }
        if denied {
            condition.unlock()
            throw ClaudeKeychain.KeychainError.accessDenied
        }
        // Checked before `stored`, which `invalidate()` has already emptied, and
        // under the lock: the probe is a fast local call that cannot raise a
        // dialog, unlike `read()`, which is deliberately run unlocked below
        // because it can block on one for hours.
        var rotationSeen = false
        if let rejected {
            if let current = itemModified(), current == rejected.modification {
                condition.unlock()
                throw ClaudeKeychain.KeychainError.awaitingRotation(
                    canSelfRenew: rejected.canSelfRenew
                )
            }
            self.rejected = nil
            rotationSeen = true
        }
        if let stored, !stored.isExpired(at: now()) {
            condition.unlock()
            return stored
        }
        // Named before the read so every keychain line in the log has the line
        // above it saying why the read happened at all.
        let trigger = if rotationSeen {
            "Claude Code rewrote the item after the token was rejected"
        } else if stored == nil {
            "nothing cached yet"
        } else {
            "cached token expired"
        }
        stored = nil
        isReading = true
        // Sampled before the read, so a write that lands mid-read is not
        // mistaken for the state the returned token came from.
        let sampled = itemModified()
        condition.unlock()
        log("keychain: reading (\(trigger))")

        // The Keychain call itself runs without the condition locked. Other
        // callers deliberately wait above: stalling behind one dialog is the
        // correct result; raising a dialog per caller is not.
        do {
            let fresh = try read()
            condition.lock()
            stored = fresh
            storedModification = sampled
            isReading = false
            condition.broadcast()
            condition.unlock()
            return fresh
        } catch ClaudeKeychain.KeychainError.accessDenied {
            condition.lock()
            denied = true
            isReading = false
            condition.broadcast()
            condition.unlock()
            throw ClaudeKeychain.KeychainError.accessDenied
        } catch {
            condition.lock()
            isReading = false
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    /// Drops the credentials and any remembered denial, and arms the rotation
    /// gate so the next call waits for Claude Code to write the item rather
    /// than re-reading a token already known to be rejected.
    ///
    /// Called when the endpoint rejects the token — the only reliable signal
    /// that Claude Code has rotated it since we looked. "Rotated" is the
    /// optimistic reading, though: until the item's timestamp actually moves,
    /// the honest state is that we asked and were told no.
    func invalidate() {
        condition.lock()
        let droppedSomething = stored != nil || denied
        // Only a read we have a timestamp for can be waited on. Without one the
        // gate stays disarmed and the next call reads as it always did.
        if let stored, let modification = storedModification {
            rejected = RejectedRead(
                modification: modification,
                canSelfRenew: stored.refreshToken != nil
            )
        }
        let armed = rejected != nil
        stored = nil
        storedModification = nil
        denied = false
        condition.unlock()
        // Logged only when there was something to drop — an invalidate of an
        // already-empty cache explains no subsequent read.
        if droppedSomething {
            log(
                armed
                    ? "keychain: cached credentials dropped (endpoint rejected the token — waiting for Claude Code to rewrite the item before reading again)"
                    : "keychain: cached credentials dropped (endpoint rejected the token — Claude Code has likely rotated it)"
            )
        }
    }

    /// Forgets a remembered denial *and* a rotation the gate is waiting on, so
    /// the next read goes back to the keychain. Credentials, if any, are
    /// untouched.
    ///
    /// Reached only from a *manual* refresh: clicking Refresh is the explicit
    /// "ask me again" both backoffs wait for. A timer tick never clears
    /// them — that would put the every-five-minutes dialog straight back.
    ///
    /// The rotation gate is cleared here too because the button means "try
    /// everything again", and the alternative is a state the user can see in
    /// the popover but has no way to leave short of relaunching. The read it
    /// permits will usually return the same rejected token; that is a fair
    /// price for the gate never being a trap.
    func retryAfterDenial() {
        condition.lock()
        let wasDenied = denied
        let wasAwaitingRotation = rejected != nil
        denied = false
        rejected = nil
        condition.unlock()
        // Every manual refresh calls this; only the one that actually forgives
        // something is worth a line, or the log claims dialogs that never came.
        if wasDenied {
            log("keychain: denial forgotten after manual refresh — macOS may ask again on the next read")
        }
        if wasAwaitingRotation {
            log("keychain: rotation wait cleared after manual refresh — the next read goes to the keychain")
        }
    }
}
