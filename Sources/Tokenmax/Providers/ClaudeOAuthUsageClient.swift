import Foundation

/// Decoded shape of `GET https://api.anthropic.com/api/oauth/usage`.
struct OAuthUsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        /// 0–100.
        let utilization: Double?
        let resetsAt: Date?
        /// Reported only on dollar-denominated blocks, such as the one-time
        /// cloud credit; null on the rate-limit windows.
        let limitDollars: Double?
        let remainingDollars: Double?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case limitDollars = "limit_dollars"
            case remainingDollars = "remaining_dollars"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // One mistyped field must not fail the whole read. A number is the
            // documented shape; a numeric string has been seen from sibling
            // endpoints, and costs nothing to accept.
            if let number = try? container.decode(Double.self, forKey: .utilization) {
                utilization = number
            } else if let string = try? container.decode(String.self, forKey: .utilization) {
                utilization = Double(string.trimmingCharacters(in: .whitespaces))
            } else {
                utilization = nil
            }
            limitDollars = try? container.decodeIfPresent(Double.self, forKey: .limitDollars)
            remainingDollars = try? container.decodeIfPresent(Double.self, forKey: .remainingDollars)

            // The endpoint has been observed returning both ISO-8601 strings and
            // numeric epochs; accept either rather than breaking on a format change.
            if let seconds = try? container.decode(Double.self, forKey: .resetsAt) {
                resetsAt = DateNormalizer.fromEpoch(seconds)
            } else if let string = try? container.decode(String.self, forKey: .resetsAt) {
                resetsAt = DateNormalizer.fromString(string)
            } else {
                resetsAt = nil
            }
        }

        init(utilization: Double?, resetsAt: Date?, limitDollars: Double? = nil, remainingDollars: Double? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.limitDollars = limitDollars
            self.remainingDollars = remainingDollars
        }
    }

    struct ExtraUsage: Decodable, Sendable {
        let isEnabled: Bool?
        let utilization: Double?

        private enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
        }

        /// Per field, for the same reason as `Window`: `is_enabled` is the value
        /// the automation's "never spend credits" guard reads, and a mistyped
        /// `utilization` beside it must not take it down. A mistyped
        /// `is_enabled` itself stays nil — unknown, which the guard reads as
        /// "do not spend".
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            utilization = try? container.decodeIfPresent(Double.self, forKey: .utilization)
        }
    }

    /// Banked limit resets (`cedar_ember`, the block behind Claude Code's reset
    /// command). Read only: spending one is a separate POST that Tokenmax never
    /// makes, for the same reason it never redeems a Codex reset.
    struct LimitResets: Decodable, Sendable {
        struct Grant: Decodable, Sendable {
            let resetsLeft: Int?
            /// The use-by date Claude Code shows as "use by {date}".
            let endsAt: Date?

            private enum CodingKeys: String, CodingKey {
                case resetsLeft = "resets_left"
                case endsAt = "ends_at"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                resetsLeft = try? container.decodeIfPresent(Int.self, forKey: .resetsLeft)
                endsAt = (try? container.decodeIfPresent(String.self, forKey: .endsAt))
                    .flatMap(DateNormalizer.fromString)
            }

            init(resetsLeft: Int?, endsAt: Date?) {
                self.resetsLeft = resetsLeft
                self.endsAt = endsAt
            }
        }

        let eligible: Bool?
        let grants: [Grant]?

        private enum CodingKeys: String, CodingKey {
            case eligible
            case grants
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try? container.decodeIfPresent(Bool.self, forKey: .eligible)
            grants = try? container.decodeIfPresent([Grant].self, forKey: .grants)
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let extraUsage: ExtraUsage?
    /// The one-time Claude Code and Cowork credit that cloud sessions spend.
    /// Two upstream shapes carry it: `iguana_necktie`, in dollars, which is how
    /// it arrived on accounts at launch, and `cinder_cove`, a bare percentage,
    /// which is what Claude Code's own `/usage` reads. The dollar block wins
    /// when both are present, because it is the one that can say "$250 left".
    let oneTimeCredit: Window?
    let limitResets: LimitResets?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case iguanaNecktie = "iguana_necktie"
        case cinderCove = "cinder_cove"
        case cedarEmber = "cedar_ember"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Per block: one malformed window used to fail the whole response with
        // a raw DecodingError. It now drops to nil, and `driftedKeys` still
        // calls it drift when that leaves no window at all.
        fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
        sevenDayOpus = try? container.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try? container.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        extraUsage = try? container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        // The credit and the resets are extras. A malformed block drops just
        // that block rather than failing the read the quota meters depend on.
        let dollars = try? container.decodeIfPresent(Window.self, forKey: .iguanaNecktie)
        let percent = try? container.decodeIfPresent(Window.self, forKey: .cinderCove)
        oneTimeCredit = dollars ?? percent
        limitResets = try? container.decodeIfPresent(LimitResets.self, forKey: .cedarEmber)
    }

    /// Available resets and the nearest use-by date. nil when the block is
    /// absent — the source did not say, which is not the same as "none". An
    /// ineligible account, or one with no grants, is an authoritative zero.
    /// A grant already past its use-by date is not counted even if the
    /// response still lists it.
    func availableResets(now: Date) -> (count: Int, nearestExpiry: Date?)? {
        guard let limitResets else { return nil }
        guard limitResets.eligible != false else { return (0, nil) }

        let live = (limitResets.grants ?? []).filter { grant in
            (grant.resetsLeft ?? 0) > 0 && grant.endsAt.map { $0 > now } ?? true
        }
        let count = live.reduce(0) { $0 + ($1.resetsLeft ?? 0) }
        return (count, live.compactMap(\.endsAt).min())
    }

    /// The credit as the model stores it, or nil when neither block was sent.
    var oneTimeCreditReading: OneTimeCredit? {
        guard let oneTimeCredit else { return nil }
        return OneTimeCredit(
            usedPercent: oneTimeCredit.utilization,
            remainingDollars: oneTimeCredit.remainingDollars,
            limitDollars: oneTimeCredit.limitDollars,
            expiresAt: oneTimeCredit.resetsAt
        )
    }
}

enum DateNormalizer {
    /// Accepts epoch seconds or milliseconds. Anything past ~year 5000 in
    /// seconds is really milliseconds.
    static func fromEpoch(_ value: Double) -> Date {
        value > 100_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }

    /// Built once: a formatter per call was two allocations for every window of
    /// every response. `ISO8601DateFormatter` is documented thread-safe for
    /// parsing on the macOS versions this app supports, but it is not
    /// `Sendable`, hence `nonisolated(unsafe)` — the instances are never
    /// mutated after this initialiser, which is what makes that claim true.
    private nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func fromString(_ value: String) -> Date? {
        if let date = withFractional.date(from: value) { return date }
        if let date = plain.date(from: value) { return date }

        if let seconds = Double(value) { return fromEpoch(seconds) }
        return nil
    }
}

enum UsageClientError: Error, LocalizedError {
    case rateLimited
    case unauthorized
    /// A 403: the token was accepted as a login but refused usage — an
    /// account type the endpoint does not report for, or a token without the
    /// scope (one from `claude setup-token`, say). Kept apart from
    /// `unauthorized` because every remedy for that one — waiting for Claude
    /// Code to renew, re-reading the keychain — hands back a token the endpoint
    /// refuses in exactly the same way.
    case forbidden
    case badStatus(Int)
    case transport(String)
    /// A 200 whose body no longer contains any window this app knows how to
    /// read. Every field of `OAuthUsageResponse` is optional — which is the
    /// right shape for an endpoint that may add windows — but it means a
    /// *renamed* window decodes to all-nil and would otherwise be reported as
    /// "no quota data" rather than "this app can no longer read the response".
    case schemaDrift([String])
    /// Not a failure: the request floor is still running and there is nothing
    /// cached to replay, which is what a launch inside it looks like (the floor
    /// is persisted, the response is not). The coordinator keeps whatever it
    /// already shows — the last snapshot, as stale data — and tries again when
    /// the floor lifts, rather than reporting an error nobody caused.
    case withinFloor(until: Date)

    var errorDescription: String? {
        switch self {
        case let .withinFloor(until):
            "Usage was requested a moment ago; Tokenmax asks again at \(until.formatted(date: .omitted, time: .shortened))."
        case .rateLimited: "Anthropic rate-limited the usage request."
        case .unauthorized: "Claude Code needs to be re-authenticated."
        case .forbidden:
            "Anthropic does not report usage for this Claude login (HTTP 403). The account type may not support it, or the login may lack usage access — signing in again with `claude auth login` restores it for a login made with `claude setup-token`."
        case let .badStatus(code): "Usage request failed with HTTP \(code)."
        case let .transport(message): message
        case let .schemaDrift(keys):
            "The usage response has changed shape (\(keys.joined(separator: ", "))). Tokenmax needs updating."
        }
    }
}

/// The request floor as it is remembered across launches: two timestamps and
/// nothing else. Not the response and nothing sensitive — only *when* the
/// endpoint was last asked and when it said to wait until — so a relaunch or a
/// crash loop cannot fire a request the moment it starts. Every field is
/// optional and decoded leniently, like every other file here.
struct UsageRequestFloor: Codable, Equatable, Sendable {
    var lastRequestAt: Date?
    var retryAfterUntil: Date?

    /// A `Retry-After` longer than this is treated as this long. It can only
    /// ever lengthen the floor, but a typo'd header must not park the meter for
    /// days, and an hour is already far beyond anything a rate limit means.
    static let maximumRetryAfter: TimeInterval = 3600

    init(lastRequestAt: Date? = nil, retryAfterUntil: Date? = nil) {
        self.lastRequestAt = lastRequestAt
        self.retryAfterUntil = retryAfterUntil
    }

    private enum CodingKeys: String, CodingKey { case lastRequestAt, retryAfterUntil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastRequestAt = try? container.decodeIfPresent(Date.self, forKey: .lastRequestAt)
        retryAfterUntil = try? container.decodeIfPresent(Date.self, forKey: .retryAfterUntil)
    }

    /// The earliest instant the endpoint may be asked again. The server's
    /// `Retry-After` is a minimum on top of the 180s floor, never a
    /// replacement for it.
    func nextRequestAllowedAt(minimumInterval: TimeInterval) -> Date? {
        let fromFloor = lastRequestAt?.addingTimeInterval(minimumInterval)
        switch (fromFloor, retryAfterUntil) {
        case let (floor?, retry?): return max(floor, retry)
        case let (floor?, nil): return floor
        case let (nil, retry?): return retry
        case (nil, nil): return nil
        }
    }

    /// A file written under another clock must not lock the endpoint out: a
    /// request "in the future" is treated as made now, and a wait is capped.
    func sanitised(now: Date) -> UsageRequestFloor {
        var copy = self
        if let last = copy.lastRequestAt, last > now { copy.lastRequestAt = now }
        if let until = copy.retryAfterUntil {
            copy.retryAfterUntil = until > now ? min(until, now.addingTimeInterval(Self.maximumRetryAfter)) : nil
        }
        return copy
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date. nil when absent or
    /// unreadable — an unreadable header changes nothing.
    static func retryAfterDeadline(header: String?, now: Date) -> Date? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        let wait: TimeInterval
        if let seconds = TimeInterval(header) {
            guard seconds >= 0, seconds.isFinite else { return nil }
            wait = seconds
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: header) else { return nil }
            wait = date.timeIntervalSince(now)
        }
        return now.addingTimeInterval(min(wait, maximumRetryAfter))
    }
}

/// Talks to the undocumented OAuth usage endpoint.
///
/// Two things are non-negotiable here and both are enforced internally rather
/// than left to callers:
///
/// 1. `User-Agent: claude-code/<version>` — without it requests land in an
///    aggressively rate-limited bucket and get persistent 429s.
/// 2. A hard 180-second floor between network calls. The UI ticks every 60s
///    while the popover is open; those extra ticks are served from cache.
actor ClaudeOAuthUsageClient {
    static let minimumRequestInterval: TimeInterval = 180

    /// `cedar_ember=1` adds the banked-reset block. Claude Code pairs it with
    /// `skip_spend=1`, but that also nulls `extra_usage` — the one field the
    /// automation's "never spend credits" guard reads — so it is left off.
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var cached: (response: OAuthUsageResponse, fetchedAt: Date)?
    private var floor = UsageRequestFloor()
    /// How the latest request ended, when it ended badly. While the floor runs
    /// this is what a caller gets instead of the older cached success: replaying
    /// that success reset the coordinator's failure streak and showed "loaded"
    /// over a 429 that was still in force.
    private var lastFailure: UsageClientError?
    private let floorFile: URL?

    /// `floorFile` persists the floor across launches. Nil (the default) keeps
    /// it in memory, which is what every test wants: a shared file would hand one
    /// test's floor to the next.
    init(
        session: URLSession = .shared,
        floorFile: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.floorFile = floorFile
        self.now = now
        if let floorFile, let saved = JSONStore.load(UsageRequestFloor.self, from: floorFile) {
            floor = saved.sanitised(now: now())
        }
    }

    private func saveFloor() {
        guard let floorFile else { return }
        JSONStore.save(floor, to: floorFile, durable: false)
    }

    /// Errors that provably never put a request on the wire. Only these may
    /// leave the floor unarmed: with no route, or no address to connect to,
    /// the server cannot have counted anything, so the wake-from-sleep case
    /// (Wi-Fi not up yet) does not cost a 180s wait. Deliberately narrow — a
    /// timeout, a reset connection or a refused one may have delivered the
    /// request, and for those the floor stays armed.
    static func neverReachedServer(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return code == .notConnectedToInternet || code == .dnsLookupFailed || code == .cannotFindHost
    }

    /// The earliest instant a call would actually hit the network rather than
    /// replay the cache.
    ///
    /// Exposed so the session opener can schedule its verification *after* the
    /// floor lifts. Without it, a refresh issued right after the opener returns
    /// the pre-opener cached response, and the verification concludes the reset
    /// never advanced — failing a run that in fact succeeded. Reading the floor
    /// is the fix; weakening it is not.
    var nextRequestAllowedAt: Date {
        floor.nextRequestAllowedAt(minimumInterval: Self.minimumRequestInterval) ?? .distantPast
    }

    /// Returns cached data when called inside the 180s window.
    /// `force` still respects the floor — it only bypasses a *fresh* cache hit.
    func fetch(accessToken: String, cliVersion: String) async throws -> (OAuthUsageResponse, Date) {
        let current = now()

        let allowedAt = nextRequestAllowedAt
        if current < allowedAt {
            if let lastFailure {
                // The latest request failed and the floor is still running:
                // say so again rather than hand back an older success.
                Log.shared.write("usage: inside the request floor after a failure; repeating it (\(lastFailure.localizedDescription))")
                throw lastFailure
            }
            if let cached {
                Log.shared.write("usage: served from cache (\(Int(current.timeIntervalSince(cached.fetchedAt)))s old)")
                return (cached.response, cached.fetchedAt)
            }
            // Floor is active but we have nothing cached — a launch inside a
            // persisted floor. Surfaced as its own case rather than hammering
            // the endpoint or reporting a rate limit nobody hit.
            throw UsageClientError.withinFloor(until: allowedAt)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Armed before the I/O, not after: a request that is in flight when the
        // app quits has still been counted.
        let previousFloor = floor
        floor.lastRequestAt = current
        floor.retryAfterUntil = nil
        saveFloor()
        Log.shared.write("usage: outbound request (ua=claude-code/\(cliVersion))")

        do {
            let result = try await send(request)
            lastFailure = nil
            return result
        } catch let error as UsageClientError {
            lastFailure = error
            throw error
        } catch {
            // Not a client error: a cancellation, or a transport error that
            // never reached the server (see `send`).
            guard Self.neverReachedServer(error) else { throw error }
            floor = previousFloor
            saveFloor()
            Log.shared.write("usage: request never left the machine (\(error.localizedDescription)); floor not armed")
            throw UsageClientError.transport(error.localizedDescription)
        }
    }

    /// The network half of `fetch`. Throws `UsageClientError` for anything the
    /// server answered or the response got wrong, and the raw error for a
    /// cancellation or a request that never left the machine, which `fetch`
    /// treats differently from the rest.
    private func send(_ request: URLRequest) async throws -> (OAuthUsageResponse, Date) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Handed up as a cancellation, not wrapped: once it is a message
            // string nothing can tell it from a dead network.
            if error.isCancellation { throw CancellationError() }
            if Self.neverReachedServer(error) { throw error }
            throw UsageClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.transport("Malformed response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageClientError.unauthorized
        case 403:
            throw UsageClientError.forbidden
        case 429:
            // The server's own wait lengthens the floor and never shortens it.
            if let until = UsageRequestFloor.retryAfterDeadline(
                header: http.value(forHTTPHeaderField: "Retry-After"), now: now()
            ) {
                floor.retryAfterUntil = until
                saveFloor()
                Log.shared.write("usage: 429 with Retry-After; next request not before \(until)")
            }
            throw UsageClientError.rateLimited
        default:
            throw UsageClientError.badStatus(http.statusCode)
        }

        let decoded: OAuthUsageResponse
        do {
            decoded = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        } catch {
            // Not a JSON object at all — a sign-in page, say. Reported as drift
            // rather than as a raw DecodingError ("The data couldn't be
            // read…"): it is Tokenmax that cannot read the answer.
            Log.shared.write("usage: SCHEMA DRIFT — body is not a usage response")
            throw UsageClientError.schemaDrift(["<not JSON>"])
        }
        try checkForDrift(decoded, data: data)

        let fetchedAt = now()
        cached = (decoded, fetchedAt)
        Log.shared.write("usage: ok five_hour=\(decoded.fiveHour?.utilization ?? -1) seven_day=\(decoded.sevenDay?.utilization ?? -1)")
        return (decoded, fetchedAt)
    }

    private func checkForDrift(_ decoded: OAuthUsageResponse, data: Data) throws {
        guard let keys = Self.driftedKeys(decoded, data: data) else { return }
        Log.shared.write("usage: SCHEMA DRIFT — 200 with no known windows; keys=\(keys.joined(separator: ","))")
        throw UsageClientError.schemaDrift(keys)
    }

    /// The body's top-level keys when a 200 has drifted out of recognition, or
    /// nil when the response is merely empty.
    ///
    /// Both halves of the test are needed. All-nil on its own is not drift: an
    /// account with nothing to report can legitimately return
    /// `"five_hour": null`, and failing that would be worse than the silence it
    /// replaces. Requiring the raw keys to be *disjoint* from the expected set
    /// separates "the windows are empty" from "the windows are called something
    /// else now", and only the second is a Tokenmax problem.
    ///
    /// Static and pure so the decision can be tested without a network stub.
    static func driftedKeys(_ decoded: OAuthUsageResponse, data: Data) -> [String]? {
        guard decoded.fiveHour == nil,
              decoded.sevenDay == nil,
              decoded.sevenDayOpus == nil,
              decoded.sevenDaySonnet == nil
        else { return nil }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        let known: Set<String> = [
            "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "extra_usage",
            "iguana_necktie", "cinder_cove", "cedar_ember",
        ]

        // A window key that is present and not null yet decoded to nothing is a
        // block this app can no longer read, however familiar its name. Without
        // this a retyped `five_hour` — the only window — would pass as an
        // account with nothing to report.
        let windowKeys = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        let unreadable = windowKeys.filter { key in
            guard let value = object?[key] else { return false }
            return !(value is NSNull)
        }
        if !unreadable.isEmpty { return unreadable }

        guard !keys.isEmpty, keys.isDisjoint(with: known) else { return nil }
        return keys.sorted()
    }
}
