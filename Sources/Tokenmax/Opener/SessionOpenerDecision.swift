import Foundation

/// Whether to open the next Claude window, and if not, exactly why.
///
/// Modelled on `SchedulingDecision`: every suppression is a named case rather
/// than a nested `if`, so the reason is testable, greppable in the log, and
/// showable in Settings. The difference from the reminder system is what a
/// mistake costs — a missed reminder is an annoyance, a wrong `open` spends the
/// user's quota — so every ambiguity resolves to `skip`.
enum SessionOpenerDecision: Equatable, Sendable {
    case open(cycleID: String)
    case skip(reason: SkipReason)

    enum SkipReason: String, Equatable, Sendable, CaseIterable {
        case disabled
        case cliNotInstalled
        /// Cannot currently confirm the quota guards. Postpones, never cancels —
        /// see `SessionOpener.decide`.
        case dataStale
        case noSessionWindow
        /// A window is already running. The overwhelmingly common case, and not
        /// a problem: the user opened one themselves.
        case windowAlreadyActive
        /// Nothing has ever been observed to expire, so there is no cycle to
        /// open. True on a first run.
        case noExpiredWindow
        case delayNotElapsed
        case alreadyOpenedThisCycle
        case retryTooSoon
        case attemptsExhausted
        case quietHours
        case weeklyQuotaUnknown
        case weeklyQuotaLow
        case extraUsageEnabled
        case extraUsageUnknown
        // Gates that need a subprocess or a file read, applied by the coordinator.
        case notSubscriptionAuth
        case apiKeyConfigured

        /// A correct pause the user need not act on, versus something worth
        /// their attention. Drives the colour in Settings and the popover.
        var isNoteworthy: Bool {
            switch self {
            case .disabled, .windowAlreadyActive, .noExpiredWindow,
                 .delayNotElapsed, .alreadyOpenedThisCycle, .retryTooSoon,
                 .quietHours, .dataStale:
                false
            default:
                true
            }
        }

        var explanation: String {
            switch self {
            case .disabled:
                "Not enabled."
            case .cliNotInstalled:
                "The claude CLI could not be found."
            case .dataStale:
                "Waiting for a fresh reading before opening."
            case .noSessionWindow:
                "No session window has been reported yet."
            case .windowAlreadyActive:
                "A session window is already running."
            case .noExpiredWindow:
                "No window has ended yet."
            case .delayNotElapsed:
                "Waiting out the configured delay after reset."
            case .alreadyOpenedThisCycle:
                "Already opened for this reset cycle."
            case .retryTooSoon:
                "The last attempt failed; waiting before retrying."
            case .attemptsExhausted:
                "Too many failed attempts for this reset cycle."
            case .quietHours:
                "Inside quiet hours — a window opened now would expire unused."
            case .weeklyQuotaUnknown:
                "The weekly quota is unknown, so spending cannot be checked."
            case .weeklyQuotaLow:
                "Weekly quota is below your threshold."
            case .extraUsageEnabled:
                "Extra paid usage is enabled on this account."
            case .extraUsageUnknown:
                "Anthropic did not report the extra-usage setting for this account."
            case .notSubscriptionAuth:
                "Claude Code is not signed in to a Claude subscription."
            case .apiKeyConfigured:
                "An API key is configured in ~/.claude/settings.json, so a run would be billed."
            }
        }
    }

    var cycleID: String? {
        switch self {
        case let .open(cycleID): cycleID
        case .skip: nil
        }
    }

    var skipReason: SkipReason? {
        switch self {
        case .open: nil
        case let .skip(reason): reason
        }
    }
}

/// The pure half of the session opener. No processes, no network, no clock of
/// its own — everything it needs arrives in `Input`, so every guard below is
/// directly unit-testable.
enum SessionOpener {
    /// A failed run is assumed to have spent nothing, so it may be retried. This
    /// bounds that: a network blip must not silently burn the cycle, and it must
    /// not retry forever either.
    static let maxAttemptsPerCycle = 3
    static let retryInterval: TimeInterval = 300

    struct Input {
        var settings: SessionOpenerSettings
        var quietHours: QuietHours
        var sessionWindow: UsageWindow?
        var weeklyWindow: UsageWindow?
        var extraUsageEnabled: Bool?
        var isStale: Bool
        var cliInstalled: Bool
        var state: SessionOpenerState
        var now: Date

        init(
            settings: SessionOpenerSettings,
            quietHours: QuietHours = .init(),
            sessionWindow: UsageWindow?,
            weeklyWindow: UsageWindow?,
            extraUsageEnabled: Bool? = nil,
            isStale: Bool = false,
            cliInstalled: Bool = true,
            state: SessionOpenerState = .init(),
            now: Date = Date()
        ) {
            self.settings = settings
            self.quietHours = quietHours
            self.sessionWindow = sessionWindow
            self.weeklyWindow = weeklyWindow
            self.extraUsageEnabled = extraUsageEnabled
            self.isStale = isStale
            self.cliInstalled = cliInstalled
            self.state = state
            self.now = now
        }
    }

    /// The reset timestamp the endpoint reports jitters by a second or so
    /// between fetches. Bucketing it — with the same 300s bucket the reminder
    /// identifiers use — is what makes "already opened this cycle" hold: a
    /// one-second drift would miss the lookup and open the window twice.
    static func cycleID(expiredResetAt: Date) -> String {
        let bucket = NotificationScheduler.identifierBucket
        let bucketed = Date(
            timeIntervalSince1970: (expiredResetAt.timeIntervalSince1970 / bucket).rounded() * bucket
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "opener-" + formatter.string(from: bucketed)
    }

    /// Every guard that can be decided from data already in hand.
    ///
    /// Ordering matters in one place: `dataStale` comes before anything that
    /// reads a quota number, because the whole point of the check is that those
    /// numbers cannot currently be trusted.
    static func decide(_ input: Input) -> SessionOpenerDecision {
        guard input.settings.enabled else { return .skip(reason: .disabled) }
        guard input.cliInstalled else { return .skip(reason: .cliNotInstalled) }
        guard !input.isStale else { return .skip(reason: .dataStale) }

        guard let session = input.sessionWindow else { return .skip(reason: .noSessionWindow) }
        // `hasNotStarted` is the endpoint's way of saying no window is running:
        // no reset time and nothing used. Anything else means one is live, and
        // there is nothing to open.
        guard session.hasNotStarted else { return .skip(reason: .windowAlreadyActive) }

        guard let expiredResetAt = input.state.lastKnownSessionResetAt else {
            return .skip(reason: .noExpiredWindow)
        }

        let cycle = cycleID(expiredResetAt: expiredResetAt)

        // Anything that actually reached Claude settles the cycle for good.
        if input.state.isSettled(cycle) { return .skip(reason: .alreadyOpenedThisCycle) }

        let priorAttempts = input.state.attempts(for: cycle)
        if priorAttempts.count >= maxAttemptsPerCycle { return .skip(reason: .attemptsExhausted) }
        if let last = input.state.lastAttempt(for: cycle),
           input.now.timeIntervalSince(last.startedAt) < retryInterval
        {
            return .skip(reason: .retryTooSoon)
        }

        let openAt = expiredResetAt.addingTimeInterval(Double(input.settings.delaySeconds))
        guard input.now >= openAt else { return .skip(reason: .delayNotElapsed) }

        if input.settings.respectQuietHours, input.quietHours.contains(input.now) {
            return .skip(reason: .quietHours)
        }

        // The real protection against an unexpected charge: the five-hour and
        // weekly allowances share one budget, so an opener is never free.
        guard let weeklyRemaining = input.weeklyWindow?.remainingPercent else {
            return .skip(reason: .weeklyQuotaUnknown)
        }
        guard weeklyRemaining >= input.settings.minimumWeeklyRemainingPercent else {
            return .skip(reason: .weeklyQuotaLow)
        }

        if input.settings.skipWhenExtraUsageEnabled {
            // Silence is not consent. Unknown is refused rather than assumed
            // off — and because that would otherwise be an invisible dead end,
            // Settings names this reason and offers the toggle as the way out.
            guard let extra = input.extraUsageEnabled else { return .skip(reason: .extraUsageUnknown) }
            if extra { return .skip(reason: .extraUsageEnabled) }
        }

        return .open(cycleID: cycle)
    }

    // MARK: - Gates needing the outside world

    /// The opener must run against a Claude subscription, never pay-as-you-go
    /// API billing. Unknown fields read as unsafe.
    static func authGate(_ status: ClaudeAuthStatus?) -> SessionOpenerDecision.SkipReason? {
        guard let status,
              status.loggedIn == true,
              status.authMethod == "claude.ai",
              status.apiProvider == "firstParty"
        else { return .notSubscriptionAuth }
        return nil
    }

    /// `claude auth status` reports the *stored login* and is unaffected by an
    /// API key supplied through configuration — verified experimentally. So the
    /// settings file has to be checked separately, or the opener could run
    /// against billed usage while `authGate` happily reports a subscription.
    ///
    /// Malformed JSON returns no objection: `~/.claude/settings.json` is
    /// frequently absent or hand-edited, and a parse failure is not evidence of
    /// an API key. The environment the runner builds is scrubbed regardless.
    static func settingsGate(_ data: Data?) -> SessionOpenerDecision.SkipReason? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let helper = root["apiKeyHelper"] as? String, !helper.isEmpty {
            return .apiKeyConfigured
        }
        if let env = root["env"] as? [String: Any] {
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
                if let value = env[key] as? String, !value.isEmpty { return .apiKeyConfigured }
            }
        }
        return nil
    }

    // MARK: - Verification

    /// Did the opener actually produce a new window?
    ///
    /// Requires a reset timestamp strictly later than the moment the opener ran.
    /// Merely having *a* reset time is not enough — a cached reading from before
    /// the run carries the old window's timestamp and would verify a run that
    /// did nothing.
    static func didWindowOpen(sessionWindow: UsageWindow?, sentAt: Date) -> Bool {
        guard let resetAt = sessionWindow?.resetAt else { return false }
        return resetAt > sentAt
    }
}
