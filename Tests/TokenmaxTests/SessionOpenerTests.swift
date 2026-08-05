import Foundation
import Testing

@testable import Tokenmax

@Suite("Session opener")
struct SessionOpenerTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    /// The window that just ended, an hour before `now`.
    private var expiredResetAt: Date { now.addingTimeInterval(-3600) }

    // MARK: - Builders

    /// A session window in the "no window running" shape the endpoint reports
    /// between the old window expiring and the next prompt.
    private func idleSession() -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: .session,
            label: "Session",
            usedPercent: 0,
            resetAt: nil,
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func activeSession(resetInMinutes: Double = 120) -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: .session,
            label: "Session",
            usedPercent: 30,
            resetAt: now.addingTimeInterval(resetInMinutes * 60),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func weekly(remaining: Double) -> UsageWindow {
        UsageWindow(
            id: "claude.weekly",
            kind: .weekly,
            label: "Weekly",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(86400),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    /// A model-specific weekly window, in the shape the endpoint reports for
    /// `seven_day_sonnet` / `seven_day_opus`.
    private func modelWeekly(_ model: String, remaining: Double) -> UsageWindow {
        UsageWindow(
            id: "claude.weekly.\(model)",
            kind: .modelSpecificWeekly,
            label: "Weekly (\(model))",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(86400),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func settings(
        enabled: Bool = true,
        delaySeconds: Int = 60,
        minimumWeekly: Double = 10,
        respectQuietHours: Bool = true,
        skipWhenExtraUsage: Bool = true
    ) -> SessionOpenerSettings {
        var settings = SessionOpenerSettings()
        settings.enabled = enabled
        settings.delaySeconds = delaySeconds
        settings.minimumWeeklyRemainingPercent = minimumWeekly
        settings.respectQuietHours = respectQuietHours
        settings.skipWhenExtraUsageEnabled = skipWhenExtraUsage
        return settings
    }

    private func stateWithExpiredWindow() -> SessionOpenerState {
        var state = SessionOpenerState()
        state.lastKnownSessionResetAt = expiredResetAt
        return state
    }

    /// Everything lined up so the opener fires. Each test spoils exactly one
    /// thing, so a failure names its own cause.
    private func input(
        settings: SessionOpenerSettings? = nil,
        quietHours: QuietHours = .init(),
        session: UsageWindow? = nil,
        weeklyRemaining: Double? = 80,
        modelWeeklyWindows: [UsageWindow] = [],
        extraUsageEnabled: Bool? = false,
        isStale: Bool = false,
        awaitingTokenRenewal: Bool = false,
        dataAge: TimeInterval = 0,
        cliInstalled: Bool = true,
        state: SessionOpenerState? = nil,
        now: Date? = nil
    ) -> SessionOpener.Input {
        SessionOpener.Input(
            settings: settings ?? self.settings(),
            quietHours: quietHours,
            sessionWindow: session ?? idleSession(),
            weeklyWindow: weeklyRemaining.map { weekly(remaining: $0) },
            modelWeeklyWindows: modelWeeklyWindows,
            extraUsageEnabled: extraUsageEnabled,
            isStale: isStale,
            awaitingTokenRenewal: awaitingTokenRenewal,
            dataAge: dataAge,
            cliInstalled: cliInstalled,
            state: state ?? stateWithExpiredWindow(),
            now: now ?? self.now
        )
    }

    private func skipReason(_ input: SessionOpener.Input) -> SessionOpenerDecision.SkipReason? {
        SessionOpener.decide(input).skipReason
    }

    // MARK: - The happy path

    @Test("Opens once the window has expired and the delay has passed")
    func opensAfterExpiry() throws {
        let decision = SessionOpener.decide(input())
        let cycleID = try #require(decision.cycleID)
        #expect(cycleID == SessionOpener.cycleID(expiredResetAt: expiredResetAt))
    }

    // MARK: - Guards

    @Test("Off by default, and disabled means disabled")
    func disabledByDefault() {
        #expect(!SessionOpenerSettings().enabled)
        #expect(skipReason(input(settings: settings(enabled: false))) == .disabled)
    }

    @Test("Refuses without the CLI")
    func requiresCLI() {
        #expect(skipReason(input(cliInstalled: false)) == .cliNotInstalled)
    }

    @Test("Refuses on stale data, because the spending guards cannot be checked")
    func refusesOnStaleData() {
        #expect(skipReason(input(isStale: true)) == .dataStale)
    }

    /// The whole point of the "no grace period" design: stale data delays the
    /// opener, it does not cancel it. The same cycle must still open once a
    /// good reading lands.
    @Test("A cycle skipped for staleness still opens when data comes back")
    func stalenessPostponesRatherThanCancels() {
        let state = stateWithExpiredWindow()
        #expect(skipReason(input(isStale: true, state: state)) == .dataStale)

        // Hours later, with fresh data, the same cycle is still eligible.
        let later = now.addingTimeInterval(4 * 3600)
        let decision = SessionOpener.decide(input(isStale: false, state: state, now: later))
        #expect(decision.cycleID == SessionOpener.cycleID(expiredResetAt: expiredResetAt))
    }

    /// The deadlock this exists to break: the staleness is an access token only
    /// a Claude Code run can renew, and the opener is a Claude Code run. Refusing
    /// would leave the user to fix it from a terminal by hand.
    @Test("Opens on a stale reading when the token is merely awaiting renewal")
    func opensThroughTokenRenewalStaleness() {
        let decision = SessionOpener.decide(input(
            isStale: true, awaitingTokenRenewal: true, dataAge: 3600
        ))
        #expect(decision.cycleID == SessionOpener.cycleID(expiredResetAt: expiredResetAt))
    }

    @Test("A reading too old to bound the weekly figure blocks even so")
    func staleTokenRenewalIsAgeBounded() {
        let tooOld = SessionOpener.maxStaleAgeAwaitingTokenRenewal + 1
        #expect(skipReason(input(
            isStale: true, awaitingTokenRenewal: true, dataAge: tooOld
        )) == .dataStale)
        // Exactly at the bound is still allowed.
        #expect(SessionOpener.decide(input(
            isStale: true,
            awaitingTokenRenewal: true,
            dataAge: SessionOpener.maxStaleAgeAwaitingTokenRenewal
        )).cycleID != nil)
    }

    /// Only the staleness check is relaxed. Everything that protects the user's
    /// money still runs, against the last good reading.
    @Test("Acting on a stale reading still applies every spending guard")
    func staleOpeningStillRespectsSpendingGuards() {
        func reason(_ spoil: (inout SessionOpener.Input) -> Void) -> SessionOpenerDecision.SkipReason? {
            var input = input(isStale: true, awaitingTokenRenewal: true, dataAge: 3600)
            spoil(&input)
            return SessionOpener.decide(input).skipReason
        }

        #expect(reason { $0.extraUsageEnabled = true } == .extraUsageEnabled)
        #expect(reason { $0.extraUsageEnabled = nil } == .extraUsageUnknown)
        #expect(reason { $0.weeklyWindow = self.weekly(remaining: 5) } == .weeklyQuotaLow)
        #expect(reason { $0.weeklyWindow = nil } == .weeklyQuotaUnknown)
        #expect(reason { $0.sessionWindow = self.activeSession() } == .windowAlreadyActive)
    }

    @Test("Any other cause of staleness still blocks")
    func otherStalenessStillBlocks() {
        #expect(skipReason(input(isStale: true, awaitingTokenRenewal: false, dataAge: 60))
            == .dataStale)
    }

    @Test("Stays silent while a window is already running")
    func skipsWhileWindowActive() {
        #expect(skipReason(input(session: activeSession())) == .windowAlreadyActive)
        // Also once the reading has gone stale — the frozen snapshot is no
        // longer evidence a window is live, so this must not be the answer.
        #expect(skipReason(input(session: activeSession(), isStale: true)) != .windowAlreadyActive)
    }

    @Test("Nothing to open before any window has been seen to end")
    func skipsWithNoExpiredWindow() {
        #expect(skipReason(input(state: SessionOpenerState())) == .noExpiredWindow)
    }

    /// The bug behind a forced refresh being spent 94 minutes before its cycle
    /// was due: a live window's reset time is in the *future*, and reporting
    /// that as `dataStale` made the coordinator burn the cycle's one allowance
    /// on it. A window that has not ended has nothing to wait for.
    @Test("A window still running is not a cycle waiting on fresh data")
    func liveWindowIsNotStale() {
        var state = SessionOpenerState()
        state.lastKnownSessionResetAt = now.addingTimeInterval(3600)

        #expect(skipReason(input(session: activeSession(), isStale: true, state: state))
            == .noExpiredWindow)
        #expect(skipReason(input(session: activeSession(), state: state))
            == .windowAlreadyActive)
    }

    @Test("Waits out the configured delay")
    func waitsForDelay() {
        // 30s after the reset, with a 60s delay configured.
        let tooEarly = expiredResetAt.addingTimeInterval(30)
        #expect(skipReason(input(now: tooEarly)) == .delayNotElapsed)

        let justRight = expiredResetAt.addingTimeInterval(61)
        #expect(SessionOpener.decide(input(now: justRight)).cycleID != nil)
    }

    @Test("Refuses when the weekly quota is low or unknown")
    func weeklyQuotaGuards() {
        #expect(skipReason(input(weeklyRemaining: 5)) == .weeklyQuotaLow)
        #expect(skipReason(input(weeklyRemaining: nil)) == .weeklyQuotaUnknown)
        // Exactly at the threshold is allowed, matching the reminder rule.
        #expect(SessionOpener.decide(input(weeklyRemaining: 10)).cycleID != nil)
    }

    /// The plan-wide weekly figure is not the whole story: a model with its own
    /// weekly allowance can be spent out while the shared week still looks
    /// healthy, and running past that allowance is billable just the same.
    @Test("Checks the weekly allowance of the model the opener will actually run")
    func modelWeeklyQuotaGuard() {
        var sonnet = settings()
        sonnet.model = "sonnet"

        // Plan-wide weekly is fine; Sonnet's own week is not.
        #expect(skipReason(input(
            settings: sonnet,
            weeklyRemaining: 80,
            modelWeeklyWindows: [modelWeekly("sonnet", remaining: 4)]
        )) == .modelWeeklyQuotaLow)

        // Above the threshold, it runs.
        #expect(SessionOpener.decide(input(
            settings: sonnet,
            modelWeeklyWindows: [modelWeekly("sonnet", remaining: 40)]
        )).cycleID != nil)

        // Another model's exhausted week is none of this run's business.
        #expect(SessionOpener.decide(input(
            settings: sonnet,
            modelWeeklyWindows: [modelWeekly("opus", remaining: 0), modelWeekly("sonnet", remaining: 40)]
        )).cycleID != nil)

        // Haiku has no weekly allowance of its own. Absence is not "unknown" —
        // treating it as a refusal would block the default configuration.
        #expect(SessionOpener.decide(input(
            modelWeeklyWindows: [modelWeekly("opus", remaining: 0)]
        )).cycleID != nil)
    }

    @Test("Resolves the model window by the id the provider builds")
    func modelWeeklyWindowLookup() {
        let windows = [modelWeekly("opus", remaining: 50), modelWeekly("sonnet", remaining: 20)]
        #expect(SessionOpener.modelWeeklyWindow(for: "sonnet", in: windows)?.id == "claude.weekly.sonnet")
        #expect(SessionOpener.modelWeeklyWindow(for: "Sonnet", in: windows)?.id == "claude.weekly.sonnet")
        #expect(SessionOpener.modelWeeklyWindow(for: "haiku", in: windows) == nil)
        #expect(SessionOpener.modelWeeklyWindow(for: "sonnet", in: []) == nil)
    }

    /// The model picker can now hold a pinned id as well as an alias, while the
    /// provider still builds window ids from the alias. A literal match would
    /// miss — silently, because absence is read as "no separate allowance", so
    /// the guard would go dark rather than fail loudly.
    @Test("A pinned model id still finds its family's weekly window")
    func pinnedModelIDResolvesToFamily() {
        let windows = [modelWeekly("opus", remaining: 50), modelWeekly("sonnet", remaining: 20)]

        #expect(SessionOpener.modelWeeklyWindow(for: "claude-opus-5", in: windows)?.id == "claude.weekly.opus")
        #expect(
            SessionOpener.modelWeeklyWindow(for: "claude-sonnet-4-5-20250929", in: windows)?.id
                == "claude.weekly.sonnet"
        )
        #expect(SessionOpener.modelWeeklyWindow(for: "Claude-Opus-5", in: windows)?.id == "claude.weekly.opus")

        #expect(SessionOpener.modelFamily("claude-opus-5") == "opus")
        #expect(SessionOpener.modelFamily("opus") == "opus")
        // An id from no known family is passed through rather than guessed at.
        #expect(SessionOpener.modelFamily("some-future-model") == "some-future-model")
    }

    /// Extra usage only bills *past* the plan allowance, and the opener only
    /// runs into a freshly reset window with the weekly figure above the
    /// threshold — so the blanket refusal is off by default now.
    @Test("The extra-usage refusal is opt-in, not the default")
    func extraUsageSkipIsOptIn() {
        #expect(!SessionOpenerSettings().skipWhenExtraUsageEnabled)
        #expect(SessionOpener.decide(input(
            settings: settings(skipWhenExtraUsage: false),
            extraUsageEnabled: true
        )).cycleID != nil)
    }

    @Test("Refuses when extra paid usage is on, or unreported")
    func extraUsageGuards() {
        #expect(skipReason(input(extraUsageEnabled: true)) == .extraUsageEnabled)
        // Silence is not consent.
        #expect(skipReason(input(extraUsageEnabled: nil)) == .extraUsageUnknown)
        // …but the toggle is the way out of an endpoint that never reports it.
        #expect(SessionOpener.decide(input(
            settings: settings(skipWhenExtraUsage: false),
            extraUsageEnabled: nil
        )).cycleID != nil)
    }

    @Test("Respects quiet hours only while the setting is on")
    func quietHoursGuard() {
        // `now` is 1_785_500_000; use a window that certainly contains it by
        // covering the whole day.
        let allDay = QuietHours(enabled: true, startMinutes: 0, endMinutes: 24 * 60 - 1)
        #expect(skipReason(input(quietHours: allDay)) == .quietHours)
        #expect(SessionOpener.decide(input(
            settings: settings(respectQuietHours: false),
            quietHours: allDay
        )).cycleID != nil)
    }

    // MARK: - Cycle identity and dedup

    @Test("Cycle id absorbs the endpoint's reset-time jitter")
    func cycleIDIsStableUnderJitter() {
        let a = SessionOpener.cycleID(expiredResetAt: expiredResetAt)
        let b = SessionOpener.cycleID(expiredResetAt: expiredResetAt.addingTimeInterval(1))
        let c = SessionOpener.cycleID(expiredResetAt: expiredResetAt.addingTimeInterval(-1))
        #expect(a == b)
        #expect(a == c)
    }

    @Test("Different cycles get different ids")
    func cycleIDDistinguishesWindows() {
        let a = SessionOpener.cycleID(expiredResetAt: expiredResetAt)
        let b = SessionOpener.cycleID(expiredResetAt: expiredResetAt.addingTimeInterval(5 * 3600))
        #expect(a != b)
    }

    /// The guarantee that matters most: a relaunch mid-cycle must not send a
    /// second opener.
    @Test("A cycle that already reached Claude is never opened again")
    func neverOpensASettledCycleTwice() {
        var state = stateWithExpiredWindow()
        let cycle = SessionOpener.cycleID(expiredResetAt: expiredResetAt)
        state.record(SessionOpenerAttempt(
            cycleID: cycle, startedAt: now, outcome: .sent, model: "haiku"
        ))

        // Reloading from disk is what a relaunch does.
        let reloaded = try! JSONStore.makeDecoder().decode(
            SessionOpenerState.self,
            from: JSONStore.makeEncoder().encode(state)
        )
        #expect(skipReason(input(state: reloaded, now: now.addingTimeInterval(3600)))
            == .alreadyOpenedThisCycle)
    }

    @Test("An unverified opener also settles the cycle")
    func unverifiedStillSettles() {
        var state = stateWithExpiredWindow()
        state.record(SessionOpenerAttempt(
            cycleID: SessionOpener.cycleID(expiredResetAt: expiredResetAt),
            startedAt: now, outcome: .unverified, model: "haiku"
        ))
        #expect(skipReason(input(state: state, now: now.addingTimeInterval(3600)))
            == .alreadyOpenedThisCycle)
    }

    /// A failed run spent nothing, so a transient blip must not burn the cycle —
    /// but it must not retry forever either.
    @Test("A failed run retries, spaced out, up to a bounded count")
    func failedRunsRetryButAreBounded() {
        var state = stateWithExpiredWindow()
        let cycle = SessionOpener.cycleID(expiredResetAt: expiredResetAt)

        state.record(SessionOpenerAttempt(
            cycleID: cycle, startedAt: now, outcome: .failed, model: "haiku"
        ))
        // Immediately after, it holds off.
        #expect(skipReason(input(state: state, now: now.addingTimeInterval(60))) == .retryTooSoon)
        // After the retry interval, it tries again.
        let afterInterval = now.addingTimeInterval(SessionOpener.retryInterval + 1)
        #expect(SessionOpener.decide(input(state: state, now: afterInterval)).cycleID != nil)

        for index in 1 ..< SessionOpener.maxAttemptsPerCycle {
            state.record(SessionOpenerAttempt(
                cycleID: cycle,
                startedAt: now.addingTimeInterval(Double(index) * 600),
                outcome: .failed,
                model: "haiku"
            ))
        }
        let muchLater = now.addingTimeInterval(86400)
        #expect(skipReason(input(state: state, now: muchLater)) == .attemptsExhausted)
    }

    // MARK: - Gates

    @Test("Only a first-party Claude subscription passes the auth gate")
    func authGate() {
        let good = ClaudeAuthStatus(
            loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "pro"
        )
        #expect(SessionOpener.authGate(good) == nil)

        #expect(SessionOpener.authGate(nil) == .notSubscriptionAuth)
        #expect(SessionOpener.authGate(ClaudeAuthStatus(
            loggedIn: false, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "pro"
        )) == .notSubscriptionAuth)
        #expect(SessionOpener.authGate(ClaudeAuthStatus(
            loggedIn: true, authMethod: "apiKey", apiProvider: "firstParty", subscriptionType: nil
        )) == .notSubscriptionAuth)
        #expect(SessionOpener.authGate(ClaudeAuthStatus(
            loggedIn: true, authMethod: "claude.ai", apiProvider: "bedrock", subscriptionType: "pro"
        )) == .notSubscriptionAuth)
        // A missing field is unknown, and unknown is unsafe.
        #expect(SessionOpener.authGate(ClaudeAuthStatus(
            loggedIn: true, authMethod: nil, apiProvider: nil, subscriptionType: nil
        )) == .notSubscriptionAuth)
    }

    /// `claude auth status` reports the stored login regardless of a configured
    /// API key, so this gate is the one that actually catches billed usage.
    @Test("An API key in the Claude settings file blocks the opener")
    func settingsGate() {
        func gate(_ json: String) -> SessionOpenerDecision.SkipReason? {
            SessionOpener.settingsGate(Data(json.utf8))
        }

        #expect(gate(#"{"permissions": {"allow": []}}"#) == nil)
        #expect(gate(#"{"apiKeyHelper": "/usr/local/bin/get-key"}"#) == .apiKeyConfigured)
        #expect(gate(#"{"env": {"ANTHROPIC_API_KEY": "sk-ant-xyz"}}"#) == .apiKeyConfigured)
        #expect(gate(#"{"env": {"ANTHROPIC_AUTH_TOKEN": "tok"}}"#) == .apiKeyConfigured)

        // Empty values are not a configured key.
        #expect(gate(#"{"apiKeyHelper": ""}"#) == nil)
        #expect(gate(#"{"env": {"ANTHROPIC_API_KEY": ""}}"#) == nil)

        // An absent or hand-mangled settings file is not evidence of a key.
        #expect(SessionOpener.settingsGate(nil) == nil)
        #expect(gate("not json at all") == nil)
    }

    // MARK: - Verification

    @Test("A window only counts as opened when the reset time moves past the run")
    func verification() {
        let sentAt = now

        #expect(!SessionOpener.didWindowOpen(sessionWindow: idleSession(), sentAt: sentAt))
        #expect(!SessionOpener.didWindowOpen(sessionWindow: nil, sentAt: sentAt))

        // A cached pre-opener reading carries the *old* window's reset time and
        // must not verify a run that did nothing.
        var stale = activeSession()
        stale.resetAt = sentAt.addingTimeInterval(-60)
        #expect(!SessionOpener.didWindowOpen(sessionWindow: stale, sentAt: sentAt))

        #expect(SessionOpener.didWindowOpen(sessionWindow: activeSession(), sentAt: sentAt))
    }

    // MARK: - Runner

    @Test("The opener command disables every tool and loads no settings")
    func runnerArguments() {
        let arguments = ClaudeOpenerRunner.arguments(model: "haiku")

        // "--tools" followed by an empty string is what disables the built-ins.
        let toolsIndex = try! #require(arguments.firstIndex(of: "--tools"))
        #expect(arguments[toolsIndex + 1] == "")

        let sourcesIndex = try! #require(arguments.firstIndex(of: "--setting-sources"))
        #expect(arguments[sourcesIndex + 1] == "")

        // No effort passed, so no flag — the opener must invoke the CLI exactly
        // as it did before the setting existed unless asked otherwise.
        #expect(!arguments.contains("--effort"))

        let withEffort = ClaudeOpenerRunner.arguments(model: "haiku", effort: "low")
        let effortIndex = try! #require(withEffort.firstIndex(of: "--effort"))
        #expect(withEffort[effortIndex + 1] == "low")
        // Still the last positional argument.
        #expect(withEffort.last == arguments.last)

        #expect(arguments.contains("--print"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("haiku"))
        #expect(arguments.last == ClaudeOpenerRunner.prompt)

        // --bare would force API-key auth and bypass the subscription entirely.
        #expect(!arguments.contains("--bare"))
    }

    @Test("The child environment cannot inherit API credentials")
    func runnerEnvironmentIsScrubbed() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "ANTHROPIC_API_KEY": "sk-ant-leak",
            "ANTHROPIC_AUTH_TOKEN": "tok",
            "ANTHROPIC_BASE_URL": "https://example.com",
            "CLAUDE_CODE_USE_BEDROCK": "1",
        ]
        let child = ClaudeOpenerRunner.environment(from: parent)

        #expect(child["PATH"] == "/usr/bin")
        #expect(child["HOME"] == "/Users/test")
        #expect(child["ANTHROPIC_API_KEY"] == nil)
        #expect(child["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(child["ANTHROPIC_BASE_URL"] == nil)
        #expect(child["CLAUDE_CODE_USE_BEDROCK"] == nil)
    }

    @Test("A child with no PATH still gets one")
    func runnerEnvironmentAlwaysHasPath() {
        let child = ClaudeOpenerRunner.environment(from: [:])
        #expect(child["PATH"]?.isEmpty == false)
    }

    @Test("Reads the CLI result envelope, and treats anything unreadable as failure")
    func runnerParsing() {
        let ok = ClaudeOpenerRunner.parse(stdout: #"""
        {"type":"result","subtype":"success","is_error":false,"result":"OK",
         "session_id":"abc-123","total_cost_usd":0.0004,"num_turns":1}
        """#)
        #expect(ok.succeeded)
        #expect(ok.text == "OK")
        #expect(ok.sessionID == "abc-123")
        #expect(ok.costUSD == 0.0004)

        let errored = ClaudeOpenerRunner.parse(stdout: #"{"is_error":true,"result":"rate limited"}"#)
        #expect(!errored.succeeded)
        #expect(errored.errorMessage == "rate limited")

        for junk in ["", "not json", "{}"] {
            let result = ClaudeOpenerRunner.parse(stdout: junk)
            if junk == "{}" {
                // No `is_error` means the run did not report a failure.
                #expect(result.succeeded)
            } else {
                #expect(!result.succeeded)
                #expect(result.errorMessage != nil)
            }
        }
    }

    // MARK: - State bookkeeping

    @Test("State keeps only the most recent attempts")
    func stateIsBounded() {
        var state = SessionOpenerState()
        for index in 0 ..< 60 {
            state.record(SessionOpenerAttempt(
                cycleID: "opener-\(index)",
                startedAt: now.addingTimeInterval(Double(index)),
                outcome: .verified,
                model: "haiku"
            ))
        }
        #expect(state.attempts.count == 40)
        #expect(state.attempts.last?.cycleID == "opener-59")
    }

    @Test("The forced stale refresh is requested at most once per cycle")
    func forcedRefreshIsOncePerCycle() {
        var state = SessionOpenerState()
        let cycle = "opener-x"
        #expect(!state.hasForcedRefresh(cycle))
        state.markForcedRefresh(cycle)
        state.markForcedRefresh(cycle)
        state.markForcedRefresh(cycle)
        #expect(state.hasForcedRefresh(cycle))
        #expect(state.forcedRefreshCycleIDs.filter { $0 == cycle }.count == 1)
    }

    @Test("Recording the same attempt twice updates it rather than duplicating")
    func recordIsIdempotentPerAttempt() {
        var state = SessionOpenerState()
        var attempt = SessionOpenerAttempt(
            cycleID: "opener-x", startedAt: now, outcome: .failed, model: "haiku"
        )
        state.record(attempt)
        attempt.outcome = .verified
        state.record(attempt)

        #expect(state.attempts.count == 1)
        #expect(state.attempts.first?.outcome == .verified)
        #expect(state.isSettled("opener-x"))
    }

    @Test("Every skip reason explains itself")
    func everyReasonHasCopy() {
        for reason in SessionOpenerDecision.SkipReason.allCases {
            #expect(!reason.explanation.isEmpty)
        }
    }
}
