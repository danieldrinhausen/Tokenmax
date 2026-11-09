import Foundation
import Testing

@testable import Tokenmax

@Suite("Menu bar reserve text")
struct MenuBarReserveTextTests {
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

    private func text(
        kind: UsageWindowKind = .session,
        remaining: Double?,
        resetInHours: Double?
    ) -> String? {
        MenuBarIconRenderer.reserveText(
            window: window(kind: kind, remaining: remaining, resetInHours: resetInHours),
            now: now
        )
    }

    @Test("Spare quota reads as time ahead of an even burn, with a plus")
    func reserveIsPositive() {
        // 2 of 5 hours elapsed, nothing spent: an even burn would have used 40%.
        #expect(text(remaining: 100, resetInHours: 3) == "+2:00")
        // 60% left with 3 hours to go is exactly the even line; 80% is 20% over it.
        #expect(text(remaining: 80, resetInHours: 3) == "+1:00")
    }

    @Test("Quota spent ahead of an even burn reads as time behind, with a minus")
    func deficitIsNegative() {
        #expect(text(remaining: 40, resetInHours: 3) == "\u{2212}1:00")
    }

    @Test("Exactly on the line carries no sign")
    func onPaceHasNoSign() {
        #expect(text(remaining: 60, resetInHours: 3) == "0:00")
        // Thirty seconds ahead is a minute short of a direction worth claiming.
        #expect(text(remaining: 60.1, resetInHours: 3) == "0:00")
    }

    @Test("A weekly reserve over a day switches to days and hours, like the countdown")
    func weeklyUsesDays() {
        // 57% left with 25h to go: the reference reserve of 42.1% of 168h.
        #expect(text(kind: .weekly, remaining: 57, resetInHours: 25) == "+2d 22h")
    }

    /// The same percentage the popover states, scaled to the window: a reserve
    /// the label and the popover disagree on is worse than no label.
    @Test("The time is the popover's reserve percentage scaled by the window length")
    func agreesWithTheProjection() throws {
        let window = window(remaining: 70, resetInHours: 2)
        let projection = try #require(UsageProjection.make(window: window, now: now))
        guard case let .reserve(percent) = projection.outlook else {
            Issue.record("expected a reserve")
            return
        }
        let minutes = Int(percent / 100 * 5 * 60)
        #expect(MenuBarIconRenderer.reserveText(window: window, now: now)
            == "+\(minutes / 60):\(String(format: "%02d", minutes % 60))")
    }

    @Test("Nothing honest to project means no text, never a placeholder")
    func staysQuietWithoutAProjection() {
        #expect(MenuBarIconRenderer.reserveText(window: nil, now: now) == nil)
        // No reset clock running.
        #expect(text(remaining: 50, resetInHours: nil) == nil)
        // Already spent: "limit reached" says it all.
        #expect(text(remaining: 0, resetInHours: 2) == nil)
        // Barely opened: used ÷ elapsed is dividing by almost nothing.
        #expect(text(remaining: 99, resetInHours: 4.99) == nil)
        // A billing cycle has no fixed length, so it has no even-burn line.
        #expect(text(kind: .billingCycle, remaining: 50, resetInHours: 100) == nil)
    }
}
