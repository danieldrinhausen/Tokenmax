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
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
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
        fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(Window.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
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

    static func fromString(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
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

    var errorDescription: String? {
        switch self {
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
    private var lastRequestAt: Date?

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
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
        guard let lastRequestAt else { return .distantPast }
        return lastRequestAt.addingTimeInterval(Self.minimumRequestInterval)
    }

    /// Returns cached data when called inside the 180s window.
    /// `force` still respects the floor — it only bypasses a *fresh* cache hit.
    func fetch(accessToken: String, cliVersion: String) async throws -> (OAuthUsageResponse, Date) {
        let current = now()

        if let lastRequestAt, current.timeIntervalSince(lastRequestAt) < Self.minimumRequestInterval {
            if let cached {
                Log.shared.write("usage: served from cache (\(Int(current.timeIntervalSince(cached.fetchedAt)))s old)")
                return (cached.response, cached.fetchedAt)
            }
            // Floor is active but we have nothing cached — surface it rather
            // than hammering the endpoint.
            throw UsageClientError.rateLimited
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        lastRequestAt = current
        Log.shared.write("usage: outbound request (ua=claude-code/\(cliVersion))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
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
            throw UsageClientError.rateLimited
        default:
            throw UsageClientError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
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

        guard !keys.isEmpty, keys.isDisjoint(with: known) else { return nil }
        return keys.sorted()
    }
}
