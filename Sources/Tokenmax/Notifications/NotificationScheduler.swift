import Foundation
import UserNotifications

/// Why a reminder was or was not scheduled. Kept explicit so the decision is
/// testable and greppable in the log rather than buried in nested `if`s.
enum SchedulingDecision: Equatable, Sendable {
    case schedule(identifier: String, fireDate: Date, title: String, body: String)
    /// We are already inside the lead window but the reminder has not been sent
    /// for it yet — deliver immediately rather than silently doing nothing.
    case deliverNow(identifier: String, title: String, body: String)
    case skip(reason: SkipReason)

    enum SkipReason: String, Equatable, Sendable {
        case remindersDisabled
        case ruleDisabled
        case dataStale
        case noSnapshot
        /// The provider returned a valid snapshot, but this plan does not
        /// include the window being configured.
        case windowUnavailable
        case noResetTime
        /// No window is running yet — the session clock starts on first use.
        /// Nothing to remind about, and nothing wrong.
        case windowNotStarted
        case notEnoughQuotaLeft
        case queueEmpty
        case alreadyFiredForWindow
        case quietHours
        /// Inside the lead window, but so close to reset that there is no
        /// longer time to use the quota — a banner would just be noise.
        case resetTooSoon

        /// Whether an already-scheduled request should be torn down when this
        /// reason applies.
        ///
        /// `dataStale` and `noResetTime` mean "we cannot currently confirm",
        /// not "the user does not want this". Every launch begins stale, and
        /// every failed refresh returns to stale — cancelling on those reasons
        /// destroys a perfectly good pending reminder and only re-creates it if
        /// a later refresh succeeds. When the refresh keeps failing (an expired
        /// Claude Code token, say) the reminder is simply gone, which is how
        /// reminders go missing without a single error in the log.
        ///
        /// `windowNotStarted` is the opposite: it is a *confirmed* absence, and
        /// any pending request belongs to the window that just expired, so it
        /// has to go.
        var shouldCancelPending: Bool {
            switch self {
            case .dataStale, .noResetTime: false
            case .noSnapshot: true
            default: true
            }
        }
    }

    var identifier: String? {
        switch self {
        case let .schedule(identifier, _, _, _): identifier
        case let .deliverNow(identifier, _, _): identifier
        case .skip: nil
        }
    }
}

/// Resolves a delivered notification back to the persisted rule that created
/// it. Metadata is authoritative, while the identifier fallback keeps banners
/// scheduled by older builds deduplicated after an upgrade.
struct ReminderRuleSource: Equatable, Sendable {
    var provider: TokenmaxProvider
    var kind: UsageWindowKind
}

enum ReminderRuleSourceResolver {
    static func resolve(
        identifier: String,
        providerID: String?,
        windowKind: String?
    ) -> ReminderRuleSource {
        let explicitProvider = providerID.flatMap(TokenmaxProvider.init(rawValue:))
        let explicitKind = windowKind.flatMap(UsageWindowKind.init(rawValue:))
        let base = identifier.components(separatedBy: "-snooze-").first ?? identifier

        let inferred = TokenmaxProvider.allCases.lazy.compactMap { provider in
            UsageWindowKind.allCases.first { kind in
                base.hasPrefix("\(provider.rawValue)-\(kind.rawValue)-")
            }.map { ReminderRuleSource(provider: provider, kind: $0) }
        }.first

        return ReminderRuleSource(
            provider: explicitProvider ?? inferred?.provider ?? .claudeCode,
            kind: explicitKind ?? inferred?.kind ?? .session
        )
    }
}

/// Builds and applies quota reminders.
///
/// The identifier is `claude-{window}-{ISO8601 resetAt}`. Because it is derived
/// from the reset timestamp, re-scheduling the same window is idempotent — this
/// is what stops repeated refreshes from stacking up duplicate notifications.
enum NotificationScheduler {
    struct Input {
        var providerID: String = TokenmaxProvider.claudeCode.rawValue
        var window: UsageWindow
        var rule: ReminderRule
        var remindersEnabled: Bool
        var quietHours: QuietHours
        var isStale: Bool
        var queuedTaskCount: Int
        /// When the queue feature is switched off there is no queue to speak of,
        /// so `rule.onlyWhenTasksQueued` is ignored rather than silently
        /// suppressing every reminder, and the banner drops the task phrase.
        var queueEnabled: Bool = true
        var alreadyFired: Bool
        var now: Date
    }

    static func identifierPrefix(
        for kind: UsageWindowKind,
        providerID: String = TokenmaxProvider.claudeCode.rawValue
    ) -> String {
        "\(providerID)-\(kind.rawValue)-"
    }

    /// Reset timestamps from the usage endpoint jitter between fetches — the
    /// same window has been observed reporting both `09:00:00Z` and
    /// `08:59:59Z`. Bucketing absorbs that.
    static let identifierBucket: TimeInterval = 300

    /// Identity only — the fire time is still computed from the raw `resetAt`,
    /// so bucketing costs no scheduling precision.
    ///
    /// This stability is what makes "notify once per window" hold: the fired
    /// identifier is recorded in `NotificationState`, and a one-second drift
    /// would make the lookup miss and deliver a second banner for the same
    /// window.
    static func identifier(
        for kind: UsageWindowKind,
        resetAt: Date,
        providerID: String = TokenmaxProvider.claudeCode.rawValue
    ) -> String {
        let bucketed = Date(
            timeIntervalSince1970: (resetAt.timeIntervalSince1970 / identifierBucket)
                .rounded() * identifierBucket
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return identifierPrefix(for: kind, providerID: providerID) + formatter.string(from: bucketed)
    }

    /// Below this much time to reset there is no longer room to actually spend
    /// the quota, so a late reminder is noise rather than help.
    static let minimumUsefulLead: TimeInterval = 5 * 60

    /// Pure decision function — every suppression guard from the plan lives here.
    static func decide(_ input: Input) -> SchedulingDecision {
        guard input.remindersEnabled else { return .skip(reason: .remindersDisabled) }
        guard input.rule.enabled else { return .skip(reason: .ruleDisabled) }

        // Never schedule off data we do not trust.
        guard !input.isStale else { return .skip(reason: .dataStale) }
        // "No session running" and "reset time missing" look identical in the
        // payload but mean opposite things to the user, so they are separated
        // before the reset time is required.
        guard !input.window.hasNotStarted else { return .skip(reason: .windowNotStarted) }
        guard let resetAt = input.window.resetAt else { return .skip(reason: .noResetTime) }

        let identifier = identifier(for: input.window.kind, resetAt: resetAt, providerID: input.providerID)

        // The point of the reminder is quota about to be *wasted*. If there is
        // barely anything left there is nothing to warn about.
        let remaining = input.window.remainingPercent ?? 0
        guard remaining >= input.rule.minimumRemainingPercent else {
            return .skip(reason: .notEnoughQuotaLeft)
        }

        if input.queueEnabled, input.rule.onlyWhenTasksQueued, input.queuedTaskCount == 0 {
            return .skip(reason: .queueEmpty)
        }

        // nil = "there is no queue", which reads differently from "the queue is
        // empty" and is what the banner has to say.
        let queuedTaskCount: Int? = input.queueEnabled ? input.queuedTaskCount : nil

        let fireDate = resetAt.addingTimeInterval(-Double(input.rule.leadTimeMinutes) * 60)
        let timeUntilReset = resetAt.timeIntervalSince(input.now)

        guard !input.quietHours.contains(max(fireDate, input.now)) else {
            return .skip(reason: .quietHours)
        }

        // Normal case: the lead point is still ahead of us.
        if fireDate > input.now {
            if input.rule.notifyOncePerWindow, input.alreadyFired {
                return .skip(reason: .alreadyFiredForWindow)
            }
            return .schedule(
                identifier: identifier,
                fireDate: fireDate,
                title: title(for: input.window.kind, providerID: input.providerID),
                body: body(
                    kind: input.window.kind,
                    timeUntilReset: Double(input.rule.leadTimeMinutes) * 60,
                    remainingPercent: remaining,
                    queuedTaskCount: queuedTaskCount
                )
            )
        }

        // We are already past the lead point. Silently doing nothing here is
        // what makes the app look broken: the user configured "remind me an
        // hour before reset", enabled it 58 minutes before reset, and got
        // nothing. If there is still usable time, tell them now.
        guard timeUntilReset >= minimumUsefulLead else { return .skip(reason: .resetTooSoon) }

        // Immediate delivery is always once-per-window regardless of the
        // setting — "deliver now" would otherwise repeat on every refresh.
        guard !input.alreadyFired else { return .skip(reason: .alreadyFiredForWindow) }

        return .deliverNow(
            identifier: identifier,
            title: title(for: input.window.kind, providerID: input.providerID),
            body: body(
                kind: input.window.kind,
                timeUntilReset: timeUntilReset,
                remainingPercent: remaining,
                queuedTaskCount: queuedTaskCount
            )
        )
    }

    static func title(
        for kind: UsageWindowKind,
        providerID: String = TokenmaxProvider.claudeCode.rawValue
    ) -> String {
        let provider = TokenmaxProvider.from(identifier: providerID)?.displayName ?? providerID
        return switch kind {
        case .session: "\(provider) window ending soon"
        case .weekly: "\(provider) weekly limit resets soon"
        case .modelSpecificWeekly: "\(provider) model limit resets soon"
        }
    }

    /// `timeUntilReset` is the real interval the banner will describe, so a
    /// late-delivered reminder says "resets in 43m" rather than parroting the
    /// configured lead time.
    ///
    /// `queuedTaskCount` is nil when the queue feature is switched off; the
    /// banner then says nothing about tasks rather than reporting an empty queue
    /// the user has no way to fill.
    static func body(
        kind: UsageWindowKind,
        timeUntilReset: TimeInterval,
        remainingPercent: Double,
        queuedTaskCount: Int?
    ) -> String {
        let windowName = switch kind {
        case .session: "five-hour window"
        case .weekly: "weekly window"
        case .modelSpecificWeekly: "model window"
        }

        let countdown = RelativeTime.countdown(timeUntilReset)
        let percent = Int(remainingPercent.rounded())

        guard let queuedTaskCount else {
            return "Your \(windowName) resets in \(countdown). Approximately \(percent)% remains."
        }

        let taskPhrase = switch queuedTaskCount {
        case 0: "no tasks are queued"
        case 1: "1 task is queued"
        default: "\(queuedTaskCount) tasks are queued"
        }

        return "Your \(windowName) resets in \(countdown). Approximately \(percent)% remains and \(taskPhrase)."
    }

    // MARK: - Applying

    /// Sub-second differences come from the endpoint's own jitter and are not
    /// worth tearing down a pending request for; anything larger is a real
    /// change the user should get.
    static func shouldReschedule(from scheduled: Date, to desired: Date, tolerance: TimeInterval = 1) -> Bool {
        abs(scheduled.timeIntervalSince(desired)) > tolerance
    }

    /// A pending request that is about to fire is left alone — a remove/re-add
    /// that close to delivery risks losing it, and at most a minute of drift on
    /// a multi-hour window is not worth that.
    static let refreshBlackout: TimeInterval = 60

    enum PendingUpdate: Equatable {
        case keep
        case replace
    }

    /// Notification content is immutable once scheduled, so a reminder queued an
    /// hour ahead would announce the quota figure from an hour ago. Re-issuing
    /// the request whenever the body changes keeps the delivered percentage
    /// honest.
    static func pendingUpdate(
        scheduledFireDate: Date?,
        scheduledBody: String,
        desiredFireDate: Date,
        desiredBody: String,
        now: Date
    ) -> PendingUpdate {
        guard let scheduledFireDate else { return .replace }

        if scheduledFireDate.timeIntervalSince(now) < refreshBlackout { return .keep }

        if shouldReschedule(from: scheduledFireDate, to: desiredFireDate) { return .replace }
        if scheduledBody != desiredBody { return .replace }
        return .keep
    }

    /// Cancels any stale pending request for this window, then schedules or
    /// delivers the current one. Safe to call on every refresh.
    ///
    /// Returns the identifier when the reminder was delivered *immediately*, so
    /// the caller can record it as fired — an already-delivered notification has
    /// no pending request to dedup against.
    @discardableResult
    static func apply(
        _ decision: SchedulingDecision,
        kind: UsageWindowKind,
        playSound: Bool,
        providerID: String = TokenmaxProvider.claudeCode.rawValue,
        center: UNUserNotificationCenter = .current()
    ) async -> String? {
        let prefix = identifierPrefix(for: kind, providerID: providerID)
        let pending = await center.pendingNotificationRequests()
        let existing = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }

        switch decision {
        case let .schedule(identifier, fireDate, title, body):
            // Anything for this window that is not the current reset time is obsolete.
            let obsolete = existing.filter { $0 != identifier }
            if !obsolete.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: obsolete)
            }

            // Already queued under this identifier. Dedup on identity alone
            // would pin the original fire time forever, so a lead-time change
            // in Settings would silently not take effect until the window
            // rolled. Compare the actual fire time and only skip a true no-op.
            if let current = pending.first(where: { $0.identifier == identifier }) {
                let update = pendingUpdate(
                    scheduledFireDate: (current.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                    scheduledBody: current.content.body,
                    desiredFireDate: fireDate,
                    desiredBody: body,
                    now: Date()
                )
                if update == .keep { return nil }
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = NotificationManager.categoryIdentifier
            content.userInfo = ["windowKind": kind.rawValue, "providerID": providerID]
            if playSound { content.sound = .default }
            NotificationIcon.attach(to: content)

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )

            do {
                try await center.add(request)
                Log.shared.write("notify: scheduled \(identifier) for \(fireDate)")
            } catch {
                Log.shared.write("notify: schedule FAILED \(identifier): \(error.localizedDescription)")
            }
            return nil

        case let .deliverNow(identifier, title, body):
            if !existing.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: existing)
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = NotificationManager.categoryIdentifier
            content.userInfo = ["windowKind": kind.rawValue, "providerID": providerID]
            if playSound { content.sound = .default }
            NotificationIcon.attach(to: content)

            // nil trigger = deliver immediately.
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

            do {
                try await center.add(request)
                Log.shared.write("notify: delivered \(identifier) immediately (already inside lead window)")
                return identifier
            } catch {
                Log.shared.write("notify: immediate delivery FAILED \(identifier): \(error.localizedDescription)")
                return nil
            }

        case let .skip(reason):
            if !existing.isEmpty, reason.shouldCancelPending {
                center.removePendingNotificationRequests(withIdentifiers: existing)
                Log.shared.write("notify: cleared \(existing.count) pending for \(kind.rawValue) (\(reason.rawValue))")
            } else if !existing.isEmpty {
                Log.shared.write(
                    "notify: kept \(existing.count) pending for \(kind.rawValue) despite \(reason.rawValue)"
                )
            } else {
                // Log even when there was nothing pending. A silent correct
                // decision is indistinguishable from a broken app otherwise.
                Log.shared.write("notify: no reminder for \(kind.rawValue) (\(reason.rawValue))")
            }
            return nil
        }
    }
}
