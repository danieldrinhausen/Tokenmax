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

    @Test("Spare quota reads as the percentage ahead of an even burn, with a plus")
    func reserveIsPositive() {
        // 2 of 5 hours elapsed, nothing spent: an even burn would have used 40%.
        #expect(text(remaining: 100, resetInHours: 3) == "+40%")
        // 60% left with 3 hours to go is exactly the even line; 80% is 20% over it.
        #expect(text(remaining: 80, resetInHours: 3) == "+20%")
    }

    @Test("Quota spent ahead of an even burn reads as a negative percentage")
    func deficitIsNegative() {
        #expect(text(remaining: 40, resetInHours: 3) == "\u{2212}20%")
    }

    @Test("Exactly on the line carries no sign")
    func onPaceHasNoSign() {
        #expect(text(remaining: 60, resetInHours: 3) == "0%")
        // Under a point either way is what the popover calls "On pace".
        #expect(text(remaining: 60.4, resetInHours: 3) == "0%")
        #expect(text(remaining: 59.6, resetInHours: 3) == "0%")
    }

    /// The reference reading: 98% left with 6d 7h to go is the "8% in reserve"
    /// the weekly row shows. A week must read on the same scale as a session.
    @Test("A weekly reserve is the same percentage the popover states, not a scaled time")
    func weeklyIsAPercentage() {
        #expect(text(kind: .weekly, remaining: 98, resetInHours: 6 * 24 + 7) == "+8%")
    }

    @Test("The text is exactly the popover's reserve percentage")
    func agreesWithTheProjection() throws {
        let window = window(remaining: 70, resetInHours: 2)
        let projection = try #require(UsageProjection.make(window: window, now: now))
        let line = UsageWindowPresentation.projectionLine(for: projection, now: now)
        #expect(line.outlookText == "30% in reserve")
        #expect(MenuBarIconRenderer.reserveText(window: window, now: now) == "+30%")
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
