import Foundation
import Testing

@testable import Tokenmax

@Suite("Provider freshness reporting")
struct ProviderFreshnessTests {
    private func credentials(expired: Bool = false) -> ClaudeKeychain.Credentials {
        ClaudeKeychain.Credentials(
            accessToken: "tok",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600),
            subscriptionType: "pro"
        )
    }

    private func makeProvider(
        session: URLSession,
        statusline: @escaping @Sendable () -> (StatuslinePayload, Date)? = { nil },
        credentials: @escaping @Sendable () throws -> ClaudeKeychain.Credentials
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            client: ClaudeOAuthUsageClient(session: session),
            readStatusline: statusline,
            readCredentials: credentials,
            cliInstalled: { true },
            cliVersion: { "2.1.220" }
        )
    }

    private func stubbedSession(body: String, status: Int = 200) -> URLSession {
        StubURLProtocol.reset(body: body, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The bug this guards: replaying a cached response must not reset the
    /// snapshot's age, or stale data renders as freshly fetched.
    @Test("fetchedAt reflects when data was observed, not when it was requested")
    func reportsObservedTime() async throws {
        let session = stubbedSession(body: """
        { "five_hour": { "utilization": 20, "resets_at": 1785500000 } }
        """)
        let provider = makeProvider(session: session, credentials: { self.credentials() })

        let usage = try await provider.fetchUsage()
        let observed = try #require(usage.windows.first?.observedAt)

        #expect(usage.fetchedAt == observed)
    }

    @Test("Plan name comes from the keychain subscription type")
    func reportsPlanName() async throws {
        let session = stubbedSession(body: """
        { "five_hour": { "utilization": 20, "resets_at": 1785500000 } }
        """)
        let provider = makeProvider(session: session, credentials: { self.credentials() })

        #expect(try await provider.fetchUsage().planName == "Pro")
    }

    @Test("A missing CLI is reported before any network call")
    func detectsMissingCLI() async {
        let provider = ClaudeCodeProvider(
            client: ClaudeOAuthUsageClient(session: stubbedSession(body: "{}")),
            readStatusline: { nil },
            readCredentials: { self.credentials() },
            cliInstalled: { false },
            cliVersion: { "2.1.220" }
        )

        await #expect(throws: ProviderError.self) { _ = try await provider.fetchUsage() }
        #expect(await provider.checkAuthentication() == .notInstalled)
    }

    @Test("An unauthenticated install is distinguished from a failed request")
    func detectsUnauthenticated() async {
        let provider = makeProvider(
            session: stubbedSession(body: "{}"),
            credentials: { throw ClaudeKeychain.KeychainError.notFound }
        )

        #expect(await provider.checkAuthentication() == .notAuthenticated)
    }

    @Test("Denied keychain consent gets its own state, not a generic error")
    func detectsAccessDenied() async {
        let provider = makeProvider(
            session: stubbedSession(body: "{}"),
            credentials: { throw ClaudeKeychain.KeychainError.accessDenied }
        )

        #expect(await provider.checkAuthentication() == .accessDenied)
    }

    /// A clock-expired token is only a hint. The endpoint may still accept it,
    /// and refusing to try could only ever turn a working request into an error.
    @Test("A locally-expired token is still tried against the endpoint")
    func expiredTokenIsStillAttempted() async throws {
        let session = stubbedSession(body: """
        { "five_hour": { "utilization": 20, "resets_at": 1785500000 } }
        """)
        let provider = makeProvider(
            session: session,
            credentials: { self.credentials(expired: true) }
        )

        let usage = try await provider.fetchUsage()
        #expect(usage.windows.count == 1)
    }

    /// The distinction that stops the app telling the user to sign in when
    /// Claude Code is about to fix this by itself.
    @Test("A rejected token with a refresh token is transient, not a sign-in")
    func rejectedTokenWithRefreshIsTransient() async {
        let provider = makeProvider(
            session: stubbedSession(body: "{}", status: 401),
            credentials: { self.credentials(expired: true) }
        )

        await #expect(throws: ProviderError.tokenExpired) {
            _ = try await provider.fetchUsage()
        }
    }

    @Test("A rejected token with nothing to refresh it does need a sign-in")
    func rejectedTokenWithoutRefreshNeedsSignIn() async {
        let provider = makeProvider(
            session: stubbedSession(body: "{}", status: 401),
            credentials: {
                ClaudeKeychain.Credentials(
                    accessToken: "tok",
                    refreshToken: nil,
                    expiresAt: Date().addingTimeInterval(-3600),
                    subscriptionType: "pro"
                )
            }
        )

        await #expect(throws: ProviderError.needsReauthentication) {
            _ = try await provider.fetchUsage()
        }
    }

    /// Blanking the popover to "Never updated" over a token that heals itself
    /// within minutes throws away the only data there is.
    @Test("A transient token expiry keeps the last good reading")
    func tokenExpiryPreservesLastGood() {
        let snapshot = UsageSnapshot(
            providerID: "claude-code",
            planName: "Pro",
            windows: [],
            fetchedAt: Date(),
            fetchDuration: 0.1,
            errorMessage: nil
        )

        #expect(UsageState.tokenExpired(lastGood: snapshot).snapshot != nil)
        // The hard case genuinely has nothing to show.
        #expect(UsageState.needsReauthentication.snapshot == nil)
    }

    @Test("Falls back to the statusline when the network call fails")
    func fallsBackToStatusline() async throws {
        let payload = try JSONDecoder().decode(
            StatuslinePayload.self,
            from: Data(#"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1785500000}}}"#.utf8)
        )
        let observedAt = Date().addingTimeInterval(-120)

        let provider = makeProvider(
            session: stubbedSession(body: "{}", status: 500),
            statusline: { (payload, observedAt) },
            credentials: { self.credentials() }
        )

        let usage = try await provider.fetchUsage()

        #expect(usage.windows.count == 1)
        #expect(usage.windows.first?.source == .statusline)
        #expect(usage.windows.first?.remainingPercent == 70)
    }

    @Test("With no source available at all, the error propagates")
    func propagatesWhenNoSourceWorks() async {
        let provider = makeProvider(
            session: stubbedSession(body: "{}", status: 500),
            credentials: { self.credentials() }
        )

        await #expect(throws: ProviderError.self) { _ = try await provider.fetchUsage() }
    }
}
