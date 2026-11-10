import Foundation
import Testing

@testable import Tokenmax

/// A reading taken before a reset says nothing about the window after it. The
/// status line file only changes while a session is answering, so it can sit
/// untouched across a reset and keep reporting the old percentage.
@Suite("Windows read before a reset that has since passed")
struct PastResetWindowTests {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func statusline(observedAt: Date, now: Date) throws -> [UsageWindow] {
        let json = """
        { "rate_limits": { "five_hour": { "used_percentage": 91, "resets_at": 1800000000 },
                           "seven_day": { "used_percentage": 40, "resets_at": 1800500000 } } }
        """
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))
        return StatuslineUsageReader.windows(from: payload, observedAt: observedAt, now: now)
    }

    @Test("A status line reading whose reset has passed is unknown, not the old percentage")
    func staleStatuslineWindowIsUnknown() throws {
        let windows = try statusline(
            observedAt: resetAt.addingTimeInterval(-3600), now: resetAt.addingTimeInterval(60)
        )
        let session = try #require(windows.first { $0.kind == .session })

        #expect(session.usedPercent == nil)
        #expect(session.remainingPercent == nil)
        #expect(session.resetAt == nil)
        #expect(session.confidence == .stale)
    }

    @Test("Only the window that reset is blanked; the other keeps its reading")
    func otherWindowKeepsItsReading() throws {
        let windows = try statusline(
            observedAt: resetAt.addingTimeInterval(-3600), now: resetAt.addingTimeInterval(60)
        )
        let weekly = try #require(windows.first { $0.kind == .weekly })
        #expect(weekly.usedPercent == 40)
    }

    @Test("A status line reading whose reset is still ahead is untouched")
    func liveStatuslineWindowIsKept() throws {
        let windows = try statusline(
            observedAt: resetAt.addingTimeInterval(-3600), now: resetAt.addingTimeInterval(-60)
        )
        let session = try #require(windows.first { $0.kind == .session })
        #expect(session.usedPercent == 91)
        #expect(session.resetAt == resetAt)
    }

    @Test("A reading observed after its reset time is the source's current word and is kept")
    func freshReadingNearItsResetIsKept() throws {
        let windows = try statusline(
            observedAt: resetAt.addingTimeInterval(5), now: resetAt.addingTimeInterval(60)
        )
        #expect(windows.first { $0.kind == .session }?.usedPercent == 91)
    }

    @Test("A window with no reset time is never blanked")
    func noResetTimeIsNotBlanked() {
        let window = UsageWindow(
            id: "w", kind: .session, label: "Session", usedPercent: 0, resetAt: nil,
            observedAt: resetAt, source: .claudeOAuth, confidence: .authoritative
        )
        #expect(window.settingPastResetToUnknown(now: resetAt.addingTimeInterval(9999)) == window)
    }

    @Test("A replayed OAuth response whose window reset meanwhile no longer shows the old utilization")
    func replayedOAuthWindowIsUnknown() throws {
        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: Data("""
        { "five_hour": { "utilization": 95, "resets_at": 1800000000 },
          "seven_day": { "utilization": 30, "resets_at": 1800500000 } }
        """.utf8))

        let windows = ClaudeCodeProvider.windows(
            from: response, observedAt: resetAt.addingTimeInterval(-120), now: resetAt.addingTimeInterval(30)
        )

        #expect(windows.first { $0.id == "claude.session" }?.usedPercent == nil)
        #expect(windows.first { $0.id == "claude.weekly" }?.usedPercent == 30)
    }

    @Test("A fresh authoritative window beats the blanked status line one in the merge")
    func freshWindowWinsTheMerge() throws {
        let blanked = try statusline(
            observedAt: resetAt.addingTimeInterval(-3600), now: resetAt.addingTimeInterval(60)
        ).filter { $0.kind == .session }
        let fresh = UsageWindow(
            id: "claude.session", kind: .session, label: "Session", usedPercent: 2,
            resetAt: resetAt.addingTimeInterval(18_000), observedAt: resetAt.addingTimeInterval(55),
            source: .claudeOAuth, confidence: .authoritative
        )

        let merged = ClaudeCodeProvider.merge(primary: [fresh], fallback: blanked)
        #expect(merged.first?.usedPercent == 2)
    }
}
