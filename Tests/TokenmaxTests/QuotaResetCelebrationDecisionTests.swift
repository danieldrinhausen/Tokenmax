import Foundation
import Testing

@testable import Tokenmax

@Suite("Quota reset celebration decisions")
struct QuotaResetCelebrationDecisionTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private func window(resetAt: Date?) -> UsageWindow {
        UsageWindow(
            id: "session", kind: .session, label: "Session", usedPercent: 10,
            resetAt: resetAt, observedAt: now, source: .manual, confidence: .authoritative
        )
    }

    private func decision(
        previous: Date? = Date(timeIntervalSince1970: 1_785_590_000),
        current: Date? = Date(timeIntervalSince1970: 1_785_610_000),
        settings: QuotaResetCelebrationSettings = .init(),
        stale: Bool = false,
        quietHours: Bool = false
    ) -> QuotaResetCelebrationDecision.Verdict {
        QuotaResetCelebrationDecision.decide(.init(
            provider: .claudeCode, kind: .session,
            previous: previous.map { window(resetAt: $0) }, current: current.map { window(resetAt: $0) },
            settings: settings, isStale: stale, isQuietHours: quietHours, now: now
        ))
    }

    @Test("A confirmed successor window celebrates when every reset is selected")
    func celebratesConfirmedReset() {
        var settings = QuotaResetCelebrationSettings()
        settings.enabled = true
        #expect(decision(settings: settings) == .celebrate(.claudeSession))
    }

    @Test("A selected-events policy stays quiet for an event it does not include")
    func selectedEventsFilterResets() {
        var settings = QuotaResetCelebrationSettings()
        settings.enabled = true
        settings.mode = .selectedResets
        settings.selectedEvents = [.claudeWeekly]
        #expect(decision(settings: settings) == .suppress(.eventNotSelected))
    }

    @Test("A reset-time change before the old window ends is not celebrated")
    func ignoresJitterBeforeReset() {
        var settings = QuotaResetCelebrationSettings()
        settings.enabled = true
        #expect(decision(previous: now.addingTimeInterval(30), settings: settings) == .suppress(.previousWindowStillActive))
    }

    @Test("Stale quota never celebrates")
    func staleQuotaStaysQuiet() {
        var settings = QuotaResetCelebrationSettings()
        settings.enabled = true
        #expect(decision(settings: settings, stale: true) == .suppress(.dataStale))
    }

    @Test("Quiet hours suppress an otherwise confirmed reset")
    func quietHoursStayQuiet() {
        var settings = QuotaResetCelebrationSettings()
        settings.enabled = true
        #expect(decision(settings: settings, quietHours: true) == .suppress(.quietHours))
    }
}
