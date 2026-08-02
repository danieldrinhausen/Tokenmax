import Foundation
import Testing

@testable import Tokenmax

@Suite("Burn opportunity")
struct BurnOpportunityTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func snapshot(remaining: Double, resetInMinutes: Double?) -> UsageSnapshot {
        UsageSnapshot(
            providerID: "claude-code",
            planName: "Pro",
            windows: [
                UsageWindow(
                    id: "claude.session",
                    kind: .session,
                    label: "Session",
                    usedPercent: 100 - remaining,
                    resetAt: resetInMinutes.map { now.addingTimeInterval($0 * 60) },
                    observedAt: now,
                    source: .claudeOAuth,
                    confidence: .authoritative
                ),
            ],
            fetchedAt: now,
            fetchDuration: 0.1,
            errorMessage: nil
        )
    }

    private func settings(
        highlight: Bool = true,
        leadMinutes: Int = 60,
        minimumRemaining: Double = 20
    ) -> AppSettings {
        var settings = AppSettings()
        settings.menuBarHighlightWhenReady = highlight
        settings.sessionReminder.leadTimeMinutes = leadMinutes
        settings.sessionReminder.minimumRemainingPercent = minimumRemaining
        return settings
    }

    private func evaluate(
        remaining: Double = 40,
        resetInMinutes: Double? = 30,
        settings: AppSettings? = nil,
        isStale: Bool = false
    ) -> BurnOpportunity? {
        BurnOpportunity.evaluate(
            snapshot: snapshot(remaining: remaining, resetInMinutes: resetInMinutes),
            settings: settings ?? self.settings(),
            isStale: isStale,
            now: now
        )
    }

    @Test("Lights up inside the lead window with usable quota")
    func activeInsideLeadWindow() throws {
        let opportunity = try #require(evaluate())

        #expect(opportunity.kind == .session)
        #expect(opportunity.remainingPercent == 40)
        #expect(opportunity.timeUntilReset(now: now) == 30 * 60)
    }

    @Test("Stays dark before the lead window opens")
    func inactiveBeforeLeadWindow() {
        // Reset in 3 hours with a 1-hour lead: not yet.
        #expect(evaluate(resetInMinutes: 180) == nil)
    }

    @Test("Goes dark once the reset is too close to be useful")
    func inactiveWhenResetImminent() {
        #expect(evaluate(resetInMinutes: 3) == nil)
    }

    @Test("Stays dark when there is not enough quota left to matter")
    func inactiveBelowMinimum() {
        #expect(evaluate(remaining: 5) == nil)
    }

    /// The glow is a claim about live quota; making it on stale data would be
    /// worse than staying dark.
    @Test("Never lights up on stale data")
    func inactiveWhenStale() {
        #expect(evaluate(isStale: true) == nil)
    }

    @Test("Respects the setting being switched off")
    func inactiveWhenDisabled() {
        #expect(evaluate(settings: settings(highlight: false)) == nil)
    }

    @Test("Stays dark without a reset time")
    func inactiveWithoutResetTime() {
        #expect(evaluate(resetInMinutes: nil) == nil)
    }

    @Test("Works with no snapshot at all")
    func inactiveWithoutSnapshot() {
        #expect(
            BurnOpportunity.evaluate(snapshot: nil, settings: settings(), isStale: false, now: now) == nil
        )
    }

    /// The glow tracks the same lead time as the reminder, so the two signals
    /// cannot disagree about when the burn window starts.
    @Test("Follows the configured lead time")
    func followsLeadTime() {
        let short = settings(leadMinutes: 15)
        #expect(evaluate(resetInMinutes: 30, settings: short) == nil)
        #expect(evaluate(resetInMinutes: 10, settings: short) != nil)
    }
}
