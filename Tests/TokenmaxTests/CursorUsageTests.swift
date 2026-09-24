import Foundation
import SQLite3
import Testing

@testable import Tokenmax

/// The response Cursor returned for a real Pro account, verbatim.
private let observedSummary = """
{"billingCycleStart":"2026-08-25T09:23:16.000Z","billingCycleEnd":"2026-09-25T09:23:16.000Z","membershipType":"pro","limitType":"user","isUnlimited":false,"autoModelSelectedDisplayMessage":"You've used 10% of your included total usage","namedModelSelectedDisplayMessage":"You've used 93% of your included API usage","individualUsage":{"plan":{"enabled":true,"used":2000,"limit":2000,"remaining":0,"breakdown":{"included":2000,"bonus":2711,"total":4711},"autoPercentUsed":1.1511111111111112,"apiPercentUsed":93.17777777777778,"totalPercentUsed":9.517171717171717},"onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},"teamUsage":{}}
"""

private func decode(_ json: String) throws -> CursorUsageSummary {
    try JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
}

/// A JWT-shaped string whose payload carries `sub`. The signature is junk;
/// nothing on Tokenmax's side verifies it.
private func token(sub: String) -> String {
    let payload = Data(#"{"sub":"\#(sub)","exp":1893456000}"#.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2lnbmF0dXJl"
}

@Suite("Cursor usage decoding")
struct CursorUsageDecodingTests {
    @Test("Decodes the response a real Pro account returned")
    func decodesObservedResponse() throws {
        let summary = try decode(observedSummary)

        #expect(summary.membershipType == "pro")
        #expect(summary.limitType == "user")
        #expect(summary.billingCycleEnd == DateNormalizer.fromString("2026-09-25T09:23:16.000Z"))
        #expect(summary.individualUsage?.plan?.totalPercentUsed == 9.517171717171717)
        #expect(summary.individualUsage?.plan?.apiPercentUsed == 93.17777777777778)
        #expect(summary.individualUsage?.onDemand?.enabled == false)
    }

    @Test("Maps API and Auto usage to two billing-cycle windows, API first, resetting at the cycle's end")
    func mapsTwoWindows() throws {
        let summary = try decode(observedSummary)
        let windows = CursorProvider.windows(from: summary, observedAt: Date())

        #expect(windows.map(\.id) == ["cursor.api", "cursor.auto"])
        #expect(windows.allSatisfy { $0.kind == .billingCycle })
        #expect(windows.allSatisfy { $0.resetAt == summary.billingCycleEnd })
        #expect(windows.allSatisfy { $0.source == .cursorDashboard })
        #expect(Int(windows[0].remainingPercent?.rounded() ?? -1) == 7)
        #expect(Int(windows[1].remainingPercent?.rounded() ?? -1) == 99)
    }

    @Test("A missing percentage drops only its own window")
    func missingPercentageDropsItsWindow() throws {
        let summary = try decode("""
        { "billingCycleEnd": "2026-09-25T09:23:16.000Z",
          "individualUsage": { "plan": { "autoPercentUsed": 40 } } }
        """)
        #expect(CursorProvider.windows(from: summary, observedAt: Date()).map(\.id) == ["cursor.auto"])
    }

    @Test("A field of the wrong type costs that field, not the whole response")
    func toleratesWrongTypes() throws {
        let summary = try decode("""
        { "billingCycleEnd": 1790328196000, "membershipType": 7, "isUnlimited": "no",
          "individualUsage": { "plan": { "totalPercentUsed": 12 } } }
        """)
        #expect(summary.membershipType == nil)
        #expect(summary.isUnlimited == nil)
        #expect(summary.billingCycleEnd == Date(timeIntervalSince1970: 1_790_328_196))
        #expect(summary.individualUsage?.plan?.totalPercentUsed == 12)
    }

    @Test("Plan identifiers become display names")
    func planNames() {
        #expect(CursorProvider.planName("pro") == "Pro")
        #expect(CursorProvider.planName("pro_plus") == "Pro Plus")
        #expect(CursorProvider.planName("") == nil)
        #expect(CursorProvider.planName(nil) == nil)
    }

    @Test("A billing cycle gets no projection rather than one against a guessed length")
    func noProjectionForBillingCycle() throws {
        let summary = try decode(observedSummary)
        let window = try #require(CursorProvider.windows(from: summary, observedAt: Date()).first)
        let now = try #require(DateNormalizer.fromString("2026-09-10T00:00:00Z"))
        #expect(UsageProjection.make(window: window, now: now) == nil)
    }
}

@Suite("Cursor schema drift")
struct CursorSchemaDriftTests {
    private func drifted(_ json: String) throws -> [String]? {
        CursorUsageClient.driftedKeys(try decode(json), data: Data(json.utf8))
    }

    @Test("The observed response is not drift")
    func observedIsNotDrift() throws {
        #expect(try drifted(observedSummary) == nil)
    }

    @Test("Renamed percentages are drift, and the log names the keys that are there instead")
    func renamedPercentagesAreDrift() throws {
        let keys = try drifted("""
        { "limitType": "user", "individualUsage": { "plan": { "totalUsedPct": 9, "apiUsedPct": 93 } } }
        """)
        #expect(keys == ["apiUsedPct", "totalUsedPct"])
    }

    @Test("A restructured top level is drift")
    func restructuredTopLevelIsDrift() throws {
        #expect(try drifted(#"{ "usage": { "percent": 9 } }"#) == ["usage"])
    }

    @Test("An unlimited plan has nothing to meter and is not drift")
    func unlimitedIsNotDrift() throws {
        #expect(try drifted(#"{ "isUnlimited": true, "individualUsage": { "plan": {} } }"#) == nil)
    }

    @Test("A team seat has no individual allowance and is not drift")
    func teamSeatIsNotDrift() throws {
        #expect(try drifted(#"{ "limitType": "team", "individualUsage": {} }"#) == nil)
    }

    @Test("An empty answer is empty, not drift")
    func emptyIsNotDrift() throws {
        #expect(try drifted("{}") == nil)
    }
}

@Suite("Cursor sign-in")
struct CursorCredentialTests {
    @Test("The user id is the JWT subject after its identity-provider prefix")
    func userIDFromSubject() {
        #expect(CursorCredentials.userID(fromJWT: token(sub: "auth0|user_01ABC")) == "user_01ABC")
        #expect(CursorCredentials.userID(fromJWT: token(sub: "user_01ABC")) == "user_01ABC")
    }

    @Test("Anything that is not a JWT yields no user id")
    func garbageHasNoUserID() {
        #expect(CursorCredentials.userID(fromJWT: "not-a-token") == nil)
        #expect(CursorCredentials.userID(fromJWT: "a.b.c") == nil)
        #expect(CursorCredentials.userID(fromJWT: token(sub: "")) == nil)
    }

    @Test("The session cookie joins the user id and the token with an encoded double colon")
    func sessionCookieShape() {
        let credentials = CursorCredentials(accessToken: "tok", userID: "user_1", membershipType: nil)
        #expect(credentials.sessionCookie == "WorkosCursorSessionToken=user_1%3A%3Atok")
    }
}

@Suite("Cursor state database")
struct CursorStateStoreTests {
    private func database(_ rows: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-state-\(UUID().uuidString).vscdb")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil) == SQLITE_OK)
        for (key, value) in rows {
            let sql = "INSERT INTO ItemTable VALUES ('\(key)', '\(value)')"
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    @Test("Reads the token, user id and plan out of Cursor's state database")
    func readsSignIn() throws {
        let url = try database([
            CursorStateStore.accessTokenKey: token(sub: "auth0|user_9"),
            CursorStateStore.membershipKey: "pro",
            "unrelated/key": "ignored",
        ])
        let credentials = try CursorStateStore.read(from: url)
        #expect(credentials.userID == "user_9")
        #expect(credentials.membershipType == "pro")
    }

    @Test("A JSON-quoted value reads the same as a bare one")
    func acceptsQuotedValues() throws {
        let url = try database([CursorStateStore.accessTokenKey: "\"\(token(sub: "user_9"))\""])
        #expect(try CursorStateStore.read(from: url).userID == "user_9")
    }

    @Test("No database means Cursor is not installed")
    func missingDatabase() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).vscdb")
        #expect(throws: CursorStateError.missingDatabase) { try CursorStateStore.read(from: url) }
    }

    @Test("A database without a token is a signed-out Cursor, not a broken one")
    func noTokenIsSignedOut() throws {
        let url = try database([CursorStateStore.membershipKey: "pro"])
        #expect(throws: CursorStateError.signedOut) { try CursorStateStore.read(from: url) }
    }

    @Test("A signed-out Cursor fails before any request is made, naming Cursor")
    func signedOutNeverReachesTheNetwork() async throws {
        let url = try database([:])
        let provider = CursorProvider(stateDatabase: url)
        await #expect(throws: ProviderError.notAuthenticated("Cursor")) { try await provider.fetchUsage() }
        #expect(await provider.checkAuthentication() == .notAuthenticated)
    }

    @Test("A missing Cursor reports itself as not installed")
    func missingCursorIsNotInstalled() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).vscdb")
        let provider = CursorProvider(stateDatabase: url)
        await #expect(throws: ProviderError.notInstalled("Cursor")) { try await provider.fetchUsage() }
        #expect(await provider.checkAuthentication() == .notInstalled)
    }

    @Test("Tests are pointed away from the real Cursor sign-in")
    func testsNeverReadTheRealDatabase() {
        #expect(!FileLocations.cursorStateDatabase.path.contains("Library/Application Support/Cursor"))
    }
}
