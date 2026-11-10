import Foundation
import Testing

@testable import Tokenmax

/// The OAuth client's request floor: what it replays, what it repeats, what it
/// remembers across a relaunch, and which failures leave it unarmed. The 180s
/// itself is pinned in `ClaudeOAuthUsageClientTests`.
@Suite("Usage request floor")
struct UsageRequestFloorTests {
    private static let ok = """
    { "five_hour": { "utilization": 23.5, "resets_at": 1785500000 } }
    """
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func clock() -> (@Sendable () -> Date, @Sendable (TimeInterval) -> Void) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var offset: TimeInterval = 0
        }
        let box = Box()
        let start = base
        return (
            { box.lock.withLock { start.addingTimeInterval(box.offset) } },
            { value in box.lock.withLock { box.offset = value } }
        )
    }

    private func fetch(_ client: ClaudeOAuthUsageClient) async throws -> OAuthUsageResponse {
        try await client.fetch(accessToken: "tok", cliVersion: "2.1.220").0
    }

    private func floorFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("floor-\(UUID().uuidString).json")
    }

    // MARK: - Replay after a failure

    /// The bug: after a failed request, a call inside the floor returned the
    /// older cached success, so the coordinator reset its failure streak and
    /// showed "loaded" over a 429 that was still in force.
    @Test("Inside the floor after a failed request the failure is repeated, not an older success replayed")
    func failureIsNotMaskedByTheCache() async throws {
        let (session, script) = ScriptedURLProtocol.session([
            .http(status: 200, body: Self.ok), .http(status: 429),
        ])
        let (now, advance) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        _ = try await fetch(client)
        advance(181)
        await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
        advance(240)
        do {
            _ = try await fetch(client)
            Issue.record("the cached success was replayed over a 429")
        } catch let error as UsageClientError {
            guard case .rateLimited = error else { Issue.record("got \(error)"); return }
        }
        #expect(script.requestCount == 2)
    }

    @Test("Inside the floor after a success the cache is still replayed")
    func successStillReplays() async throws {
        let (session, script) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        let (now, advance) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        _ = try await fetch(client)
        advance(60)
        let replay = try await fetch(client)

        #expect(replay.fiveHour?.utilization == 23.5)
        #expect(script.requestCount == 1)
    }

    @Test("A success after a failure clears it, so the next replay is a success again")
    func recoveryClearsTheFailure() async throws {
        let (session, _) = ScriptedURLProtocol.session([.http(status: 500), .http(status: 200, body: Self.ok)])
        let (now, advance) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
        advance(181)
        _ = try await fetch(client)
        advance(200)
        #expect(try await fetch(client).fiveHour?.utilization == 23.5)
    }

    // MARK: - Retry-After

    @Test("A Retry-After longer than the floor holds the next request back for that long")
    func retryAfterLengthensTheFloor() async throws {
        let (session, script) = ScriptedURLProtocol.session([
            .http(status: 429, headers: ["Retry-After": "600"]), .http(status: 200, body: Self.ok),
        ])
        let (now, advance) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
        #expect(await client.nextRequestAllowedAt == base.addingTimeInterval(600))

        advance(300)
        await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
        #expect(script.requestCount == 1)

        advance(601)
        _ = try await fetch(client)
        #expect(script.requestCount == 2)
    }

    @Test("A Retry-After shorter than the floor never shortens it")
    func retryAfterNeverShortens() async throws {
        let (session, _) = ScriptedURLProtocol.session([.http(status: 429, headers: ["Retry-After": "5"])])
        let (now, _) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
        #expect(await client.nextRequestAllowedAt == base.addingTimeInterval(180))
    }

    @Test("Retry-After is read as seconds or an HTTP-date, capped, and ignored when unreadable or negative")
    func retryAfterParsing() {
        #expect(UsageRequestFloor.retryAfterDeadline(header: "120", now: base) == base.addingTimeInterval(120))
        #expect(UsageRequestFloor.retryAfterDeadline(header: "999999", now: base)
            == base.addingTimeInterval(UsageRequestFloor.maximumRetryAfter))
        #expect(UsageRequestFloor.retryAfterDeadline(header: "-5", now: base) == nil)
        #expect(UsageRequestFloor.retryAfterDeadline(header: "soon", now: base) == nil)
        #expect(UsageRequestFloor.retryAfterDeadline(header: nil, now: base) == nil)
        #expect(UsageRequestFloor.retryAfterDeadline(header: "", now: base) == nil)

        // 1_800_000_000 is Fri, 15 Jan 2027 08:00:00 GMT.
        let date = UsageRequestFloor.retryAfterDeadline(header: "Fri, 15 Jan 2027 08:05:00 GMT", now: base)
        #expect(date == base.addingTimeInterval(300))
        let past = UsageRequestFloor.retryAfterDeadline(header: "Fri, 15 Jan 2027 07:00:00 GMT", now: base)
        #expect((past ?? base.addingTimeInterval(1)) <= base)
    }

    // MARK: - Requests that never left the machine

    @Test("A request that never reached the network leaves the floor unarmed")
    func neverSentDoesNotArm() async throws {
        for code in [URLError.Code.notConnectedToInternet, .dnsLookupFailed, .cannotFindHost] {
            let (session, script) = ScriptedURLProtocol.session([.failure(code), .http(status: 200, body: Self.ok)])
            let (now, _) = clock()
            let client = ClaudeOAuthUsageClient(session: session, now: now)

            await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
            #expect(await client.nextRequestAllowedAt == .distantPast)
            _ = try await fetch(client)
            #expect(script.requestCount == 2)
        }
    }

    @Test("A timeout or a reset connection may have reached the server, so the floor stays armed")
    func mayHaveBeenSentArms() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed] {
            let (session, script) = ScriptedURLProtocol.session([.failure(code), .http(status: 200, body: Self.ok)])
            let (now, advance) = clock()
            let client = ClaudeOAuthUsageClient(session: session, now: now)

            await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
            #expect(await client.nextRequestAllowedAt == base.addingTimeInterval(180))
            advance(30)
            await #expect(throws: UsageClientError.self) { _ = try await fetch(client) }
            #expect(script.requestCount == 1)
        }
    }

    @Test("Only the three provably-unsent errors count as never reaching the server")
    func neverReachedClassification() {
        #expect(ClaudeOAuthUsageClient.neverReachedServer(URLError(.notConnectedToInternet)))
        #expect(ClaudeOAuthUsageClient.neverReachedServer(URLError(.dnsLookupFailed)))
        #expect(ClaudeOAuthUsageClient.neverReachedServer(URLError(.cannotFindHost)))
        #expect(!ClaudeOAuthUsageClient.neverReachedServer(URLError(.timedOut)))
        #expect(!ClaudeOAuthUsageClient.neverReachedServer(URLError(.networkConnectionLost)))
        #expect(!ClaudeOAuthUsageClient.neverReachedServer(URLError(.cannotConnectToHost)))
        #expect(!ClaudeOAuthUsageClient.neverReachedServer(URLError(.cancelled)))
        #expect(!ClaudeOAuthUsageClient.neverReachedServer(UsageClientError.rateLimited))
    }

    @Test("A cancelled request is handed up as a cancellation and keeps the floor armed")
    func cancelledKeepsFloor() async {
        let (session, _) = ScriptedURLProtocol.session([.failure(.cancelled)])
        let (now, _) = clock()
        let client = ClaudeOAuthUsageClient(session: session, now: now)

        do {
            _ = try await fetch(client)
            Issue.record("expected a throw")
        } catch {
            #expect(error.isCancellation)
        }
        #expect(await client.nextRequestAllowedAt == base.addingTimeInterval(180))
    }

    // MARK: - Across a relaunch

    @Test("A relaunch inside the floor does not call the endpoint and says the floor is running")
    func floorSurvivesRelaunch() async throws {
        let file = floorFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (first, firstScript) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        let (now, advance) = clock()

        _ = try await fetch(ClaudeOAuthUsageClient(session: first, floorFile: file, now: now))
        advance(40)

        let (second, secondScript) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        let relaunched = ClaudeOAuthUsageClient(session: second, floorFile: file, now: now)
        do {
            _ = try await fetch(relaunched)
            Issue.record("a request was made inside the persisted floor")
        } catch let error as UsageClientError {
            guard case let .withinFloor(until) = error else { Issue.record("got \(error)"); return }
            #expect(until == base.addingTimeInterval(180))
        }
        #expect(firstScript.requestCount == 1)
        #expect(secondScript.requestCount == 0)

        advance(181)
        _ = try await fetch(relaunched)
        #expect(secondScript.requestCount == 1)
    }

    @Test("A persisted Retry-After outlives the relaunch")
    func retryAfterSurvivesRelaunch() async throws {
        let file = floorFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (first, _) = ScriptedURLProtocol.session([.http(status: 429, headers: ["Retry-After": "900"])])
        let (now, _) = clock()
        await #expect(throws: UsageClientError.self) {
            _ = try await fetch(ClaudeOAuthUsageClient(session: first, floorFile: file, now: now))
        }

        let (second, _) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        let relaunched = ClaudeOAuthUsageClient(session: second, floorFile: file, now: now)
        #expect(await relaunched.nextRequestAllowedAt == base.addingTimeInterval(900))
    }

    @Test("An old, corrupt, empty or future-dated floor file never blocks the endpoint")
    func badFloorFilesAreHarmless() async throws {
        let (now, _) = clock()
        let cases: [String] = [
            "not json at all",
            "{}",
            #"{ "lastRequestAt": "2020-01-01T00:00:00Z" }"#,
            #"{ "lastRequestAt": 5 }"#,
        ]
        for contents in cases {
            let file = floorFile()
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(contents.utf8).write(to: file)
            let (session, script) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
            _ = try await fetch(ClaudeOAuthUsageClient(session: session, floorFile: file, now: now))
            #expect(script.requestCount == 1)
        }
    }

    @Test("A floor dated in the future is treated as made now, and a huge wait is capped")
    func sanitisesTheClock() {
        let floor = UsageRequestFloor(
            lastRequestAt: base.addingTimeInterval(86400),
            retryAfterUntil: base.addingTimeInterval(86400 * 30)
        ).sanitised(now: base)

        #expect(floor.lastRequestAt == base)
        #expect(floor.retryAfterUntil == base.addingTimeInterval(UsageRequestFloor.maximumRetryAfter))
        #expect(UsageRequestFloor(retryAfterUntil: base.addingTimeInterval(-5)).sanitised(now: base).retryAfterUntil == nil)
    }

    @Test("Without a floor file nothing is persisted, so tests cannot leak a floor into each other")
    func inMemoryByDefault() async throws {
        let (session, _) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        let (now, _) = clock()
        _ = try await fetch(ClaudeOAuthUsageClient(session: session, now: now))

        let (other, script) = ScriptedURLProtocol.session([.http(status: 200, body: Self.ok)])
        _ = try await fetch(ClaudeOAuthUsageClient(session: other, now: now))
        #expect(script.requestCount == 1)
    }
}

@Suite("Refresh backoff")
struct RefreshBackoffTests {
    @Test("The backoff steps 30, 60, 120, 300 seconds and stays at 300")
    func schedule() {
        #expect((1...6).map { RefreshBackoff.delay(afterConsecutiveFailures: $0) } == [30, 60, 120, 300, 300, 300])
        #expect(RefreshBackoff.delay(afterConsecutiveFailures: 0) == 30)
    }

    @Test("The retry waits out the longer of the backoff and the request floor, plus a margin")
    func retryDelay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RefreshBackoff.retryDelay(backoff: 30, floorEndsAt: nil, now: now) == 31)
        #expect(RefreshBackoff.retryDelay(backoff: 30, floorEndsAt: now.addingTimeInterval(150), now: now) == 151)
        #expect(RefreshBackoff.retryDelay(backoff: 120, floorEndsAt: now.addingTimeInterval(10), now: now) == 121)
        #expect(RefreshBackoff.retryDelay(backoff: 30, floorEndsAt: now.addingTimeInterval(-50), now: now) == 31)
        #expect(RefreshBackoff.retryDelay(backoff: 0, floorEndsAt: now.addingTimeInterval(40), now: now) == 41)
    }

    @Test("Only a failure that clears by itself is retried; a refusal, a missing install or a sign-in is not")
    func retryable() {
        #expect(RefreshBackoff.isRetryable(ProviderError.underlying("offline")))
        #expect(RefreshBackoff.isRetryable(URLError(.timedOut)))
        #expect(!RefreshBackoff.isRetryable(ProviderError.accessDenied))
        #expect(!RefreshBackoff.isRetryable(ProviderError.notAuthenticated("Claude Code")))
        #expect(!RefreshBackoff.isRetryable(ProviderError.notInstalled("Claude Code")))
        #expect(!RefreshBackoff.isRetryable(ProviderError.needsReauthentication))
        #expect(!RefreshBackoff.isRetryable(ProviderError.tokenExpired))
        #expect(!RefreshBackoff.isRetryable(ProviderError.apiKeyConfigured("Claude Code")))
    }
}
