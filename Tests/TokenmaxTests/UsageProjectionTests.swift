import Foundation
import Testing

@testable import Tokenmax

@Suite("Usage projection")
struct UsageProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func window(
        kind: UsageWindowKind = .session,
        remaining: Double?,
        resetInHours: Double?
    ) -> UsageWindow {
        UsageWindow(
            id: "claude.\(kind.rawValue)",
            kind: kind,
            label: "Session",
            usedPercent: remaining.map { 100 - $0 },
            resetAt: resetInHours.map { now.addingTimeInterval($0 * 3600) },
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func project(
        kind: UsageWindowKind = .session,
        remaining: Double?,
        resetInHours: Double?
    ) -> UsageProjection? {
        UsageProjection.make(window: window(kind: kind, remaining: remaining, resetInHours: resetInHours), now: now)
    }

    private func deficit(_ projection: UsageProjection?) throws -> (percent: Double, emptyAt: Date) {
        let projection = try #require(projection)
        guard case let .deficit(percent, emptyAt) = projection.outlook else {
            Issue.record("expected a deficit, got \(projection.outlook)")
            throw CancellationError()
        }
        return (percent, emptyAt)
    }

    private func reserve(_ projection: UsageProjection?) throws -> Double {
        let projection = try #require(projection)
        guard case let .reserve(percent) = projection.outlook else {
            Issue.record("expected a reserve, got \(projection.outlook)")
            throw CancellationError()
        }
        return percent
    }

    // MARK: - Window lengths

    /// Everything else is derived from these two numbers and the reset time.
    /// The endpoint never reports when a window opened, so getting the length
    /// wrong silently skews every projection.
    @Test("Window lengths match the endpoint's own field names")
    func windowDurations() {
        #expect(UsageWindowKind.session.duration == 5 * 3600)
        #expect(UsageWindowKind.weekly.duration == 7 * 24 * 3600)
        #expect(UsageWindowKind.modelSpecificWeekly.duration == 7 * 24 * 3600)
    }

    // MARK: - The even-burn reference

    @Test("The pace marker is the share of the window still to run")
    func evenPaceReference() throws {
        // Three of five session hours left: an even burn would have left 60%.
        let projection = try #require(project(remaining: 60, resetInHours: 3))
        #expect(abs(projection.evenPaceRemainingPercent - 60) < 0.001)

        let percent = try reserve(projection)
        #expect(percent.rounded() < 1)
    }

    @Test("Spending exactly on the line is neither a deficit nor a reserve")
    func onPace() throws {
        let percent = try reserve(project(remaining: 40, resetInHours: 2))
        #expect(abs(percent) < 0.001)
    }

    // MARK: - Reference readings

    /// The readings below are taken from a side-by-side comparison against
    /// CodexBar on the same account at the same moment. They are the
    /// specification for this arithmetic: an earlier version extrapolated a
    /// *recent* burn rate instead, and reported a 94% deficit where the true
    /// figure was 34%.
    ///
    /// The deficit and reserve percentages are pinned tightly because they
    /// depend only on the clock. The countdowns are given two minutes of slack:
    /// they are reconstructed from figures that were already rounded for
    /// display, and "22% left" covers a range wide enough to move the answer by
    /// about a minute on its own.
    @Test("Session deficit matches the reference: 28% left, 3h 6m to reset")
    func referenceSessionDeficit() throws {
        // Even burn leaves 3.1/5 = 62%; the account is 34 points behind that.
        let (percent, emptyAt) = try deficit(project(remaining: 28, resetInHours: 3.1))

        #expect(abs(percent - 34) < 0.5)
        // 72% used over 1h 54m is 37.9%/h, so 28% lasts another 45 minutes.
        #expect(abs(emptyAt.timeIntervalSince(now) / 60 - 45) < 2)
    }

    @Test("Session deficit matches the reference: 22% left, 3h 3m to reset")
    func referenceSessionDeficitLater() throws {
        let (percent, emptyAt) = try deficit(project(remaining: 22, resetInHours: 3.05))

        #expect(abs(percent - 39) < 0.5)
        #expect(abs(emptyAt.timeIntervalSince(now) / 60 - 34) < 2)
    }

    @Test("Session deficit matches the reference: 59% left, 3h 34m to reset")
    func referenceSessionEarly() throws {
        let (percent, emptyAt) = try deficit(project(remaining: 59, resetInHours: 3 + 34 / 60.0))

        #expect(abs(percent - 12) < 0.5)
        // 41% used over 1h 26m is 28.6%/h, so 59% lasts another 2h 4m.
        #expect(abs(emptyAt.timeIntervalSince(now) / 60 - 124) < 2)
    }

    @Test("Weekly reserve matches the reference: 57% left, 1d 1h to reset")
    func referenceWeeklyReserve() throws {
        // 25 of 168 hours left: an even burn would have left 14.9%.
        let percent = try reserve(project(kind: .weekly, remaining: 57, resetInHours: 25))

        #expect(abs(percent - 42) < 0.5)
    }

    @Test("Weekly reserve matches the reference: 60% left, 1d 1h to reset")
    func referenceWeeklyReserveEarlier() throws {
        let percent = try reserve(project(kind: .weekly, remaining: 60, resetInHours: 25))
        #expect(abs(percent - 45) < 0.5)
    }

    @Test("Projection copy keeps reserve and deficit meanings paired")
    func projectionCopyStaysConsistent() throws {
        let deficit = UsageWindowPresentation.projectionLine(
            for: try #require(project(remaining: 28, resetInHours: 3.1)),
            now: now
        )
        let reserve = UsageWindowPresentation.projectionLine(
            for: try #require(project(kind: .weekly, remaining: 57, resetInHours: 25)),
            now: now
        )

        #expect(deficit.outlookText == "34% in deficit")
        #expect(deficit.paceText.hasPrefix("Projected empty in "))
        #expect(deficit.isDeficit)
        #expect(reserve.outlookText == "42% in reserve")
        #expect(reserve.paceText == "Lasts until reset")
        #expect(!reserve.isDeficit)
    }

    // MARK: - Internal consistency

    /// The two halves of the line come from one comparison, so they can never
    /// disagree: a deficit is *exactly* the condition under which the average
    /// rate empties the window early. If these ever diverge the popover would
    /// claim a reserve while counting down to empty.
    @Test("A deficit always empties before the reset, a reserve never does")
    func outlookAgreesWithCountdown() throws {
        for remaining in stride(from: 5.0, through: 95.0, by: 5) {
            for resetInHours in stride(from: 0.5, through: 4.5, by: 0.5) {
                let projection = try #require(project(remaining: remaining, resetInHours: resetInHours))
                let resetAt = now.addingTimeInterval(resetInHours * 3600)

                switch projection.outlook {
                case let .deficit(_, emptyAt):
                    #expect(emptyAt < resetAt, "\(remaining)% with \(resetInHours)h left")
                case .reserve:
                    // The mirror of the above: an even-or-slower burn cannot run
                    // out before the window it is being measured against.
                    let hoursUntilEmpty = remaining / projection.percentPerHour
                    #expect(hoursUntilEmpty >= resetInHours - 0.001, "\(remaining)% with \(resetInHours)h left")
                }
            }
        }
    }

    // MARK: - Refusals

    @Test("Projects nothing without a reset clock")
    func noProjectionWithoutResetTime() {
        #expect(project(remaining: 60, resetInHours: nil) == nil)
    }

    @Test("Projects nothing once the reset has passed")
    func noProjectionAfterReset() {
        #expect(project(remaining: 60, resetInHours: -1) == nil)
    }

    /// A reset further out than the window is long means the window cannot have
    /// opened yet, or the assumed length is wrong. Either way the elapsed time
    /// underpinning every figure here would be negative.
    @Test("Projects nothing when the reset is further out than the window is long")
    func noProjectionBeyondWindowLength() {
        #expect(project(remaining: 100, resetInHours: 6) == nil)
        #expect(project(kind: .weekly, remaining: 100, resetInHours: 200) == nil)
    }

    /// "Limit reached" already says everything a projection could, and the
    /// deficit arithmetic on a spent window produces "empty in 0s".
    @Test("Projects nothing for a spent window")
    func noProjectionWhenExhausted() {
        #expect(project(remaining: 0, resetInHours: 3) == nil)
    }

    @Test("Projects nothing when usage is unknown")
    func noProjectionWithoutUsage() {
        #expect(project(remaining: nil, resetInHours: 3) == nil)
    }

    /// An untouched window is behind an even burn by definition, and dividing
    /// its zero rate into the remaining quota must not reach the countdown.
    @Test("An untouched window is all reserve, with no countdown")
    func untouchedWindowIsReserve() throws {
        let percent = try reserve(project(remaining: 100, resetInHours: 3))

        #expect(abs(percent - 40) < 0.001)
    }

    /// `used ÷ elapsed` divides by something near zero here, so one early
    /// prompt reads as a runaway rate. CodexBar suppresses the line on the same
    /// 3% threshold.
    @Test("Says nothing until the window has meaningfully opened")
    func noProjectionInTheFirstMinutes() {
        // 4 minutes into a 5-hour session is 1.3% elapsed.
        #expect(project(remaining: 90, resetInHours: 5 - 4 / 60.0) == nil)
        // 9 minutes in clears the threshold.
        #expect(project(remaining: 90, resetInHours: 5 - 10 / 60.0) != nil)

        // The same rule costs the weekly window its first five hours.
        #expect(project(kind: .weekly, remaining: 99, resetInHours: 168 - 4) == nil)
        #expect(project(kind: .weekly, remaining: 99, resetInHours: 168 - 6) != nil)
    }
}
