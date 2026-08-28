import Foundation

/// How a quota window should be described, independent of how it is drawn.
///
/// Both the popover's full meter and the queue's compact bar have to answer the
/// same two questions — how much is left, and when does it reset — and both have
/// to get the same awkward cases right: an idle window that has not started, a
/// window whose reset time was never reported, and a reading too old to speak
/// for the present.
///
/// Keeping the rules here rather than in either view is what stops the two from
/// drifting into disagreeing about the same snapshot.
enum UsageWindowPresentation {
    /// What the reset side of the row should say.
    ///
    /// A stale snapshot must never present its countdown as authoritative: the
    /// numbers were true when they were read and the clock has kept running
    /// since, so the honest statement is that the countdown is unavailable, not
    /// a number that is quietly wrong by however long the staleness lasted.
    ///
    /// "No window running" is a different statement from "reset time unknown".
    /// A Claude Code session window starts on first use, so between one window
    /// expiring and the next prompt there is genuinely nothing to count down to
    /// — reporting that as missing data makes the app look broken when it is
    /// merely idle.
    static func resetText(for window: UsageWindow, isStale: Bool, now: Date) -> String {
        if window.hasNotStarted { return "No window running" }
        guard let resetAt = window.resetAt else { return "Reset time unknown" }
        guard !isStale else { return "Countdown unavailable" }

        let interval = resetAt.timeIntervalSince(now)
        guard interval > 0 else { return "Resetting…" }
        return "Resets in \(RelativeTime.countdown(interval)) (\(localResetTimeText(for: window, resetAt: resetAt)))"
    }

    /// The clock time a reset lands at, in the user's local timezone.
    ///
    /// A session window resets within the same day often enough that the day
    /// would be noise; a weekly window resets 5-7 days out, where the day is
    /// the first thing worth knowing. Both use the locale's own hour format
    /// (12- or 24-hour) rather than hardcoding one.
    private static func localResetTimeText(for window: UsageWindow, resetAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        switch window.kind {
        case .weekly, .modelSpecificWeekly:
            formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        case .session:
            formatter.setLocalizedDateFormatFromTemplate("j:mm")
        }
        return formatter.string(from: resetAt)
    }

    /// The compact form for the queue header, where the row already carries the
    /// window's name and the space for a sentence does not exist.
    static func compactResetText(for window: UsageWindow, isStale: Bool, now: Date) -> String {
        if window.hasNotStarted { return "Not started" }
        guard let resetAt = window.resetAt else { return "Reset unknown" }
        guard !isStale else { return "Countdown unavailable" }

        let interval = resetAt.timeIntervalSince(now)
        guard interval > 0 else { return "Resetting…" }
        return RelativeTime.countdown(interval)
    }

    /// What the remaining side of the row should say.
    static func remainingText(for window: UsageWindow) -> String {
        guard let remaining = window.remainingPercent else { return "Unknown" }
        if window.isExhausted { return "Limit reached" }
        return "\(Int(remaining.rounded()))% left"
    }

    /// The fraction of the bar to fill, or nil when there is nothing to draw.
    ///
    /// Stale readings return nil rather than a faded number: a bar drawn at 89%
    /// is a claim about right now however muted it is, and the row says
    /// "Stale" beside it instead.
    static func fillFraction(for window: UsageWindow, isStale: Bool) -> Double? {
        guard !isStale, let remaining = window.remainingPercent else { return nil }
        return max(0, min(1, remaining / 100))
    }
}
