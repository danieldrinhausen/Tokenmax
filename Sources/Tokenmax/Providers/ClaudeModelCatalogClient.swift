import Foundation

/// Fetches the list of models the account can actually use.
///
/// Exists so a newly released model appears in the task editor without shipping
/// a new build of Tokenmax. The endpoint is documented for API keys, but it also
/// accepts the OAuth token Claude Code already stores — verified against a live
/// subscription account, which is the only reason this design is viable.
///
/// Two headers matter, and only one of them is required:
///
/// 1. `anthropic-version: 2023-06-01` — **required**. Without it the request is
///    a 400, not a 401, so a missing version reads as a malformed request rather
///    than an auth problem.
/// 2. `User-Agent: claude-code/<version>` — not required here, but sent for the
///    same reason `ClaudeOAuthUsageClient` sends it: an unrecognised agent lands
///    in a more aggressively rate-limited bucket.
///
/// The floor here is hours rather than the usage client's 180 seconds. Model
/// lists change a few times a year; polling them like a quota meter would be
/// pure waste.
actor ClaudeModelCatalogClient {
    /// Long by design — see the type comment. A manual refresh in Settings
    /// bypasses it via `force`.
    static let minimumRequestInterval: TimeInterval = 6 * 60 * 60

    private let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
    private let session: URLSession
    private let now: @Sendable () -> Date

    private var lastRequestAt: Date?

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    /// `force` skips the request floor, for the explicit "Refresh" button.
    /// Nothing else may set it — an automatic caller that bypasses the floor is
    /// how a once-a-year list turns into a per-tick request.
    func fetch(accessToken: String, cliVersion: String, force: Bool = false) async throws -> ModelCatalog {
        let current = now()

        if !force, let lastRequestAt,
           current.timeIntervalSince(lastRequestAt) < Self.minimumRequestInterval {
            throw UsageClientError.rateLimited
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        lastRequestAt = current
        Log.shared.write("models: outbound request")

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
        case 200: break
        case 401, 403: throw UsageClientError.unauthorized
        case 429: throw UsageClientError.rateLimited
        default: throw UsageClientError.badStatus(http.statusCode)
        }

        let decoded = try Self.makeDecoder().decode(ModelsResponse.self, from: data)
        let models = decoded.data.map {
            CatalogModel(
                id: $0.id,
                displayName: $0.displayName ?? $0.id,
                createdAt: $0.createdAt,
                effortLevels: $0.capabilities?.effort?.supportedLevels ?? []
            )
        }

        Log.shared.write("models: ok (\(models.count) models)")
        return ModelCatalog(models: models, fetchedAt: now())
    }

    /// `created_at` is ISO-8601 and the keys are snake_case, neither of which
    /// matches `JSONStore.makeDecoder()`'s configuration for our own files.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
