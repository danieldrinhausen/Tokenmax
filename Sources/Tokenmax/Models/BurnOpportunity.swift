import Foundation

/// "Now is a good time to spend quota."
///
/// Deliberately derived from the same data as the reminder rather than from the
/// notification being delivered: a banner is a single instant and easy to miss,
/// but the *opportunity* lasts until the window resets. The menubar should stay
/// lit for that whole stretch.
struct BurnOpportunity: Equatable, Sendable {
    let kind: UsageWindowKind
    let remainingPercent: Double
    let resetAt: Date

    func timeUntilReset(now: Date = Date()) -> TimeInterval {
        max(0, resetAt.timeIntervalSince(now))
    }

    /// Returns the live opportunity, or nil when there is nothing worth
    /// flagging. Pure, so the conditions are testable without a menubar.
    static func evaluate(
        snapshot: UsageSnapshot?,
        settings: AppSettings,
        isStale: Bool,
        now: Date = Date()
    ) -> BurnOpportunity? {
        guard settings.menuBarHighlightWhenReady else { return nil }

        // Never advertise an opportunity off data we do not trust.
        guard !isStale, let snapshot else { return nil }
        guard let window = snapshot.sessionWindow, let resetAt = window.resetAt else { return nil }

        let rule = settings.sessionReminder
        let remaining = window.remainingPercent ?? 0
        let timeUntilReset = resetAt.timeIntervalSince(now)

        // Inside the lead window…
        guard timeUntilReset <= Double(rule.leadTimeMinutes) * 60 else { return nil }
        // …but with enough time left to actually use it.
        guard timeUntilReset >= NotificationScheduler.minimumUsefulLead else { return nil }
        // …and enough quota left to be worth using.
        guard remaining >= rule.minimumRemainingPercent else { return nil }

        return BurnOpportunity(kind: window.kind, remainingPercent: remaining, resetAt: resetAt)
    }
}
