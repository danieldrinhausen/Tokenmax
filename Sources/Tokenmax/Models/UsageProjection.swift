import Foundation

extension UsageWindowKind {
    /// How long the window runs for.
    ///
    /// The endpoint reports only when a window *resets*, never when it opened,
    /// so the length has to come from somewhere else — and the API's own field
    /// names state it: `five_hour`, `seven_day`, `seven_day_opus`. Everything
    /// below is derived from this and the reset time, which is why no reading
    /// history is needed.
    var duration: TimeInterval {
        switch self {
        case .session: 5 * 3600
        case .weekly, .modelSpecificWeekly: 7 * 24 * 3600
        }
    }
}

/// Where the current rate of spending lands a window before it resets.
enum UsageOutlook: Equatable, Sendable {
    /// Spending is behind an even burn, leaving this much spare at reset.
    case reserve(percent: Double)
    /// Spending is ahead of an even burn by this much, running the window dry
    /// at `emptyAt`.
    case deficit(percent: Double, emptyAt: Date)
}

/// One window measured against an even burn.
///
/// The reference point is what a constant rate of spending would have left at
/// this exact moment: three of five session hours remaining means 60% of the
/// quota should still be there. Ahead of that line is a reserve, behind it is a
/// deficit.
///
/// Both halves come from the same comparison, so they cannot contradict each
/// other — a deficit is *exactly* the condition under which the average rate
/// empties the window before it resets, and the "projected empty" countdown
/// only ever appears alongside one.
struct UsageProjection: Equatable, Sendable {
    /// Average consumption since the window opened, in percentage points per
    /// hour. Deliberately the average over the whole window rather than a recent
    /// rate: a recent rate measured over minutes and extrapolated across hours
    /// swings wildly with every burst, and the number is meant to answer "am I
    /// on track for this window", which is a question about the window.
    let percentPerHour: Double
    /// Quota an even burn would have *spent* by now: the share of the window
    /// that has elapsed.
    let expectedUsedPercent: Double
    let remainingPercent: Double
    let outlook: UsageOutlook

    /// Quota an even burn would have left at this moment. This is the marker on
    /// the bar, drawn on the same scale as the fill.
    var evenPaceRemainingPercent: Double { 100 - expectedUsedPercent }

    /// Below this the window has barely opened: `used ÷ elapsed` is dividing by
    /// something near zero, so a single early prompt reads as a runaway rate.
    /// Matches CodexBar, which suppresses the line for the same reason — the
    /// first ~9 minutes of a session, the first ~5 hours of a week.
    static let minimumExpectedUsedPercent: Double = 3

    /// Returns `nil` when there is nothing honest to project: no reset clock is
    /// running, the window is already spent, or it has not been open long enough
    /// for an average to mean anything.
    static func make(window: UsageWindow, now: Date) -> UsageProjection? {
        guard let usedPercent = window.usedPercent,
              let remainingPercent = window.remainingPercent
        else { return nil }

        // "Limit reached" already says everything a projection could.
        guard !window.isExhausted else { return nil }
        guard let resetAt = window.resetAt else { return nil }

        let duration = window.kind.duration
        let timeUntilReset = resetAt.timeIntervalSince(now)
        guard timeUntilReset > 0, timeUntilReset < duration else { return nil }

        // Guarded above, so this is always positive.
        let elapsed = duration - timeUntilReset
        let expectedUsedPercent = elapsed / duration * 100
        guard expectedUsedPercent >= minimumExpectedUsedPercent else { return nil }

        let percentPerHour = usedPercent / (elapsed / 3600)
        let evenPaceRemainingPercent = 100 - expectedUsedPercent

        let outlook: UsageOutlook
        if remainingPercent < evenPaceRemainingPercent, percentPerHour > 0 {
            let hoursUntilEmpty = remainingPercent / percentPerHour
            outlook = .deficit(
                percent: evenPaceRemainingPercent - remainingPercent,
                emptyAt: now.addingTimeInterval(hoursUntilEmpty * 3600)
            )
        } else {
            outlook = .reserve(percent: remainingPercent - evenPaceRemainingPercent)
        }

        return UsageProjection(
            percentPerHour: percentPerHour,
            expectedUsedPercent: expectedUsedPercent,
            remainingPercent: remainingPercent,
            outlook: outlook
        )
    }
}
