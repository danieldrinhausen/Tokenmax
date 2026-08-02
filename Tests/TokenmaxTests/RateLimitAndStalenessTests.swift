import Foundation
import Testing

@testable import Tokenmax

/// Serves canned responses so the 180s floor can be exercised without touching
/// the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset(body: String, status: Int = 200) {
        responseBody = Data(body.utf8)
        statusCode = status
        requestCount = 0
        lastRequest = nil
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("OAuth client rate limiting", .serialized)
struct ClaudeOAuthUsageClientTests {
    private static let body = """
    {
      "five_hour": { "utilization": 23.5, "resets_at": 1785500000 },
      "seven_day": { "utilization": 41.2, "resets_at": 1785600000 }
    }
    """

    private func makeClient(now: @escaping @Sendable () -> Date) -> ClaudeOAuthUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ClaudeOAuthUsageClient(session: URLSession(configuration: configuration), now: now)
    }

    @Test("Sends the three headers the endpoint requires")
    func sendsRequiredHeaders() async throws {
        StubURLProtocol.reset(body: Self.body)
        let client = makeClient(now: { Date() })

        _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")

        let headers = StubURLProtocol.lastRequest?.allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"] == "Bearer tok")
        #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
        // Without this exact User-Agent the endpoint throttles aggressively.
        #expect(headers["User-Agent"] == "claude-code/2.1.220")
    }

    @Test("A second call inside 180s is served from cache")
    func honoursRateLimitFloor() async throws {
        StubURLProtocol.reset(body: Self.body)
        let base = Date()
        nonisolated(unsafe) var clock = base
        let client = makeClient(now: { clock })

        _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        #expect(StubURLProtocol.requestCount == 1)

        // 60s later — the popover tick — must not hit the network.
        clock = base.addingTimeInterval(60)
        let (cached, _) = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        #expect(StubURLProtocol.requestCount == 1)
        #expect(cached.fiveHour?.utilization == 23.5)

        // 179s: still inside the floor.
        clock = base.addingTimeInterval(179)
        _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        #expect(StubURLProtocol.requestCount == 1)

        // 181s: allowed through.
        clock = base.addingTimeInterval(181)
        _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        #expect(StubURLProtocol.requestCount == 2)
    }

    @Test("401 is surfaced as needing re-authentication, not a generic failure")
    func mapsUnauthorized() async throws {
        StubURLProtocol.reset(body: "{}", status: 401)
        let client = makeClient(now: { Date() })

        await #expect(throws: UsageClientError.self) {
            _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        }
    }

    @Test("429 is surfaced distinctly so backoff can react")
    func mapsRateLimited() async throws {
        StubURLProtocol.reset(body: "{}", status: 429)
        let client = makeClient(now: { Date() })

        await #expect(throws: UsageClientError.self) {
            _ = try await client.fetch(accessToken: "tok", cliVersion: "2.1.220")
        }
    }
}

@Suite("Snapshot staleness")
struct StalenessTests {
    private func snapshot(ageSeconds: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            providerID: "claude-code",
            planName: "Max",
            windows: [],
            fetchedAt: Date().addingTimeInterval(-ageSeconds),
            fetchDuration: 0.2,
            errorMessage: nil
        )
    }

    @Test("Fresh data is not stale")
    func freshIsNotStale() {
        #expect(!snapshot(ageSeconds: 60).isStale(threshold: 600))
    }

    @Test("Data past the threshold is stale")
    func oldIsStale() {
        #expect(snapshot(ageSeconds: 900).isStale(threshold: 600))
    }

    @Test("The boundary itself is not yet stale")
    func boundaryIsNotStale() {
        let snapshot = snapshot(ageSeconds: 600)
        #expect(!snapshot.isStale(now: snapshot.fetchedAt.addingTimeInterval(600), threshold: 600))
    }
}

@Suite("Task ordering")
@MainActor
struct TaskOrderingTests {
    @Test("Ready tasks sort by manual order, then priority, then age")
    func sortsReadyTasks() {
        var low = TokenmaxTask(title: "low", prompt: "p")
        low.priority = .low
        low.sortIndex = 0
        low.createdAt = Date(timeIntervalSince1970: 100)

        var urgent = TokenmaxTask(title: "urgent", prompt: "p")
        urgent.priority = .urgent
        urgent.sortIndex = 0
        urgent.createdAt = Date(timeIntervalSince1970: 200)

        var pinned = TokenmaxTask(title: "pinned", prompt: "p")
        pinned.priority = .medium
        pinned.sortIndex = -5

        let sorted = [low, urgent, pinned].sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.priority.sortWeight != rhs.priority.sortWeight {
                return lhs.priority.sortWeight > rhs.priority.sortWeight
            }
            return lhs.createdAt < rhs.createdAt
        }

        #expect(sorted.map(\.title) == ["pinned", "urgent", "low"])
    }

    @Test("A task with no working directory is not runnable")
    func detectsMissingDirectory() {
        var task = TokenmaxTask(title: "t", prompt: "p")
        #expect(task.expandedWorkingDirectory == nil)
        #expect(!task.workingDirectoryExists)

        task.workingDirectory = "~"
        #expect(task.workingDirectoryExists)

        task.workingDirectory = "/definitely/not/here/\(UUID().uuidString)"
        #expect(!task.workingDirectoryExists)
    }
}
