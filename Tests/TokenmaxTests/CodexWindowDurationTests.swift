import Foundation
import Testing

@testable import Tokenmax

/// A Codex window's real length, from `windowDurationMins`, decides its pace
/// line. The kind alone cannot: Codex tags a five-hour per-model limit and a
/// weekly one the same way.
@Suite("Codex window durations")
struct CodexWindowDurationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private typealias Limits = CodexAppServerClient.RateLimits
    private func window(_ used: Double, minutes: Int?, resetIn hours: Double = 2.5) -> Limits.Window {
        Limits.Window(usedPercent: used, durationMinutes: minutes, resetsAt: now.addingTimeInterval(hours * 3600))
    }

    private func windows(
        primary: Limits.Window? = nil,
        secondary: Limits.Window? = nil,
        additional: [(id: String, name: String?, primary: Limits.Window?, secondary: Limits.Window?)] = []
    ) -> [UsageWindow] {
        CodexProvider.windows(
            from: Limits(primary: primary, secondary: secondary, additional: additional), observedAt: now
        )
    }

    @Test("A five-hour per-model window projects over five hours, not seven days")
    func additionalSessionUsesItsOwnLength() throws {
        let result = windows(additional: [("spark", "Spark", window(40, minutes: 300), nil)])
        let spark = try #require(result.first { $0.id == "codex.spark.session" })

        #expect(spark.windowMinutes == 300)
        let projection = try #require(UsageProjection.make(window: spark, now: now))
        // Two and a half of five hours have gone.
        #expect(abs(projection.expectedUsedPercent - 50) < 0.001)
    }

    @Test("A per-model window with no reported length is not projected at all")
    func unknownLengthIsNotGuessed() throws {
        let result = windows(additional: [("spark", "Spark", window(40, minutes: nil), nil)])
        let spark = try #require(result.first)

        #expect(spark.length == nil)
        #expect(UsageProjection.make(window: spark, now: now) == nil)
    }

    @Test("A Claude per-model weekly window keeps the seven days its endpoint name states")
    func claudeModelWeeklyKeepsKindLength() {
        let opus = UsageWindow(
            id: "claude.weekly.opus", kind: .modelSpecificWeekly, label: "Weekly (Opus)",
            usedPercent: 10, resetAt: now.addingTimeInterval(3 * 24 * 3600), observedAt: now,
            source: .claudeOAuth, confidence: .authoritative
        )
        #expect(opus.length == TimeInterval(7 * 24 * 3600))
        #expect(UsageProjection.make(window: opus, now: now) != nil)
    }

    @Test("A reported length overrides the kind's for the main windows too")
    func reportedLengthWins() throws {
        let result = windows(primary: window(30, minutes: 120, resetIn: 1))
        let session = try #require(result.first)

        #expect(session.kind == .session)
        #expect(session.length == TimeInterval(7200))
    }

    @Test("A long primary plus a secondary no longer share the weekly id")
    func idsAreUnique() {
        let result = windows(
            primary: window(10, minutes: 10_080, resetIn: 100),
            secondary: window(20, minutes: 43_200, resetIn: 400),
            additional: [("spark", "Spark", window(5, minutes: 300), window(6, minutes: 10_080))]
        )

        let ids = result.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("codex.weekly"))
        #expect(ids.contains("codex.secondary"))
        #expect(result.first { $0.id == "codex.secondary" }?.windowMinutes == 43_200)
    }

    @Test("The usual short primary and weekly secondary keep their familiar ids")
    func usualShapeIsUnchanged() {
        let result = windows(primary: window(10, minutes: 300), secondary: window(20, minutes: 10_080, resetIn: 100))
        #expect(result.map(\.id) == ["codex.session", "codex.weekly"])
        #expect(result.map(\.kind) == [.session, .weekly])
    }

    @Test("A single long primary window is the weekly one and a missing secondary adds nothing")
    func singleWeeklyPrimary() {
        let result = windows(primary: window(10, minutes: 10_080, resetIn: 100))
        #expect(result.map(\.id) == ["codex.weekly"])
    }

    @Test("A snapshot saved before windows carried a length still loads, and the length round-trips")
    func windowMinutesIsBackwardCompatible() throws {
        let old = """
        { "id": "codex.session", "kind": "session", "label": "Session", "usedPercent": 5,
          "observedAt": "2026-11-10T10:00:00Z", "source": "codexAppServer", "confidence": "authoritative" }
        """
        let decoded = try JSONStore.makeDecoder().decode(UsageWindow.self, from: Data(old.utf8))
        #expect(decoded.windowMinutes == nil)

        var withLength = decoded
        withLength.windowMinutes = 300
        let data = try JSONStore.makeEncoder().encode(withLength)
        #expect(try JSONStore.makeDecoder().decode(UsageWindow.self, from: data).windowMinutes == 300)
    }
}
