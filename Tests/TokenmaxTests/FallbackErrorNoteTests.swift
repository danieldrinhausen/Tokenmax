import Foundation
import Testing

@testable import Tokenmax

/// When the account endpoint fails but the status line has a reading, the
/// failure used to vanish: the reading was good, so nothing said the primary
/// source was refusing. It is recorded on the reading now.
@Suite("Primary failure noted beside a fallback reading")
struct FallbackErrorNoteTests {
    private func statusline() throws -> @Sendable () -> (StatuslinePayload, Date)? {
        let payload = try JSONDecoder().decode(
            StatuslinePayload.self,
            from: Data(#"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":4000000000}}}"#.utf8)
        )
        let observedAt = Date().addingTimeInterval(-60)
        return { (payload, observedAt) }
    }

    private func provider(
        _ replies: [ScriptedURLProtocol.Reply], statusline: (@Sendable () -> (StatuslinePayload, Date)?)?
    ) -> ClaudeCodeProvider {
        let (session, _) = ScriptedURLProtocol.session(replies)
        return ClaudeCodeProvider(
            client: ClaudeOAuthUsageClient(session: session),
            readStatusline: statusline ?? { nil },
            readCredentials: {
                ClaudeKeychain.Credentials(
                    accessToken: "t", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600),
                    subscriptionType: "pro"
                )
            },
            cliInstalled: { true },
            cliVersion: { "2.1.220" },
            dataSource: { .keychain }
        )
    }

    @Test("A 403 hidden behind a statusline reading is recorded on the reading")
    func forbiddenIsRecorded() async throws {
        let usage = try await provider([.http(status: 403)], statusline: statusline()).fetchUsage()

        #expect(usage.windows.first?.source == .statusline)
        let note = try #require(usage.errorMessage)
        #expect(note.contains("403"))
        #expect(note.contains("status line"))
    }

    @Test("A 429 is recorded too")
    func rateLimitIsRecorded() async throws {
        let usage = try await provider([.http(status: 429)], statusline: statusline()).fetchUsage()
        #expect(usage.errorMessage?.contains("rate-limited") == true)
    }

    @Test("A healthy account reading carries no note, even with a statusline file beside it")
    func healthyReadingHasNoNote() async throws {
        let body = #"{"five_hour":{"utilization":10,"resets_at":4000000000}}"#
        let usage = try await provider([.http(status: 200, body: body)], statusline: statusline()).fetchUsage()
        #expect(usage.errorMessage == nil)
    }

    @Test("Waiting out the request floor is not a failure and leaves no note")
    func floorWaitIsNotNoted() {
        #expect(ClaudeCodeProvider.fallbackNote(for: UsageClientError.withinFloor(until: Date())) == nil)
        #expect(ClaudeCodeProvider.fallbackNote(for: UsageClientError.rateLimited) != nil)
    }

    @Test("Statusline-only mode has no primary source, so nothing to note")
    func statuslineOnlyHasNoNote() async throws {
        let (session, script) = ScriptedURLProtocol.session([.http(status: 403)])
        let provider = ClaudeCodeProvider(
            client: ClaudeOAuthUsageClient(session: session),
            readStatusline: try statusline(),
            readCredentials: { throw ClaudeKeychain.KeychainError.suppressedUnderTest },
            cliInstalled: { true },
            cliVersion: { "2.1.220" },
            dataSource: { .statuslineOnly }
        )
        let usage = try await provider.fetchUsage()
        #expect(usage.errorMessage == nil)
        #expect(script.requestCount == 0)
    }

    @Test("The note is carried onto the snapshot the popover shows")
    @MainActor
    func noteReachesTheSnapshot() async throws {
        let coordinator = UsageRefreshCoordinator(
            provider: provider([.http(status: 403)], statusline: try statusline()),
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )
        await coordinator.refresh(reason: "test")

        guard case let .loaded(snapshot) = coordinator.state else { Issue.record("got \(coordinator.state)"); return }
        #expect(snapshot.errorMessage?.contains("403") == true)
    }
}
