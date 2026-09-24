import Foundation

/// The rules for asking Claude Code to renew its own login.
///
/// **Why this exists.** Claude Code rotates its access token only when it runs.
/// Leave it idle past the token's expiry and the keychain keeps holding the
/// rejected token, so Tokenmax sat in "needs Claude Code to renew" until the
/// user either happened to use Claude Code or clicked Sign In — which walks
/// them through an OAuth flow they did not need, because the refresh token was
/// fine all along.
///
/// **What it does instead.** Starts `claude` in a hidden terminal, types
/// `/status`, and waits for Claude Code to write a new login to the keychain.
/// Claude Code does the renewal with its own refresh token, exactly as it would
/// if the user had opened it. Tokenmax still never calls Anthropic's token
/// endpoint: two programs refreshing one OAuth login can invalidate each
/// other's credentials, and that invariant is untouched here.
///
/// **Why it cannot spend quota.** The only input ever written to the terminal
/// is one of the fixed `Keystroke`s. No free text can be typed, so nothing
/// reaches a model. The argv carries no prompt and no `--print`, and disables
/// tools, MCP servers and settings files the same way the session opener does.
///
/// Pure: no clock, no process, no keychain. `ClaudeTokenRenewalCoordinator`
/// owns those.
enum ClaudeTokenRenewal {
    /// Between automatic attempts. Long enough that a Claude Code which will
    /// not renew costs a hidden process a few times an hour at most; short
    /// enough that an expired token is usually fixed before anyone looks.
    static let cooldown: TimeInterval = 15 * 60

    /// Runs that left the keychain item untouched before automatic attempts
    /// stop. Two, not one: a single miss can be a slow network during startup.
    /// After that, it is Claude Code telling us this route does not work, and
    /// repeating it every fifteen minutes would only be noise.
    static let maxAttemptsWithoutEffect = 2

    /// How long one run may take. A cold CLI start plus a token request is a
    /// few seconds; anything past this is a CLI that is waiting on something
    /// it will never get.
    static let timeout: TimeInterval = 25

    /// Quiet time after the last output before `/status` is typed, so it lands
    /// in a ready prompt rather than in the middle of the startup screen.
    static let statusDelay: TimeInterval = 3

    /// Between SIGTERM and SIGKILL when stopping the run.
    static let killGrace: TimeInterval = 2

    struct Input: Equatable, Sendable {
        var awaitingRenewal: Bool
        var dataSource: ClaudeDataSource
        var claudeEnabled: Bool
        var cliFound: Bool
        var isRunning: Bool
        var signInInProgress: Bool
        var lastAttemptAt: Date?
        var attemptsWithoutEffect: Int
        var userRequested: Bool
        var now: Date
    }

    enum Reason: Equatable, Sendable {
        case notAwaitingRenewal
        case statuslineOnly
        case providerDisabled
        case cliMissing
        case alreadyRunning
        case signInInProgress
        case coolingDown(until: Date)
        case noEffect

        var explanation: String {
            switch self {
            case .notAwaitingRenewal:
                "Claude Code's saved credential is not waiting for renewal."
            case .statuslineOnly:
                "Status line only mode never reads the keychain, so there is no saved credential to renew."
            case .providerDisabled:
                "Claude Code is switched off in Settings."
            case .cliMissing:
                "Tokenmax could not find the claude CLI to renew the login with."
            case .alreadyRunning:
                "Claude Code is already renewing its login."
            case .signInInProgress:
                "A sign-in is in progress; it replaces the login anyway."
            case let .coolingDown(until):
                "Claude Code did not renew yet. Tokenmax asks again at \(until.formatted(date: .omitted, time: .shortened)), or click Refresh."
            case .noEffect:
                "Claude Code ran but did not renew its login. Sign in again, or click Refresh to try once more."
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case run
        case suppressed(Reason)
    }

    /// `userRequested` is the Refresh click. It skips the waiting rules — the
    /// cooldown and the no-effect limit exist to stop the app asking on its
    /// own, not to overrule the user — and nothing else: a disabled provider,
    /// status-line mode or a sign-in in flight mean the run cannot help.
    static func decide(_ input: Input) -> Verdict {
        guard input.claudeEnabled else { return .suppressed(.providerDisabled) }
        guard input.dataSource == .keychain else { return .suppressed(.statuslineOnly) }
        guard input.awaitingRenewal else { return .suppressed(.notAwaitingRenewal) }
        guard !input.signInInProgress else { return .suppressed(.signInInProgress) }
        guard !input.isRunning else { return .suppressed(.alreadyRunning) }
        guard input.cliFound else { return .suppressed(.cliMissing) }
        if input.userRequested { return .run }
        if input.attemptsWithoutEffect >= maxAttemptsWithoutEffect { return .suppressed(.noEffect) }
        if let last = input.lastAttemptAt {
            let until = last.addingTimeInterval(cooldown)
            if input.now < until { return .suppressed(.coolingDown(until: until)) }
        }
        return .run
    }

    /// Whether Claude Code wrote the item during the run. A missing reading
    /// afterwards is never a change: Claude Code rewrites by delete-then-add,
    /// and catching the gap must not count as a renewal.
    static func itemChanged(baseline: Date?, current: Date?) -> Bool {
        guard let current else { return false }
        guard let baseline else { return true }
        return current > baseline
    }

    // MARK: - The run

    /// Interactive on purpose: `/status` is a slash command, and the startup it
    /// follows is what makes Claude Code check its login. Everything that could
    /// act on the machine or bill anything is off:
    ///
    /// - `--tools ""` disables every built-in tool;
    /// - `--strict-mcp-config` with no config means no MCP servers;
    /// - `--setting-sources ""` loads no settings files, so no hooks run and no
    ///   `env` block can bring an API key in behind our back.
    ///
    /// Never `--print`, never a prompt, never `--dangerously-skip-permissions`.
    static let arguments = [
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "",
    ]

    /// The same allowlist as `ClaudeSignIn.environment` — a home directory and
    /// a path, nothing that could carry an API key. `TERM` because an
    /// interactive CLI draws differently (or not at all) without one; the
    /// autoupdater is off because a renewal must not change the user's install.
    static func environment(from parent: [String: String]) -> [String: String] {
        var result = ClaudeSignIn.environment(from: parent)
        result["TERM"] = "xterm-256color"
        result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    /// Everything that can ever be written to the terminal. A closed set, so
    /// no code path can type a prompt.
    enum Keystroke: CaseIterable, Sendable {
        /// Only when the screen shows the folder-trust question. The folder is
        /// an empty one Tokenmax owns, so trusting it grants nothing.
        case acceptTrust
        case status
        case escape

        var bytes: String {
            switch self {
            case .acceptTrust: "\r"
            case .status: "/status\r"
            case .escape: "\u{1b}"
            }
        }
    }

    /// Whether the terminal is showing Claude Code's folder-trust question.
    ///
    /// The screen arrives as terminal output, where words may be separated by
    /// cursor movements rather than spaces, so escape sequences and whitespace
    /// are stripped before matching.
    static func showsTrustPrompt(_ screen: String) -> Bool {
        let stripped = screen
            .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
            .lowercased()
        return stripped.contains("trustthisfolder") || stripped.contains("trustthefilesinthisfolder")
    }

    enum RunResult: Equatable, Sendable {
        case renewed
        case unchanged
        case failedToStart(String)
    }
}
