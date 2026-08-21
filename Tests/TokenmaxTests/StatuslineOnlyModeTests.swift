import Foundation
import Testing

@testable import Tokenmax

/// The rule these guard: statusline-only mode promises "Tokenmax never touches
/// the keychain", and a promise like that is only worth making if a test fails
/// the moment any path quietly falls back to a credential read.
@Suite("Statusline-only data source")
struct StatuslineOnlyModeTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock(); value += 1; lock.unlock()
        }
    }

    private let observedAt = Date(timeIntervalSince1970: 1_785_500_000)

    private func payload() throws -> StatuslinePayload {
        try JSONDecoder().decode(StatuslinePayload.self, from: Data("""
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 42, "resets_at": 1785510000 },
            "seven_day": { "used_percentage": 61, "resets_at": 1785900000 }
          }
        }
        """.utf8))
    }

    private func makeProvider(
        statusline: @escaping @Sendable () -> (StatuslinePayload, Date)?,
        keychainReads: Counter
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            readStatusline: statusline,
            readCredentials: {
                keychainReads.increment()
                throw ClaudeKeychain.KeychainError.suppressedUnderTest
            },
            cliInstalled: { true },
            cliVersion: { "2.1.220" },
            dataSource: { .statuslineOnly }
        )
    }

    // MARK: - The promise

    @Test("Fetching usage never reads the keychain in statusline-only mode")
    func fetchNeverReadsKeychain() async throws {
        let reads = Counter()
        let payload = try payload()
        let provider = makeProvider(
            statusline: { (payload, self.observedAt) },
            keychainReads: reads
        )

        let usage = try await provider.fetchUsage()

        #expect(reads.count == 0)
        #expect(usage.windows.count == 2)
        #expect(usage.windows.allSatisfy { $0.source == .statusline })
        #expect(usage.windows.allSatisfy { $0.confidence == .observed })
    }

    /// The tempting bug: no payload yet, so read the keychain "just this once".
    /// That once is a consent dialog, which is the whole thing the mode exists
    /// to remove.
    @Test("A missing payload is its own error, not a reason to read the keychain")
    func missingPayloadDoesNotFallBack() async throws {
        let reads = Counter()
        let provider = makeProvider(statusline: { nil }, keychainReads: reads)

        await #expect(throws: ProviderError.statuslineNoData) {
            _ = try await provider.fetchUsage()
        }
        #expect(reads.count == 0)
    }

    @Test("The authentication check never reads the keychain in statusline-only mode")
    func authCheckNeverReadsKeychain() async throws {
        let reads = Counter()
        let provider = makeProvider(statusline: { nil }, keychainReads: reads)

        _ = await provider.checkAuthentication()

        #expect(reads.count == 0)
    }

    // MARK: - Honest absences

    /// What the status line cannot carry must stay unknown, not be guessed.
    /// `extraUsageEnabled == nil` in particular: the automation guard reads
    /// unknown as "do not spend", and a fabricated `false` would wave a
    /// billable run through.
    @Test("Plan name and the usage-credit flag stay unknown, never guessed")
    func absentFieldsStayUnknown() async throws {
        let reads = Counter()
        let payload = try payload()
        let provider = makeProvider(
            statusline: { (payload, self.observedAt) },
            keychainReads: reads
        )

        let usage = try await provider.fetchUsage()

        #expect(usage.planName == nil)
        #expect(usage.extraUsageEnabled == nil)
    }

    /// Statusline data is only as fresh as the last session response, and the
    /// staleness machinery keys off `fetchedAt`. Stamping it with `Date()`
    /// would make an hours-old reading render as current.
    @Test("fetchedAt is the file's observation time, not the moment of asking")
    func fetchedAtIsObservationTime() async throws {
        let payload = try payload()
        let provider = makeProvider(
            statusline: { (payload, self.observedAt) },
            keychainReads: Counter()
        )

        #expect(try await provider.fetchUsage().fetchedAt == observedAt)
    }

    // MARK: - The side door

    /// The model catalog uses the same keychain token as usage. Left unguarded
    /// it would reintroduce the consent dialog through a path nobody thinks of
    /// as "usage monitoring" — the task editor appearing on screen.
    @Test("The model catalog refuses to fetch in statusline-only mode")
    @MainActor
    func modelCatalogRefusesToFetch() async {
        let reads = Counter()
        let store = ModelCatalogStore(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("statusline-only-catalog-\(UUID().uuidString).json"),
            loadCredentials: {
                reads.increment()
                throw ClaudeKeychain.KeychainError.suppressedUnderTest
            },
            dataSource: { .statuslineOnly }
        )

        // Even the forced path — the Settings button — must refuse.
        await store.refresh(force: true)

        #expect(reads.count == 0)
        #expect(store.lastError == nil)
    }

    /// The negative: keychain mode still fetches, so the guard above is the
    /// mode's doing and not a dead catalog.
    @Test("The model catalog still asks for credentials in keychain mode")
    @MainActor
    func modelCatalogStillFetchesInKeychainMode() async {
        let reads = Counter()
        let store = ModelCatalogStore(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("keychain-catalog-\(UUID().uuidString).json"),
            loadCredentials: {
                reads.increment()
                throw ClaudeKeychain.KeychainError.suppressedUnderTest
            },
            dataSource: { .keychain }
        )

        await store.refresh(force: true)

        #expect(reads.count == 1)
    }
}
