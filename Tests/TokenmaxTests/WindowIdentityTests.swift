import Foundation
import Testing

@testable import Tokenmax

@Suite("Window identity tolerates a bucket of jitter")
struct WindowIdentityTests {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    @Test("The same instant read a second apart is one window, even across a bucket edge")
    func adjacentBucketsAreTheSameWindow() {
        let a = "opener-" + WindowIdentity.timestamp(base.addingTimeInterval(149.5))
        let b = "opener-" + WindowIdentity.timestamp(base.addingTimeInterval(150.5))
        #expect(a != b)
        #expect(WindowIdentity.isSame(a, b))
        #expect(WindowIdentity.isSame(b, a))
    }

    @Test("Ids two buckets or more apart are different windows")
    func distantIdsDiffer() {
        let a = "opener-" + WindowIdentity.timestamp(base)
        #expect(!WindowIdentity.isSame(a, "opener-" + WindowIdentity.timestamp(base.addingTimeInterval(600))))
        #expect(!WindowIdentity.isSame(a, "opener-" + WindowIdentity.timestamp(base.addingTimeInterval(5 * 3600))))
    }

    @Test("A different prefix is never the same window, however close the times")
    func prefixMustMatch() {
        let stamp = WindowIdentity.timestamp(base)
        #expect(!WindowIdentity.isSame("autorun-" + stamp, "autorun-codex-" + stamp))
        #expect(!WindowIdentity.isSame("opener-" + stamp, "autorun-" + stamp))
    }

    @Test("Ids that carry no timestamp compare by equality alone")
    func unparseableIdsFallBackToEquality() {
        #expect(WindowIdentity.isSame("", ""))
        #expect(WindowIdentity.isSame("window", "window"))
        #expect(!WindowIdentity.isSame("window", "other"))
        #expect(!WindowIdentity.isSame("", "opener-" + WindowIdentity.timestamp(base)))
    }

    @Test("Identifiers keep the format earlier builds wrote")
    func formatIsUnchanged() {
        let date = Date(timeIntervalSince1970: 1_788_177_600) // 2026-08-31T12:00:00Z
        #expect(WindowIdentity.timestamp(date) == "2026-08-31T12:00:00Z")
        #expect(NotificationScheduler.identifier(for: .session, resetAt: date) == "claude-code-session-2026-08-31T12:00:00Z")
        #expect(SessionOpener.cycleID(expiredResetAt: date) == "opener-2026-08-31T12:00:00Z")
        #expect(QueueAutoRun.windowID(resetAt: date) == "autorun-2026-08-31T12:00:00Z")
    }
}
