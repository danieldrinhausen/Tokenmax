import Foundation
import SQLite3

/// Decoded shape of `GET https://cursor.com/api/usage-summary` — the call
/// Cursor's own dashboard makes to draw its usage meters.
///
/// Undocumented, and every field is optional: this belongs to a web page, not
/// an API. Its predecessors already changed shape once — when Cursor replaced
/// request counts with an included-usage pool, `/api/usage` kept answering 200
/// with a `gpt-4` request count of zero for everyone. A renamed field therefore
/// decodes to nil rather than throwing, and `CursorUsageClient.driftedKeys`
/// tells that apart from an account with nothing to report.
struct CursorUsageSummary: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        let enabled: Bool?
        /// Cents of included usage. Not shown, and nothing is derived from
        /// them: a Pro account has been seen at 2000 of 2000 used while Cursor
        /// reported 9.5% of its total used, so how these relate to Cursor's own
        /// percentages is not known. The percentages are what its dashboard
        /// shows, so they are what Tokenmax shows.
        let used: Double?
        let limit: Double?
        let remaining: Double?
        /// 0–100. Usage routed through Auto mode.
        let autoPercentUsed: Double?
        /// 0–100. Usage on models picked by name, which drains far faster.
        let apiPercentUsed: Double?
        /// 0–100. What Cursor's dashboard calls "your included total usage".
        let totalPercentUsed: Double?
    }

    struct OnDemand: Decodable, Sendable {
        let enabled: Bool?
    }

    struct IndividualUsage: Decodable, Sendable {
        let plan: Plan?
        let onDemand: OnDemand?
    }

    let billingCycleStart: Date?
    let billingCycleEnd: Date?
    let membershipType: String?
    /// `"user"` for a personal plan, `"team"` for a seat billed to a team.
    let limitType: String?
    let isUnlimited: Bool?
    let individualUsage: IndividualUsage?

    private enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, membershipType, limitType, isUnlimited, individualUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = Self.date(container, .billingCycleStart)
        billingCycleEnd = Self.date(container, .billingCycleEnd)
        membershipType = try? container.decodeIfPresent(String.self, forKey: .membershipType)
        limitType = try? container.decodeIfPresent(String.self, forKey: .limitType)
        isUnlimited = try? container.decodeIfPresent(Bool.self, forKey: .isUnlimited)
        individualUsage = try? container.decodeIfPresent(IndividualUsage.self, forKey: .individualUsage)
    }

    /// ISO-8601 strings today; epoch numbers accepted too, for the same reason
    /// `OAuthUsageResponse` accepts both.
    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let number = try? container.decode(Double.self, forKey: key) { return DateNormalizer.fromEpoch(number) }
        if let string = try? container.decode(String.self, forKey: key) { return DateNormalizer.fromString(string) }
        return nil
    }
}

/// The part of Cursor's own sign-in Tokenmax needs, read out of Cursor.app's
/// local state. Held in memory only; never written anywhere.
struct CursorCredentials: Sendable, Equatable {
    let accessToken: String
    let userID: String
    let membershipType: String?

    /// The cookie cursor.com's dashboard is signed in with: the user id and
    /// the same access token, joined by `::`. Built here rather than read from
    /// a browser, so Tokenmax never goes near a browser's cookie store.
    var sessionCookie: String { "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)" }

    /// The user id is the JWT's `sub` claim after its identity-provider prefix
    /// (`auth0|user_01…` → `user_01…`). Decoded without verifying the
    /// signature: Tokenmax is not the audience, it only needs the id the
    /// server will check for itself.
    static func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let subject = object["sub"] as? String,
              let id = subject.split(separator: "|").last, !id.isEmpty
        else { return nil }
        return String(id)
    }
}

enum CursorStateError: Error, Equatable {
    /// No Cursor state database — Cursor.app is not installed, or has never run.
    case missingDatabase
    /// The database is there but holds no usable sign-in.
    case signedOut
    case unreadable(String)
}

/// Reads Cursor.app's sign-in out of its VS Code–style state database
/// (`state.vscdb`, an SQLite file with one key/value table).
///
/// Opened read-only and closed straight away: Cursor writes this file while it
/// runs, and a reader that held it open, or opened it for writing, could get in
/// the way of the app that owns it. Tokenmax never refreshes this token either
/// — Cursor renews its own sign-in whenever it runs, as Claude Code does.
enum CursorStateStore {
    static let accessTokenKey = "cursorAuth/accessToken"
    static let membershipKey = "cursorAuth/stripeMembershipType"

    static func read(from url: URL) throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CursorStateError.missingDatabase }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw CursorStateError.unreadable(message)
        }
        defer { sqlite3_close(database) }
        // Cursor may be mid-write; waiting a moment beats failing the refresh.
        sqlite3_busy_timeout(database, 1000)

        let query = "SELECT key, value FROM ItemTable WHERE key IN (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw CursorStateError.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the string, so the Swift buffer may go.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, accessTokenKey, -1, transient)
        sqlite3_bind_text(statement, 2, membershipKey, -1, transient)

        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) else {
                continue
            }
            values[String(cString: key)] = unquoted(String(cString: value))
        }

        guard let token = values[accessTokenKey], !token.isEmpty,
              let userID = CursorCredentials.userID(fromJWT: token)
        else { throw CursorStateError.signedOut }

        let membership = values[membershipKey].flatMap { $0.isEmpty ? nil : $0 }
        return CursorCredentials(accessToken: token, userID: userID, membershipType: membership)
    }

    /// Values are stored bare today. A JSON-encoded string is accepted too, so
    /// a change to how Cursor serialises them does not read as a sign-out.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}

enum CursorUsageClientError: Error, LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case badStatus(Int)
    case transport(String)
    /// A 200 that no longer carries the percentages this app reads. See
    /// `CursorUsageClient.driftedKeys`.
    case schemaDrift([String])

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Cursor rejected its saved sign-in."
        case .rateLimited: "Cursor rate-limited the usage request."
        case let .badStatus(code): "Cursor's usage request failed with HTTP \(code)."
        case let .transport(message): message
        case let .schemaDrift(keys):
            "Cursor's usage response has changed shape (\(keys.joined(separator: ", "))). Tokenmax needs updating."
        }
    }
}

/// Talks to the endpoint behind Cursor's usage dashboard.
///
/// Cursor documents no rate limit for it, and it is not an API anyone promised
/// to keep serving. The floor keeps an open popover — which ticks every 60s —
/// from asking more often than the numbers can meaningfully move; a billing
/// cycle is a month long.
actor CursorUsageClient {
    static let minimumRequestInterval: TimeInterval = 120

    private let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cached: (summary: CursorUsageSummary, fetchedAt: Date)?
    private var lastRequestAt: Date?

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func fetch(credentials: CursorCredentials) async throws -> (CursorUsageSummary, Date) {
        let current = now()
        if let lastRequestAt, current.timeIntervalSince(lastRequestAt) < Self.minimumRequestInterval {
            if let cached {
                Log.shared.write("cursor: served from cache (\(Int(current.timeIntervalSince(cached.fetchedAt)))s old)")
                return (cached.summary, cached.fetchedAt)
            }
            throw CursorUsageClientError.rateLimited
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        // The dashboard's own origin. Its routes are same-site by design.
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        lastRequestAt = current
        Log.shared.write("cursor: outbound request")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CursorUsageClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageClientError.transport("Malformed response")
        }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw CursorUsageClientError.unauthorized
        case 429: throw CursorUsageClientError.rateLimited
        default: throw CursorUsageClientError.badStatus(http.statusCode)
        }

        let summary: CursorUsageSummary
        do {
            summary = try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            // Not a JSON object at all — most likely a sign-in page served in
            // place of the data. Reported as drift: it is Tokenmax that cannot
            // read the answer, not the user who did something wrong.
            Log.shared.write("cursor: SCHEMA DRIFT — body is not a usage summary")
            throw CursorUsageClientError.schemaDrift(["<not JSON>"])
        }
        if let keys = Self.driftedKeys(summary, data: data) {
            Log.shared.write("cursor: SCHEMA DRIFT — 200 with no known percentages; keys=\(keys.joined(separator: ","))")
            throw CursorUsageClientError.schemaDrift(keys)
        }

        let fetchedAt = now()
        cached = (summary, fetchedAt)
        let plan = summary.individualUsage?.plan
        Log.shared.write("cursor: ok total=\(plan?.totalPercentUsed ?? -1) api=\(plan?.apiPercentUsed ?? -1)")
        return (summary, fetchedAt)
    }

    /// The keys to report when a 200 has drifted out of recognition, or nil
    /// when the response is readable.
    ///
    /// Missing percentages alone are not drift: an unlimited plan and a team
    /// seat have no individual allowance to meter, and an empty body is an
    /// empty answer. Anything else without either percentage means the fields
    /// were renamed, and the keys that *are* there go in the log so the fix
    /// starts from evidence.
    ///
    /// Static and pure so the rule can be tested without a network stub.
    static func driftedKeys(_ summary: CursorUsageSummary, data: Data) -> [String]? {
        let plan = summary.individualUsage?.plan
        guard plan?.totalPercentUsed == nil, plan?.apiPercentUsed == nil else { return nil }
        guard summary.isUnlimited != true, summary.limitType != "team" else { return nil }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard !object.isEmpty else { return nil }
        let individual = object["individualUsage"] as? [String: Any]
        let planObject = individual?["plan"] as? [String: Any]
        return Array((planObject ?? individual ?? object).keys).sorted()
    }
}
