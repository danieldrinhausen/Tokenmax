import Foundation

/// The rules behind the popover's **Sign In with Claude** button.
///
/// Tokenmax does not sign in itself. It runs `claude auth login`, which opens
/// Claude's OAuth page in the default browser, waits for the localhost
/// callback, and writes the new login to the keychain item Tokenmax already
/// reads. Claude Code stays the only program that ever obtains or rotates the
/// token, so the "never refresh the token" invariant holds: this is the same
/// command the user used to paste into a terminal, minus the terminal.
enum ClaudeSignIn {
    /// Long enough to find a password manager and approve a 2FA prompt; short
    /// enough that an abandoned browser tab does not leave a login server
    /// listening on a localhost port all afternoon.
    static let timeout: TimeInterval = 10 * 60

    /// `--claudeai` pins the subscription login. `--console` would sign in to
    /// API billing, which the session opener refuses to run under and the
    /// queue would then spend real money against. The default is the same
    /// today; passing it explicitly means a changed default cannot move us.
    static let arguments = ["auth", "login", "--claudeai"]

    /// Deliberately excludes `BROWSER`: the login must open in the user's real
    /// browser, not whatever a launch environment happened to point it at. An
    /// allowlist for the same reason as `ClaudeOpenerRunner.environment` — the
    /// login needs a home directory and a path, and nothing else.
    static func environment(from parent: [String: String]) -> [String: String] {
        let allowed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR"]
        var result = parent.filter { allowed.contains($0.key) }
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        return result
    }

    /// How long to wait after a successful sign-in before asking for usage.
    ///
    /// The rejected token's request started the client's 180s floor, and a
    /// refresh inside it replays the cached reading — which the refresh
    /// coordinator correctly refuses to treat as a renewal. Asking early would
    /// leave "needs renewal" on screen for a login that in fact worked.
    static func refreshDelay(now: Date, nextRequestAllowedAt: Date) -> TimeInterval {
        max(0, nextRequestAllowedAt.timeIntervalSince(now)) + 1
    }

    enum Outcome: Equatable, Sendable {
        case signedIn
        case cliMissing
        case failedToStart(String)
        case cancelled
        case timedOut
        case failed(exitCode: Int32)

        /// Cancellation and timeout are checked before the exit code: both end
        /// in a signal Tokenmax sent, and the status that produces says nothing
        /// about whether the login worked.
        static func from(exitCode: Int32, cancelled: Bool, timedOut: Bool) -> Outcome {
            if cancelled { return .cancelled }
            if timedOut { return .timedOut }
            return exitCode == 0 ? .signedIn : .failed(exitCode: exitCode)
        }

        /// What the popover says afterwards. `nil` where the change is visible
        /// on its own — a success replaces the error with a reading, and a
        /// cancel is the user's own click.
        var message: String? {
            switch self {
            case .signedIn, .cancelled:
                nil
            case .cliMissing:
                "Tokenmax could not find the claude CLI to sign in with."
            case let .failedToStart(detail):
                "Could not start the sign-in: \(detail). Run `claude auth login` in Terminal instead."
            case .timedOut:
                "The sign-in was not finished within 10 minutes, so Tokenmax stopped waiting. Try again when you are ready."
            case let .failed(exitCode):
                "The sign-in did not complete (exit \(exitCode)). Run `claude auth login` in Terminal to see why."
            }
        }
    }
}
