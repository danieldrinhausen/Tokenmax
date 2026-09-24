import Foundation

struct UsageProjectionLinePresentation: Equatable, Sendable {
    let outlookText: String
    let paceText: String
    let isDeficit: Bool
}

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
        case .billingCycle:
            // Weeks out, where the weekday alone would be ambiguous.
            formatter.setLocalizedDateFormatFromTemplate("MMM d j:mm")
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

    /// The projection sentence shared by every quota surface. Keeping both
    /// halves together prevents a compact view from pairing a reserve label
    /// with the deficit-only empty-time estimate.
    static func projectionLine(
        for projection: UsageProjection,
        now: Date
    ) -> UsageProjectionLinePresentation {
        switch projection.outlook {
        case let .reserve(percent):
            return UsageProjectionLinePresentation(
                outlookText: percent.rounded() < 1
                    ? "On pace"
                    : "\(Int(percent.rounded()))% in reserve",
                paceText: "Lasts until reset",
                isDeficit: false
            )
        case let .deficit(percent, emptyAt):
            return UsageProjectionLinePresentation(
                outlookText: percent.rounded() < 1
                    ? "On pace"
                    : "\(Int(percent.rounded()))% in deficit",
                paceText: "Projected empty in \(RelativeTime.countdown(emptyAt.timeIntervalSince(now)))",
                isDeficit: true
            )
        }
    }

    /// A banked reset belongs to the provider rather than either window, so it
    /// sits below both in every surface. One line per reset where the source
    /// lists them, soonest expiry first, so the one to use next is on top; the
    /// count summary otherwise. An expired cached credit is never advertised.
    static func availableResetLines(for snapshot: UsageSnapshot, now: Date) -> [String] {
        let live = (snapshot.availableResets ?? []).filter { $0.expiresAt.map { $0 > now } ?? true }
        guard live.isEmpty else {
            return live.map { reset in
                let title = reset.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Reset"
                guard let expiry = reset.expiresAt else { return title }
                return "\(title) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
            }
        }
        return availableResetText(for: snapshot, now: now).map { [$0] } ?? []
    }

    static func availableResetText(for snapshot: UsageSnapshot, now: Date) -> String? {
        guard let count = snapshot.availableResetCount, count > 0,
              snapshot.availableResetExpiresAt.map({ $0 > now }) ?? true
        else { return nil }

        let noun = count == 1 ? "reset" : "resets"
        if let expiry = snapshot.availableResetExpiresAt {
            return "\(count) available \(noun) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(count) available \(noun)"
    }

    /// Where a banked reset is redeemed. Tokenmax only reports one: spending it
    /// changes the account, so it belongs in the provider's own tool, where the
    /// user can review it first.
    static func resetHelpText(for provider: TokenmaxProvider) -> String {
        switch provider {
        case .claudeCode:
            "A banked reset refills Claude's usage limits once. Use it with /limit-reset in Claude Code; Tokenmax only shows it."
        case .codex, .cursor:
            "A banked reset refreshes Codex's eligible usage windows. Redeem it from Codex after reviewing its offer details."
        }
    }

    /// The one-time cloud credit, in dollars when the source reports them and
    /// as a share otherwise. Like a reset, an expired or fully spent credit is
    /// never advertised.
    static func oneTimeCreditText(for snapshot: UsageSnapshot, now: Date) -> String? {
        guard let credit = snapshot.oneTimeCredit,
              credit.expiresAt.map({ $0 > now }) ?? true
        else { return nil }

        let left: String
        if let remaining = credit.remainingDollars, let limit = credit.limitDollars, limit > 0 {
            guard remaining > 0 else { return nil }
            left = "\(dollars(remaining)) of \(dollars(limit)) left"
        } else if let used = credit.usedPercent {
            guard used < 100 else { return nil }
            left = "\(Int((100 - used).rounded(.down)))% left"
        } else {
            return nil
        }

        if let expiry = credit.expiresAt {
            return "Cloud credit · \(left) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Cloud credit · \(left)"
    }

    static let oneTimeCreditHelpText =
        "Anthropic's one-time Claude Code and Cowork credit, spent by cloud sessions. It does not refill, and Tokenmax never spends it."

    /// Whole dollars stay whole ("$250"); a partly spent balance keeps its
    /// cents. Written out rather than locale-formatted: the credit is granted
    /// in US dollars, and "250 $" would read as a different currency.
    private static func dollars(_ value: Double) -> String {
        value.rounded() == value ? "$\(Int(value))" : String(format: "$%.2f", value)
    }
}
