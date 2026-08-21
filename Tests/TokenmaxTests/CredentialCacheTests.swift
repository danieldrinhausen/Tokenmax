import Foundation
import Testing

@testable import Tokenmax

/// The rule these guard: reading the Claude credentials can raise a consent
/// dialog, so the app must ask macOS as few times as it can get away with —
/// without ever holding on to an answer it should not have kept.
@Suite("Claude credential cache")
struct CredentialCacheTests {
    private final class ReadCounter: @unchecked Sendable {
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

    private func credentials(
        token: String = "tok",
        expiresIn: TimeInterval? = 3600
    ) -> ClaudeKeychain.Credentials {
        ClaudeKeychain.Credentials(
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            subscriptionType: "pro"
        )
    }

    @Test("A second caller is served from memory, not from the keychain")
    func servesRepeatCallersFromMemory() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            return self.credentials()
        })

        for _ in 0 ..< 10 { _ = try cache.credentials() }

        #expect(reads.count == 1)
    }

    /// The whole point: the usage refresh and the model catalog are two objects
    /// that each want credentials, and they must cost one dialog between them.
    @Test("Independent callers share one read")
    func sharesOneReadAcrossCallers() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            return self.credentials()
        })
        let usage: @Sendable () throws -> ClaudeKeychain.Credentials = { try cache.credentials() }
        let catalog: @Sendable () throws -> ClaudeKeychain.Credentials = { try cache.credentials() }

        _ = try usage()
        _ = try catalog()

        #expect(reads.count == 1)
    }

    @Test("A token past its expiry is re-read rather than handed out")
    func rereadsExpiredToken() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            return self.credentials(token: "token-\(reads.count)", expiresIn: -1)
        })

        _ = try cache.credentials()
        let second = try cache.credentials()

        #expect(reads.count == 2)
        #expect(second.accessToken == "token-2")
    }

    /// Claude Code rotates the token in place. A 401 is the only reliable
    /// evidence of it, and the provider answers by dropping the cache.
    @Test("Invalidating sends the next caller back to the keychain")
    func invalidateForcesReread() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            return self.credentials(token: "token-\(reads.count)")
        })

        _ = try cache.credentials()
        cache.invalidate()
        let after = try cache.credentials()

        #expect(reads.count == 2)
        #expect(after.accessToken == "token-2")
    }

    /// A denial *is* a decision — the user answered the dialog. Re-asking on
    /// the next tick turned one *Deny* into a dialog every five minutes for as
    /// long as the app ran, which is the app arguing with the user.
    @Test("An explicit denial is remembered, not re-asked every tick")
    func remembersDenial() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            throw ClaudeKeychain.KeychainError.accessDenied
        })

        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

        #expect(reads.count == 1)
    }

    /// The way back from a denial is the user's own click, not a relaunch: the
    /// retry drops the memory so macOS may raise the dialog again.
    @Test("Retrying after a denial asks the keychain again")
    func retryAfterDenialRereads() throws {
        let reads = ReadCounter()
        let outcome = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            guard outcome.count > 0 else { throw ClaudeKeychain.KeychainError.accessDenied }
            return self.credentials()
        })

        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        outcome.increment()
        // Without the retry the denial would still be replayed.
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

        cache.retryAfterDenial()

        #expect(try cache.credentials().accessToken == "tok")
        #expect(reads.count == 2)
    }

    @Test("Invalidating clears a remembered denial too")
    func invalidateClearsDenial() throws {
        let reads = ReadCounter()
        let outcome = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            guard outcome.count > 0 else { throw ClaudeKeychain.KeychainError.accessDenied }
            return self.credentials()
        })

        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        outcome.increment()
        cache.invalidate()

        #expect(try cache.credentials().accessToken == "tok")
        #expect(reads.count == 2)
    }

    /// Only an answered dialog is remembered. Everything else — a malformed
    /// payload, an unexpected status, a keychain that could not raise the
    /// dialog at all — stays transient and is retried on the next call.
    @Test("A non-denial failure is never cached")
    func nonDenialFailuresAreRetried() throws {
        for failure: ClaudeKeychain.KeychainError in [
            .malformed, .unexpected(-25293), .interactionNotAllowed,
        ] {
            let reads = ReadCounter()
            let cache = ClaudeCredentialCache(read: {
                reads.increment()
                throw failure
            })

            #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
            #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

            #expect(reads.count == 2, "\(failure) must be retried, not remembered")
        }
    }

    /// `notFound` is the state of a machine where Claude Code has not been
    /// logged into yet. Caching it would mean Tokenmax never notices the login.
    @Test("A missing item is retried on the next call")
    func retriesMissingItem() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            throw ClaudeKeychain.KeychainError.notFound
        })

        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

        #expect(reads.count == 2)
    }

    @Test("A token with no expiry stays cached")
    func keepsTokenWithoutExpiry() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            return self.credentials(expiresIn: nil)
        })

        _ = try cache.credentials()
        _ = try cache.credentials()

        #expect(reads.count == 1)
    }

    /// Expiry is checked against the cache's clock, not the wall clock, so the
    /// hand-out rule is testable at all.
    @Test("Expiry is judged by the injected clock")
    func honoursInjectedClock() throws {
        let reads = ReadCounter()
        let expiry = Date(timeIntervalSince1970: 1_000)
        let clock = ReadCounter()
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return ClaudeKeychain.Credentials(
                    accessToken: "tok",
                    refreshToken: nil,
                    expiresAt: expiry,
                    subscriptionType: nil
                )
            },
            now: { Date(timeIntervalSince1970: clock.count > 0 ? 2_000 : 500) }
        )

        _ = try cache.credentials()
        _ = try cache.credentials()
        #expect(reads.count == 1)

        // Move the clock past the expiry.
        clock.increment()
        _ = try cache.credentials()
        #expect(reads.count == 2)
    }
}
