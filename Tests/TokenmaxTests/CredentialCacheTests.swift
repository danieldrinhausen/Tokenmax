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

    /// Launch can ask the usage provider and model catalog for credentials at
    /// the same time. A shared cache is not enough if both observe it empty
    /// before either read returns: that produces two stacked consent dialogs.
    @Test("Concurrent cache misses coalesce into one keychain read")
    func concurrentMissesCoalesce() {
        let reads = ReadCounter()
        let releaseRead = DispatchSemaphore(value: 0)
        let firstReadStarted = DispatchSemaphore(value: 0)
        let callers = DispatchGroup()
        let queue = DispatchQueue(label: "credential-cache-test", attributes: .concurrent)
        let cache = ClaudeCredentialCache(read: {
            reads.increment()
            firstReadStarted.signal()
            releaseRead.wait()
            return self.credentials()
        })

        callers.enter()
        queue.async {
            _ = try? cache.credentials()
            callers.leave()
        }
        #expect(firstReadStarted.wait(timeout: .now() + 1) == .success)

        callers.enter()
        queue.async {
            _ = try? cache.credentials()
            callers.leave()
        }

        // Two signals keep the old, broken implementation from deadlocking:
        // it starts two reads; the fixed implementation consumes only one.
        releaseRead.signal()
        releaseRead.signal()
        #expect(callers.wait(timeout: .now() + 1) == .success)
        #expect(reads.count == 1)
    }

    /// `manual` also means "force a network refresh" to the unattended opener
    /// and post-run verifier. That must not be mistaken for a user's request to
    /// reopen an answered consent dialog.
    @Test("A forced refresh retries a denial only when the user requested it")
    @MainActor
    func forcedRefreshDoesNotForgiveDenial() async {
        let retries = ReadCounter()
        let provider = ClaudeCodeProvider(
            readCredentials: { throw ClaudeKeychain.KeychainError.accessDenied },
            retryDeniedAccess: { retries.increment() },
            cliInstalled: { true },
            dataSource: { .keychain }
        )
        let coordinator = UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("denial-retry-\(UUID().uuidString).json")
        )

        await coordinator.refresh(reason: "automatic verifier", manual: true)
        #expect(retries.count == 0)

        await coordinator.refresh(
            reason: "refresh button",
            manual: true,
            retryDeniedKeychainAccess: true
        )
        #expect(retries.count == 1)
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

    /// The loop this closes, measured over a fortnight of real use: 64 of 176
    /// keychain reads were a rejected token being re-read every five minutes,
    /// stacking consent dialogs minutes apart. Until Claude Code writes the
    /// item, the keychain holds the same token the endpoint just refused, so
    /// the read can only cost a dialog and return nothing new.
    @Test("A rejected token is not re-read until Claude Code rewrites the item")
    func waitsForRotationBeforeRereading() throws {
        let reads = ReadCounter()
        let written = Date(timeIntervalSince1970: 1_000)
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return self.credentials(token: "token-\(reads.count)")
            },
            itemModified: { written }
        )

        _ = try cache.credentials()
        cache.invalidate()

        for _ in 0 ..< 10 {
            #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        }
        #expect(reads.count == 1, "the item never changed, so nothing new could be read")
    }

    /// The other half: once the timestamp moves, the wait is over immediately.
    @Test("A rewritten item ends the wait and is read once")
    func rereadsOnceTheItemChanges() throws {
        let reads = ReadCounter()
        let rotations = ReadCounter()
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return self.credentials(token: "token-\(reads.count)")
            },
            itemModified: { Date(timeIntervalSince1970: rotations.count > 0 ? 2_000 : 1_000) }
        )

        _ = try cache.credentials()
        cache.invalidate()
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

        rotations.increment()
        #expect(try cache.credentials().accessToken == "token-2")
        // And the fresh token is then served from memory, not re-read.
        #expect(try cache.credentials().accessToken == "token-2")
        #expect(reads.count == 2)
    }

    /// The distinction the caller needs while waiting: a token with a refresh
    /// token is one Claude Code renews by itself, and telling the user to sign
    /// in again would send them through an OAuth flow they did not need.
    @Test("The wait reports whether the rejected token could renew itself")
    func reportsSelfRenewalWhileWaiting() throws {
        for canSelfRenew in [true, false] {
            let cache = ClaudeCredentialCache(
                read: {
                    ClaudeKeychain.Credentials(
                        accessToken: "tok",
                        refreshToken: canSelfRenew ? "refresh" : nil,
                        expiresAt: Date().addingTimeInterval(3600),
                        subscriptionType: "pro"
                    )
                },
                itemModified: { Date(timeIntervalSince1970: 1_000) }
            )

            _ = try cache.credentials()
            cache.invalidate()

            do {
                _ = try cache.credentials()
                Issue.record("expected the read to be held back")
            } catch let ClaudeKeychain.KeychainError.awaitingRotation(reported) {
                #expect(reported == canSelfRenew)
            }
        }
    }

    /// The gate fails open. A machine whose item cannot be stat'd must keep
    /// monitoring — a redundant read costs a dialog, a gate stuck shut costs
    /// the reading entirely, and stale data postpones rather than cancels.
    @Test("Without a timestamp the rejected token is re-read as before")
    func rereadsWhenTheTimestampIsUnknown() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return self.credentials(token: "token-\(reads.count)")
            },
            itemModified: { nil }
        )

        _ = try cache.credentials()
        cache.invalidate()

        #expect(try cache.credentials().accessToken == "token-2")
        #expect(reads.count == 2)
    }

    /// The gate must never be a trap: the popover shows the waiting state, and
    /// Refresh is the gesture that leaves it without relaunching the app.
    @Test("A manual refresh ends the rotation wait")
    func manualRefreshClearsTheRotationWait() throws {
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return self.credentials(token: "token-\(reads.count)")
            },
            itemModified: { Date(timeIntervalSince1970: 1_000) }
        )

        _ = try cache.credentials()
        cache.invalidate()
        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }

        cache.retryAfterDenial()

        #expect(try cache.credentials().accessToken == "token-2")
        #expect(reads.count == 2)
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

    private final class LogSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func write(_ line: String) {
            lock.lock(); stored.append(line); lock.unlock()
        }
    }

    /// The log is the instrument users hand over when the dialog surprises
    /// them, so each read must be preceded by the reason it happened.
    @Test("Each keychain read is logged with why it happened")
    func logsReadTriggers() throws {
        let spy = LogSpy()
        let reads = ReadCounter()
        let cache = ClaudeCredentialCache(
            read: {
                reads.increment()
                return self.credentials(token: "token-\(reads.count)", expiresIn: -1)
            },
            log: { spy.write($0) }
        )

        _ = try cache.credentials()
        _ = try cache.credentials()

        #expect(spy.lines.count == 2)
        #expect(spy.lines[0].contains("nothing cached yet"))
        #expect(spy.lines[1].contains("cached token expired"))
    }

    /// A "denial forgotten" line for a refresh that forgave nothing would put
    /// phantom dialogs in the log — it may only appear when a denial existed.
    @Test("Forgetting a denial is logged only when there was one")
    func logsDenialRetryOnlyWhenDenied() throws {
        let spy = LogSpy()
        let cache = ClaudeCredentialCache(
            read: { throw ClaudeKeychain.KeychainError.accessDenied },
            log: { spy.write($0) }
        )

        // No denial yet: a manual refresh must stay quiet about denials.
        cache.retryAfterDenial()
        #expect(!spy.lines.contains { $0.contains("denial forgotten") })

        #expect(throws: ClaudeKeychain.KeychainError.self) { _ = try cache.credentials() }
        cache.retryAfterDenial()
        #expect(spy.lines.contains { $0.contains("denial forgotten") })
    }

    @Test("Dropping the cache after a rejected token is logged, an empty drop is not")
    func logsInvalidateOnlyWhenSomethingDropped() throws {
        let spy = LogSpy()
        let cache = ClaudeCredentialCache(
            read: { self.credentials() },
            log: { spy.write($0) }
        )

        cache.invalidate()
        #expect(!spy.lines.contains { $0.contains("dropped") })

        _ = try cache.credentials()
        cache.invalidate()
        #expect(spy.lines.contains { $0.contains("dropped") })
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
