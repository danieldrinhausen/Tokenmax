import Foundation

/// Decoded shape of `GET https://api.anthropic.com/api/oauth/usage`.
struct OAuthUsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        /// 0–100.
        let utilization: Double?
        let resetsAt: Date?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)

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

        init(utilization: Double?, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
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

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let extraUsage: ExtraUsage?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
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
    case badStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited: "Anthropic rate-limited the usage request."
        case .unauthorized: "Claude Code needs to be re-authenticated."
        case let .badStatus(code): "Usage request failed with HTTP \(code)."
        case let .transport(message): message
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

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
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
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            throw UsageClientError.rateLimited
        default:
            throw UsageClientError.badStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        let fetchedAt = now()
        cached = (decoded, fetchedAt)
        Log.shared.write("usage: ok five_hour=\(decoded.fiveHour?.utilization ?? -1) seven_day=\(decoded.sevenDay?.utilization ?? -1)")
        return (decoded, fetchedAt)
    }
}
