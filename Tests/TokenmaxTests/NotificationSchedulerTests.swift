import Foundation
import Testing

@testable import Tokenmax

@Suite("Notification scheduling decisions")
struct NotificationSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func window(
        remaining: Double,
        resetInMinutes: Double?,
        kind: UsageWindowKind = .session
    ) -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: kind,
            label: "Session",
            usedPercent: 100 - remaining,
            resetAt: resetInMinutes.map { now.addingTimeInterval($0 * 60) },
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func input(
        remaining: Double = 41,
        resetInMinutes: Double? = 60,
        rule: ReminderRule = .sessionDefault,
        remindersEnabled: Bool = true,
        quietHours: QuietHours = QuietHours(),
        isStale: Bool = false,
        queuedTaskCount: Int = 6,
        queueEnabled: Bool = true,
        alreadyFired: Bool = false
    ) -> NotificationScheduler.Input {
        .init(
            window: window(remaining: remaining, resetInMinutes: resetInMinutes),
            rule: rule,
            remindersEnabled: remindersEnabled,
            quietHours: quietHours,
            isStale: isStale,
            queuedTaskCount: queuedTaskCount,
            queueEnabled: queueEnabled,
            alreadyFired: alreadyFired,
            now: now
        )
    }

    // MARK: - Happy path

    @Test("Schedules at reset minus lead time")
    func schedulesAtLeadTime() throws {
        let decision = NotificationScheduler.decide(input())

        guard case let .schedule(_, fireDate, _, body) = decision else {
            Issue.record("expected schedule, got \(decision)")
            return
        }
        // Reset in 60 min, 30 min lead -> fires in 30 min.
        #expect(fireDate == now.addingTimeInterval(30 * 60))
        #expect(body.contains("41%"))
        #expect(body.contains("6 tasks are queued"))
    }

    @Test("Identifier is stable across repeated refreshes")
    func identifierIsStable() {
        let first = NotificationScheduler.decide(input())
        let second = NotificationScheduler.decide(input())

        guard case let .schedule(id1, _, _, _) = first,
              case let .schedule(id2, _, _, _) = second
        else {
            Issue.record("expected both to schedule")
            return
        }
        // This stability is what prevents duplicate banners after every refresh.
        #expect(id1 == id2)
    }

    /// Regression: the live endpoint returned 09:00:00Z on one fetch and
    /// 08:59:59Z on the next for the same window. An identifier that tracked
    /// the raw second would miss the already-fired lookup and deliver a second
    /// banner for a window that had already been announced.
    @Test("Second-level drift in resets_at does not change the identifier")
    func identifierAbsorbsResetDrift() {
        let onTheHour = Date(timeIntervalSince1970: 1_785_484_800) // 09:00:00Z
        let oneSecondEarly = onTheHour.addingTimeInterval(-1) // 08:59:59Z

        #expect(
            NotificationScheduler.identifier(for: .session, resetAt: onTheHour)
                == NotificationScheduler.identifier(for: .session, resetAt: oneSecondEarly)
        )
    }

    @Test("Drift up to the bucket edge still collapses to one identifier")
    func identifierAbsorbsLargerDrift() {
        let base = Date(timeIntervalSince1970: 1_785_484_800)
        let identifiers = Set(
            [-120.0, -30, -1, 0, 1, 30, 120].map {
                NotificationScheduler.identifier(for: .session, resetAt: base.addingTimeInterval($0))
            }
        )

        #expect(identifiers.count == 1)
    }

    @Test("Genuinely different windows still get different identifiers")
    func identifierSeparatesRealWindows() {
        let base = Date(timeIntervalSince1970: 1_785_484_800)
        // Consecutive five-hour windows must never collide.
        #expect(
            NotificationScheduler.identifier(for: .session, resetAt: base)
                != NotificationScheduler.identifier(for: .session, resetAt: base.addingTimeInterval(5 * 3600))
        )
    }

    @Test("Session and weekly windows never share an identifier")
    func identifierSeparatesKinds() {
        let base = Date(timeIntervalSince1970: 1_785_484_800)
        #expect(
            NotificationScheduler.identifier(for: .session, resetAt: base)
                != NotificationScheduler.identifier(for: .weekly, resetAt: base)
        )
    }

    @Test("Providers never share a reminder identity")
    func identifierSeparatesProviders() {
        let reset = Date(timeIntervalSince1970: 1_785_484_800)
        #expect(
            NotificationScheduler.identifier(for: .session, resetAt: reset, providerID: TokenmaxProvider.claudeCode.rawValue)
                != NotificationScheduler.identifier(for: .session, resetAt: reset, providerID: TokenmaxProvider.codex.rawValue)
        )
    }

    /// Delivery callbacks arrive later than scheduling and must recover the
    /// exact provider rule whose fingerprint keeps once-per-window reliable.
    @Test("Delivery metadata resolves every provider window independently")
    func resolvesDeliveredReminderSource() {
        #expect(
            ReminderRuleSourceResolver.resolve(
                identifier: "ignored", providerID: "codex", windowKind: "session"
            ) == ReminderRuleSource(provider: .codex, kind: .session)
        )
        #expect(
            ReminderRuleSourceResolver.resolve(
                identifier: "ignored", providerID: "claude-code", windowKind: "weekly"
            ) == ReminderRuleSource(provider: .claudeCode, kind: .weekly)
        )
    }

    @Test("Older delivered reminders resolve from their identifier")
    func resolvesLegacyReminderSource() {
        let source = ReminderRuleSourceResolver.resolve(
            identifier: "codex-weekly-2026-08-31T12:00:00Z-snooze-1",
            providerID: nil,
            windowKind: nil
        )

        #expect(source == ReminderRuleSource(provider: .codex, kind: .weekly))
    }

    @Test("Drift changes the identity but not the scheduled fire time")
    func driftDoesNotShiftFireTime() {
        guard case let .schedule(id1, fire1, _, _) = NotificationScheduler.decide(input(resetInMinutes: 60)),
              case let .schedule(id2, fire2, _, _) = NotificationScheduler.decide(
                  input(resetInMinutes: 60 - 1.0 / 60) // one second earlier
              )
        else {
            Issue.record("expected both to schedule")
            return
        }

        #expect(id1 == id2)
        // Bucketing is for identity only; the fire time still tracks the exact
        // reset the provider reported.
        #expect(fire1 != fire2)
        #expect(abs(fire1.timeIntervalSince(fire2)) == 1)
    }

    /// Regression: dedup used to key on identity alone, which pinned the
    /// original fire time — changing the lead time in Settings silently had no
    /// effect until the window rolled.
    @Test("A changed lead time reschedules the pending request")
    func reschedulesOnLeadTimeChange() {
        let scheduled = Date(timeIntervalSince1970: 1_785_484_800)

        #expect(NotificationScheduler.shouldReschedule(from: scheduled, to: scheduled.addingTimeInterval(-900)))
        #expect(NotificationScheduler.shouldReschedule(from: scheduled, to: scheduled.addingTimeInterval(1800)))
    }

    /// Regression: a banner scheduled an hour ahead announced "28% remains"
    /// while the menubar read 10%. Notification content is immutable once
    /// scheduled, so the pending request has to be re-issued as the figure moves.
    @Test("A changed quota figure re-issues the pending request")
    func refreshesStaleBody() {
        let fire = Date().addingTimeInterval(3600)

        #expect(
            NotificationScheduler.pendingUpdate(
                scheduledFireDate: fire,
                scheduledBody: "Your five-hour window resets in 15m. Approximately 28% remains and 2 tasks are queued.",
                desiredFireDate: fire,
                desiredBody: "Your five-hour window resets in 15m. Approximately 10% remains and 2 tasks are queued.",
                now: Date()
            ) == .replace
        )
    }

    @Test("An unchanged body leaves the pending request alone")
    func keepsUnchangedBody() {
        let fire = Date().addingTimeInterval(3600)
        let body = "Your five-hour window resets in 15m. Approximately 28% remains and 2 tasks are queued."

        #expect(
            NotificationScheduler.pendingUpdate(
                scheduledFireDate: fire,
                scheduledBody: body,
                desiredFireDate: fire,
                desiredBody: body,
                now: Date()
            ) == .keep
        )
    }

    @Test("A reminder about to fire is never torn down mid-flight")
    func doesNotTouchImminentRequest() {
        let now = Date()
        // Inside the blackout: a remove/re-add here risks losing it entirely.
        #expect(
            NotificationScheduler.pendingUpdate(
                scheduledFireDate: now.addingTimeInterval(20),
                scheduledBody: "old body",
                desiredFireDate: now.addingTimeInterval(20),
                desiredBody: "new body",
                now: now
            ) == .keep
        )
    }

    @Test("A queued-task count change re-issues the pending request")
    func refreshesTaskCount() {
        let fire = Date().addingTimeInterval(3600)

        #expect(
            NotificationScheduler.pendingUpdate(
                scheduledFireDate: fire,
                scheduledBody: NotificationScheduler.body(
                    kind: .session, timeUntilReset: 900, remainingPercent: 28, queuedTaskCount: 2
                ),
                desiredFireDate: fire,
                desiredBody: NotificationScheduler.body(
                    kind: .session, timeUntilReset: 900, remainingPercent: 28, queuedTaskCount: 5
                ),
                now: Date()
            ) == .replace
        )
    }

    @Test("Endpoint jitter alone does not tear down a pending request")
    func doesNotRescheduleOnJitter() {
        let scheduled = Date(timeIntervalSince1970: 1_785_484_800)

        #expect(!NotificationScheduler.shouldReschedule(from: scheduled, to: scheduled))
        #expect(!NotificationScheduler.shouldReschedule(from: scheduled, to: scheduled.addingTimeInterval(-1)))
    }

    @Test("A different reset time produces a different identifier")
    func identifierTracksResetTime() {
        guard case let .schedule(id1, _, _, _) = NotificationScheduler.decide(input(resetInMinutes: 60)),
              case let .schedule(id2, _, _, _) = NotificationScheduler.decide(input(resetInMinutes: 120))
        else {
            Issue.record("expected both to schedule")
            return
        }
        #expect(id1 != id2)
    }

    // MARK: - Suppression guards

    @Test("Skips when reminders are globally disabled")
    func skipsWhenRemindersDisabled() {
        #expect(NotificationScheduler.decide(input(remindersEnabled: false)) == .skip(reason: .remindersDisabled))
    }

    @Test("Skips when this window's rule is off")
    func skipsWhenRuleDisabled() {
        var rule = ReminderRule.sessionDefault
        rule.enabled = false
        #expect(NotificationScheduler.decide(input(rule: rule)) == .skip(reason: .ruleDisabled))
    }

    @Test("Never schedules off stale data")
    func skipsWhenStale() {
        #expect(NotificationScheduler.decide(input(isStale: true)) == .skip(reason: .dataStale))
    }

    @Test("Skips when the provider gave no reset time")
    func skipsWithoutResetTime() {
        #expect(NotificationScheduler.decide(input(resetInMinutes: nil)) == .skip(reason: .noResetTime))
    }

    /// Regression: this is what made the app look broken. Configuring "remind
    /// me an hour before reset" while 58 minutes remain used to skip silently.
    /// There is still nearly an hour of usable quota, so the reminder is due
    /// now, not never.
    @Test("Delivers immediately when already inside the lead window")
    func deliversWhenAlreadyInsideLeadWindow() {
        var rule = ReminderRule.sessionDefault
        rule.leadTimeMinutes = 60

        let decision = NotificationScheduler.decide(input(resetInMinutes: 58, rule: rule))

        guard case let .deliverNow(_, _, body) = decision else {
            Issue.record("expected immediate delivery, got \(decision)")
            return
        }
        // The body must describe the real remaining time, not the configured lead.
        #expect(body.contains("58m"))
    }

    @Test("Immediate delivery still respects once-per-window")
    func immediateDeliveryIsOncePerWindow() {
        var rule = ReminderRule.sessionDefault
        rule.leadTimeMinutes = 60
        // Even with the setting off, an immediate send must not repeat on every
        // refresh — there is no pending request to dedup against.
        rule.notifyOncePerWindow = false

        #expect(
            NotificationScheduler.decide(input(resetInMinutes: 58, rule: rule, alreadyFired: true))
                == .skip(reason: .alreadyFiredForWindow)
        )
    }

    @Test("Does not nag when the reset is too close to be useful")
    func skipsWhenResetImminent() {
        var rule = ReminderRule.sessionDefault
        rule.leadTimeMinutes = 60

        // Under five minutes left: there is no time to spend the quota.
        #expect(
            NotificationScheduler.decide(input(resetInMinutes: 3, rule: rule))
                == .skip(reason: .resetTooSoon)
        )
    }

    @Test("Skips when too little quota remains to be worth warning about")
    func skipsWhenQuotaTooLow() {
        #expect(NotificationScheduler.decide(input(remaining: 5)) == .skip(reason: .notEnoughQuotaLeft))
    }

    @Test("Skips an empty queue when the rule requires queued tasks")
    func skipsEmptyQueue() {
        #expect(NotificationScheduler.decide(input(queuedTaskCount: 0)) == .skip(reason: .queueEmpty))
    }

    @Test("Still notifies on an empty queue when the rule allows it")
    func allowsEmptyQueueWhenConfigured() {
        var rule = ReminderRule.sessionDefault
        rule.onlyWhenTasksQueued = false

        let decision = NotificationScheduler.decide(input(rule: rule, queuedTaskCount: 0))
        guard case let .schedule(_, _, _, body) = decision else {
            Issue.record("expected schedule, got \(decision)")
            return
        }
        #expect(body.contains("no tasks are queued"))
    }

    /// The queue-empty guard would otherwise suppress every reminder forever
    /// once the queue is switched off — the user has no way left to queue
    /// anything, so the rule they set while the feature existed must not
    /// silently take their reminders with it.
    @Test("A disabled queue ignores the queued-tasks requirement")
    func disabledQueueIgnoresQueueRequirement() {
        var rule = ReminderRule.sessionDefault
        rule.onlyWhenTasksQueued = true

        let decision = NotificationScheduler.decide(
            input(rule: rule, queuedTaskCount: 0, queueEnabled: false)
        )
        guard case .schedule = decision else {
            Issue.record("expected schedule, got \(decision)")
            return
        }
    }

    @Test("A disabled queue drops the task phrase from the banner")
    func disabledQueueOmitsTaskPhrase() {
        let decision = NotificationScheduler.decide(input(queueEnabled: false))

        guard case let .schedule(_, _, _, body) = decision else {
            Issue.record("expected schedule, got \(decision)")
            return
        }
        #expect(body.contains("41%"))
        #expect(!body.contains("queued"))
    }

    @Test("Fires only once per window when configured")
    func skipsWhenAlreadyFired() {
        #expect(NotificationScheduler.decide(input(alreadyFired: true)) == .skip(reason: .alreadyFiredForWindow))
    }

    @Test("Re-notifies for the same window when once-per-window is off")
    func allowsRepeatWhenConfigured() {
        var rule = ReminderRule.sessionDefault
        rule.notifyOncePerWindow = false

        let decision = NotificationScheduler.decide(input(rule: rule, alreadyFired: true))
        guard case .schedule = decision else {
            Issue.record("expected schedule, got \(decision)")
            return
        }
    }

    @Test("Suppresses reminders landing inside quiet hours")
    func skipsDuringQuietHours() {
        // Make quiet hours cover the whole day so the fire time must land inside.
        let quiet = QuietHours(enabled: true, startMinutes: 0, endMinutes: 24 * 60 - 1)
        #expect(NotificationScheduler.decide(input(quietHours: quiet)) == .skip(reason: .quietHours))
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {
    private func date(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    @Test("Disabled quiet hours never match")
    func disabledNeverMatches() {
        let quiet = QuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60)
        #expect(!quiet.contains(date(hour: 23)))
    }

    @Test("Handles a window that wraps past midnight")
    func handlesOvernightWindow() {
        let quiet = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)

        #expect(quiet.contains(date(hour: 23)))
        #expect(quiet.contains(date(hour: 3)))
        #expect(!quiet.contains(date(hour: 12)))
        #expect(!quiet.contains(date(hour: 21)))
    }

    @Test("Handles a same-day window")
    func handlesDaytimeWindow() {
        let quiet = QuietHours(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60)

        #expect(quiet.contains(date(hour: 12)))
        #expect(!quiet.contains(date(hour: 8)))
        #expect(!quiet.contains(date(hour: 18)))
    }
}

@Suite("Notification state")
struct NotificationStateTests {
    private let fingerprint = ReminderRule.sessionDefault.fingerprint

    @Test("Fired identifiers are recorded once and survive re-marking")
    func recordsFiredOnce() {
        var state = NotificationState()
        state.markFired("claude-session-2026-07-31T09:30:00Z", fingerprint: fingerprint)
        state.markFired("claude-session-2026-07-31T09:30:00Z", fingerprint: fingerprint)

        #expect(state.fired.count == 1)
        #expect(state.hasFired("claude-session-2026-07-31T09:30:00Z", fingerprint: fingerprint))
    }

    @Test("Old identifiers are trimmed so the file cannot grow forever")
    func trimsHistory() {
        var state = NotificationState()
        for index in 0 ..< 260 {
            state.markFired("id-\(index)", fingerprint: fingerprint)
        }

        #expect(state.fired.count == 200)
        #expect(!state.hasFired("id-0", fingerprint: fingerprint))
        #expect(state.hasFired("id-259", fingerprint: fingerprint))
    }

    /// The bug this whole mechanism exists for: a reminder delivered under a
    /// four-hour lead time kept suppressing the window after the lead was
    /// changed to 45 minutes, so the reconfigured reminder never arrived.
    @Test("Changing the rule re-arms the window")
    func ruleChangeRearmsWindow() {
        var longLead = ReminderRule.sessionDefault
        longLead.leadTimeMinutes = 260

        var shortLead = longLead
        shortLead.leadTimeMinutes = 45

        var state = NotificationState()
        state.markFired("claude-session-2026-07-31T14:20:00Z", fingerprint: longLead.fingerprint)

        #expect(state.hasFired("claude-session-2026-07-31T14:20:00Z", fingerprint: longLead.fingerprint))
        #expect(!state.hasFired("claude-session-2026-07-31T14:20:00Z", fingerprint: shortLead.fingerprint))
    }

    @Test("Changing the minimum quota also re-arms")
    func minimumQuotaChangeRearms() {
        var original = ReminderRule.sessionDefault
        original.minimumRemainingPercent = 20

        var changed = original
        changed.minimumRemainingPercent = 30

        var state = NotificationState()
        state.markFired("claude-session-x", fingerprint: original.fingerprint)

        #expect(!state.hasFired("claude-session-x", fingerprint: changed.fingerprint))
    }

    /// Toggling the dedup switch is not a statement about *when* to fire.
    @Test("Toggling notify-once does not re-arm")
    func notifyOnceToggleDoesNotRearm() {
        var original = ReminderRule.sessionDefault
        original.notifyOncePerWindow = true

        var changed = original
        changed.notifyOncePerWindow = false

        #expect(original.fingerprint == changed.fingerprint)
    }

    @Test("The delivery time is recorded so the UI can explain the suppression")
    func recordsDeliveryTime() {
        let firedAt = Date(timeIntervalSince1970: 1_780_000_000)
        var state = NotificationState()
        state.markFired("claude-session-x", fingerprint: fingerprint, at: firedAt)

        #expect(state.firedAt("claude-session-x") == firedAt)
        #expect(state.firedAt("never-fired") == nil)
    }

    @Test("Re-arming clears the record entirely")
    func clearingRemovesRecord() {
        var state = NotificationState()
        state.markFired("claude-session-x", fingerprint: fingerprint)
        state.clearFired("claude-session-x")

        #expect(!state.hasFired("claude-session-x", fingerprint: fingerprint))
        #expect(state.fired.isEmpty)
    }
}

/// A Claude Code session window starts on first use. Between one window
/// expiring and the next prompt, the endpoint reports the window with nothing
/// used and no reset time — which previously surfaced as "reset time unknown",
/// i.e. as though the app had failed to read something.
@Suite("Idle session window")
struct IdleWindowTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func sessionWindow(usedPercent: Double?, resetInMinutes: Double?) -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: .session,
            label: "Session",
            usedPercent: usedPercent,
            resetAt: resetInMinutes.map { now.addingTimeInterval($0 * 60) },
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    @Test("Nothing used and no reset time means no window is running")
    func idleWindowDetected() {
        #expect(sessionWindow(usedPercent: 0, resetInMinutes: nil).hasNotStarted)
    }

    @Test("A running window is never mistaken for an idle one")
    func runningWindowIsNotIdle() {
        #expect(!sessionWindow(usedPercent: 44, resetInMinutes: 76).hasNotStarted)
        // Used but no reset time is genuinely odd data, not an idle window.
        #expect(!sessionWindow(usedPercent: 44, resetInMinutes: nil).hasNotStarted)
        // A fresh window that has a clock running is not idle either.
        #expect(!sessionWindow(usedPercent: 0, resetInMinutes: 300).hasNotStarted)
    }

    @Test("An idle window is reported as such rather than as missing data")
    func idleWindowGetsItsOwnReason() {
        let decision = NotificationScheduler.decide(.init(
            window: sessionWindow(usedPercent: 0, resetInMinutes: nil),
            rule: .sessionDefault,
            remindersEnabled: true,
            quietHours: QuietHours(),
            isStale: false,
            queuedTaskCount: 3,
            alreadyFired: false,
            now: now
        ))

        #expect(decision == .skip(reason: .windowNotStarted))
    }

    /// Orange means "something needs your attention". Waiting for a session to
    /// start does not.
    @Test("An idle window is not flagged as noteworthy")
    func idleWindowIsNotNoteworthy() {
        let status = ReminderStatus(decision: .skip(reason: .windowNotStarted))
        #expect(!status.isNoteworthy)
    }

    @Test("A plan without a session window is informative rather than alarming")
    func unavailableWindowIsNotNoteworthy() {
        let status = ReminderStatus(decision: .skip(reason: .windowUnavailable))
        #expect(!status.isNoteworthy)
        #expect(status.summary().contains("plan reports no such window"))
    }

    /// The pending request belongs to the window that just expired.
    @Test("An idle window clears the previous window's pending reminder")
    func idleWindowCancelsPending() {
        #expect(SchedulingDecision.SkipReason.windowNotStarted.shouldCancelPending)
    }
}

@Suite("Transient suppressions keep pending reminders")
struct PendingRetentionTests {
    /// Every launch starts stale and every failed refresh returns to stale. If
    /// those cancelled the pending request, a run of failures would silently
    /// leave the user with no reminder at all.
    @Test("Stale data and unknown reset times do not cancel a scheduled reminder")
    func transientReasonsKeepPending() {
        #expect(!SchedulingDecision.SkipReason.dataStale.shouldCancelPending)
        #expect(!SchedulingDecision.SkipReason.noResetTime.shouldCancelPending)
    }

    @Test("Decisions made from known data do cancel")
    func decidedReasonsCancelPending() {
        for reason: SchedulingDecision.SkipReason in [
            .remindersDisabled, .ruleDisabled, .notEnoughQuotaLeft,
            .windowUnavailable, .queueEmpty, .alreadyFiredForWindow, .quietHours, .resetTooSoon,
        ] {
            #expect(reason.shouldCancelPending)
        }
    }
}

@Suite("Countdown formatting")
struct RelativeTimeTests {
    @Test("Formats the units the popover actually shows")
    func formatsCountdowns() {
        #expect(RelativeTime.countdown(45) == "45s")
        #expect(RelativeTime.countdown(28 * 60) == "28m")
        #expect(RelativeTime.countdown(3 * 3600 + 5 * 60) == "3h 05m")
        #expect(RelativeTime.countdown(2 * 86400 + 9 * 3600) == "2d 9h")
    }

    @Test("Never renders a negative countdown")
    func clampsNegative() {
        #expect(RelativeTime.countdown(-500) == "0s")
    }
}
