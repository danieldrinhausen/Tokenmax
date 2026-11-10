import Foundation
import Testing

@testable import Tokenmax

@Suite("Reset time formatting")
struct ResetTimeFormattingTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func window(kind: UsageWindowKind) -> UsageWindow {
        UsageWindow(
            id: "claude.\(kind.rawValue)",
            kind: kind,
            label: "Window",
            usedPercent: 10,
            resetAt: now.addingTimeInterval(7200),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func expected(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: now.addingTimeInterval(7200))
    }

    @Test("A cached formatter prints exactly what a fresh one would, on every call")
    func cachedMatchesFresh() {
        for _ in 0..<3 {
            #expect(UsageWindowPresentation.resetText(for: window(kind: .session), isStale: false, now: now)
                == "Resets in 2h 00m (\(expected("j:mm")))")
        }
        #expect(UsageWindowPresentation.resetText(for: window(kind: .weekly), isStale: false, now: now)
            .hasSuffix("(\(expected("EEE j:mm")))"))
        #expect(UsageWindowPresentation.resetText(for: window(kind: .billingCycle), isStale: false, now: now)
            .hasSuffix("(\(expected("MMM d j:mm")))"))
    }

    @Test("A stale window still never prints a clock time")
    func staleHasNoClock() {
        #expect(UsageWindowPresentation.resetText(for: window(kind: .session), isStale: true, now: now)
            == "Countdown unavailable")
    }
}
