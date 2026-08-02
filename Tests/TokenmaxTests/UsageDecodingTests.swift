import Foundation
import Testing

@testable import Tokenmax

@Suite("OAuth usage decoding")
struct OAuthUsageDecodingTests {
    private func decode(_ json: String) throws -> OAuthUsageResponse {
        try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(json.utf8))
    }

    @Test("Decodes the documented response shape")
    func decodesFullResponse() throws {
        let response = try decode("""
        {
          "five_hour":  { "utilization": 23.5, "resets_at": "2026-07-31T12:00:00Z" },
          "seven_day":  { "utilization": 41.2, "resets_at": "2026-08-02T00:00:00Z" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": false, "utilization": 0 }
        }
        """)

        #expect(response.fiveHour?.utilization == 23.5)
        #expect(response.sevenDay?.utilization == 41.2)
        #expect(response.sevenDayOpus == nil)
        #expect(response.sevenDaySonnet == nil)
        #expect(response.extraUsage?.isEnabled == false)
    }

    @Test("Accepts epoch numbers as well as ISO-8601 strings")
    func decodesEpochResets() throws {
        let response = try decode("""
        { "five_hour": { "utilization": 10, "resets_at": 1785500000 } }
        """)

        #expect(response.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_785_500_000))
    }

    @Test("Survives a missing window rather than throwing")
    func toleratesMissingWindows() throws {
        let response = try decode(#"{ "seven_day": { "utilization": 5, "resets_at": null } }"#)

        #expect(response.fiveHour == nil)
        #expect(response.sevenDay?.utilization == 5)
        #expect(response.sevenDay?.resetsAt == nil)
    }

    @Test("Model-specific weekly windows map to their own kind")
    func mapsModelSpecificWindows() throws {
        let response = try decode("""
        {
          "five_hour": { "utilization": 10, "resets_at": 1785500000 },
          "seven_day_opus": { "utilization": 60, "resets_at": 1785600000 }
        }
        """)

        let windows = ClaudeCodeProvider.windows(from: response, observedAt: Date())
        #expect(windows.count == 2)
        #expect(windows.contains { $0.kind == .session })
        #expect(windows.contains { $0.kind == .modelSpecificWeekly && $0.id == "claude.weekly.opus" })
    }
}

@Suite("Statusline decoding")
struct StatuslineDecodingTests {
    @Test("Decodes the documented statusline payload")
    func decodesPayload() throws {
        let json = """
        {
          "model": { "display_name": "Opus" },
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
            "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
          }
        }
        """
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))

        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 23.5)
        // resets_at is epoch *seconds* in the statusline payload.
        #expect(payload.rateLimits?.fiveHour?.resetDate == Date(timeIntervalSince1970: 1_738_425_600))
    }

    @Test("rate_limits is absent for API-key users and must not crash")
    func toleratesAbsentRateLimits() throws {
        let payload = try JSONDecoder().decode(
            StatuslinePayload.self,
            from: Data(#"{ "model": { "display_name": "Opus" } }"#.utf8)
        )

        #expect(payload.rateLimits == nil)
        #expect(StatuslineUsageReader.windows(from: payload, observedAt: Date()).isEmpty)
    }

    @Test("Each window can be independently absent")
    func handlesPartialWindows() throws {
        let json = #"{ "rate_limits": { "five_hour": { "used_percentage": 12, "resets_at": 1738425600 } } }"#
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))

        let windows = StatuslineUsageReader.windows(from: payload, observedAt: Date())
        #expect(windows.count == 1)
        #expect(windows.first?.kind == .session)
    }
}

@Suite("Epoch normalization")
struct DateNormalizerTests {
    @Test("Distinguishes epoch seconds from milliseconds")
    func normalizesEpochs() {
        let seconds = DateNormalizer.fromEpoch(1_785_500_000)
        let milliseconds = DateNormalizer.fromEpoch(1_785_500_000_000)

        #expect(seconds == Date(timeIntervalSince1970: 1_785_500_000))
        // The keychain stores expiry in ms; the statusline uses seconds. Both
        // must land on the same instant.
        #expect(milliseconds == seconds)
    }

    @Test("Parses ISO-8601 with and without fractional seconds")
    func parsesISOStrings() {
        #expect(DateNormalizer.fromString("2026-07-31T12:00:00Z") != nil)
        #expect(DateNormalizer.fromString("2026-07-31T12:00:00.123Z") != nil)
        #expect(DateNormalizer.fromString("not a date") == nil)
    }
}

@Suite("Window derivation")
struct UsageWindowTests {
    private func window(used: Double?, resetIn: TimeInterval? = nil) -> UsageWindow {
        UsageWindow(
            id: "test",
            kind: .session,
            label: "Session",
            usedPercent: used,
            resetAt: resetIn.map { Date().addingTimeInterval($0) },
            observedAt: Date(),
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    @Test("remaining is derived from used, never stored separately")
    func derivesRemaining() {
        #expect(window(used: 23.5).remainingPercent == 76.5)
        #expect(window(used: nil).remainingPercent == nil)
    }

    @Test("Clamps nonsense values from upstream")
    func clampsOutOfRange() {
        #expect(window(used: 140).remainingPercent == 0)
        #expect(window(used: -20).remainingPercent == 100)
    }

    @Test("Exhaustion is detected at the limit")
    func detectsExhaustion() {
        #expect(window(used: 100).isExhausted)
        #expect(!window(used: 60).isExhausted)
    }
}

@Suite("Source merging")
struct MergeTests {
    private func window(
        id: String,
        source: UsageSource,
        confidence: UsageConfidence,
        used: Double,
        observedAt: Date
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: .session,
            label: "Session",
            usedPercent: used,
            resetAt: nil,
            observedAt: observedAt,
            source: source,
            confidence: confidence
        )
    }

    @Test("Authoritative OAuth data beats the statusline fallback")
    func prefersAuthoritative() {
        let now = Date()
        let merged = ClaudeCodeProvider.merge(
            primary: [window(id: "a", source: .claudeOAuth, confidence: .authoritative, used: 10, observedAt: now)],
            fallback: [window(id: "a", source: .statusline, confidence: .observed, used: 90, observedAt: now)]
        )

        #expect(merged.count == 1)
        #expect(merged.first?.source == .claudeOAuth)
        #expect(merged.first?.usedPercent == 10)
    }

    @Test("Fallback fills windows the primary did not return")
    func fillsGaps() {
        let now = Date()
        let merged = ClaudeCodeProvider.merge(
            primary: [window(id: "session", source: .claudeOAuth, confidence: .authoritative, used: 10, observedAt: now)],
            fallback: [window(id: "weekly", source: .statusline, confidence: .observed, used: 40, observedAt: now)]
        )

        #expect(merged.count == 2)
    }

    @Test("At equal confidence the fresher observation wins")
    func prefersFresherOnTie() {
        let old = Date().addingTimeInterval(-600)
        let recent = Date()
        let merged = ClaudeCodeProvider.merge(
            primary: [window(id: "a", source: .statusline, confidence: .observed, used: 10, observedAt: old)],
            fallback: [window(id: "a", source: .statusline, confidence: .observed, used: 55, observedAt: recent)]
        )

        #expect(merged.first?.usedPercent == 55)
    }
}
