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

    // MARK: - Banked resets and the one-time cloud credit

    /// Trimmed from a live `?cedar_ember=1` response, grant ids replaced.
    private let creditAndResets = """
    {
      "five_hour": { "utilization": 29.0, "resets_at": "2026-09-24T08:00:00.128102+00:00",
                     "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "iguana_necktie": { "utilization": 12.0, "resets_at": "2026-11-05T07:59:00+00:00",
                          "limit_dollars": 250, "used_dollars": 30.0, "remaining_dollars": 220.0,
                          "locked_reason": null },
      "cinder_cove": null,
      "cedar_ember": {
        "eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [],
        "grants": [
          { "id": "g1", "label": "", "resets_total": 2, "resets_left": 2,
            "starts_at": null, "ends_at": "2026-10-10T00:00:00Z", "clears": [], "paused": false,
            "usable_now": true, "use_requires_limit": false, "percent_used": {}, "blocking": [] },
          { "id": "g2", "label": "", "resets_total": 1, "resets_left": 1,
            "starts_at": null, "ends_at": "2026-10-01T00:00:00Z", "clears": [], "paused": false,
            "usable_now": true, "use_requires_limit": false, "percent_used": {}, "blocking": [] },
          { "id": "g3", "label": "", "resets_total": 4, "resets_left": 4,
            "starts_at": null, "ends_at": "2026-09-01T00:00:00Z", "clears": [], "paused": false,
            "usable_now": false, "use_requires_limit": false, "percent_used": {}, "blocking": [] }
        ],
        "next_grant_id": "g2", "weekly_resets_at": null, "cooldown_until": null, "event_props": null
      },
      "extra_usage": { "is_enabled": false, "utilization": null }
    }
    """

    private let september24 = DateNormalizer.fromString("2026-09-24T12:00:00Z")!

    @Test("Resets sum across live grants and report the nearest use-by date")
    func decodesResets() throws {
        let response = try decode(creditAndResets)
        let resets = try #require(response.availableResets(now: september24))

        // g3 expired on September 1 and must not be counted.
        #expect(resets.count == 3)
        #expect(resets.nearestExpiry == DateNormalizer.fromString("2026-10-01T00:00:00Z"))
        #expect(response.extraUsage?.isEnabled == false)
    }

    @Test("An absent reset block is unknown, an ineligible one is none")
    func absentAndIneligibleResets() throws {
        #expect(try decode(#"{ "five_hour": null }"#).availableResets(now: september24) == nil)

        let ineligible = try decode("""
        { "cedar_ember": { "eligible": false, "ineligible_reason": "surface", "grants": [] } }
        """).availableResets(now: september24)
        #expect(ineligible?.count == 0)
        #expect(ineligible?.nearestExpiry == nil)
    }

    @Test("A malformed reset block drops only itself")
    func malformedResetsKeepTheMeters() throws {
        let response = try decode("""
        { "five_hour": { "utilization": 10 }, "cedar_ember": { "eligible": true, "grants": "x" } }
        """)

        #expect(response.fiveHour?.utilization == 10)
        #expect(response.availableResets(now: september24)?.count == 0)
    }

    @Test("The dollar credit is read with its expiry")
    func decodesDollarCredit() throws {
        let credit = try #require(try decode(creditAndResets).oneTimeCreditReading)

        #expect(credit.remainingDollars == 220)
        #expect(credit.limitDollars == 250)
        #expect(credit.usedPercent == 12)
        #expect(credit.expiresAt == DateNormalizer.fromString("2026-11-05T07:59:00Z"))
    }

    @Test("The percentage-only credit is the fallback")
    func decodesPercentCredit() throws {
        let credit = try #require(try decode("""
        { "cinder_cove": { "utilization": 40, "resets_at": "2026-10-31T00:00:00Z" } }
        """).oneTimeCreditReading)

        #expect(credit.usedPercent == 40)
        #expect(credit.remainingDollars == nil)
    }

    @Test("No credit block means no credit")
    func absentCredit() throws {
        #expect(try decode(#"{ "iguana_necktie": null, "cinder_cove": null }"#).oneTimeCreditReading == nil)
    }

    // MARK: - Schema drift

    private func drift(_ json: String) throws -> [String]? {
        let data = Data(json.utf8)
        return ClaudeOAuthUsageClient.driftedKeys(
            try JSONDecoder().decode(OAuthUsageResponse.self, from: data),
            data: data
        )
    }

    @Test("A renamed window set is reported as drift, not as no data")
    func renamedWindowsAreDrift() throws {
        // Every field is optional, so this decodes cleanly to all-nil. Without
        // the tripwire it would surface as "no quota" and hide an upstream
        // change indefinitely.
        let keys = try drift("""
        {
          "five_hour_window": { "utilization": 23.5 },
          "seven_day_window": { "utilization": 41.2 }
        }
        """)

        #expect(keys == ["five_hour_window", "seven_day_window"])
    }

    @Test("Explicitly empty windows are not drift")
    func emptyWindowsAreNotDrift() throws {
        // An account with nothing to report. The keys are still the ones we
        // expect, so this is silence, not a schema change.
        #expect(try drift("""
        { "five_hour": null, "seven_day": null }
        """) == nil)
    }

    @Test("An added window alongside a known one is not drift")
    func addedWindowIsNotDrift() throws {
        // The endpoint is expected to gain windows over time. As long as one
        // known key is present, this app is still reading the right response.
        #expect(try drift("""
        { "five_hour": null, "thirty_day": { "utilization": 5 } }
        """) == nil)
    }

    @Test("A body holding only the credit and resets is not drift")
    func creditOnlyIsNotDrift() throws {
        #expect(try drift("""
        { "iguana_necktie": { "utilization": 0 }, "cedar_ember": { "eligible": false } }
        """) == nil)
    }

    @Test("An empty body is not drift")
    func emptyBodyIsNotDrift() throws {
        #expect(try drift("{}") == nil)
    }

    @Test("A readable response is never drift")
    func readableResponseIsNotDrift() throws {
        #expect(try drift("""
        { "five_hour": { "utilization": 23.5 } }
        """) == nil)
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
