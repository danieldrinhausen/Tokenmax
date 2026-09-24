import Foundation
import Security

/// Reads the OAuth credentials Claude Code stores in the login keychain.
///
/// The secret is read through `/usr/bin/security`, the tool Claude Code itself
/// writes the item with, so macOS serves it without a consent dialog — see
/// `performRead` for why reading from our own process could never manage that.
///
/// Every read is still served through `ClaudeCredentialCache`, which keeps
/// reads rare and keeps the denial handling for a machine whose item does not
/// trust the tool: there `security` raises the dialog, and a user who answers
/// *Deny* is not asked again until they click Refresh themselves.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let subscriptionType: String?

        var isExpired: Bool { isExpired(at: Date()) }

        /// Takes the clock as a parameter so the cache can be tested without
        /// waiting for a token to age out.
        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }
    }

    enum KeychainError: Error, LocalizedError {
        case notFound
        /// The user answered the consent dialog with *Deny* or dismissed it.
        /// The cache remembers this one — see `ClaudeCredentialCache` — so it
        /// must only ever mean "the user answered", never "no answer possible".
        case accessDenied
        /// macOS could not raise the dialog at all — a locked keychain during a
        /// background tick, typically. Environmental and transient, so it is
        /// kept out of `accessDenied`: remembering it as a denial would switch
        /// monitoring off because a screen was locked at the wrong moment.
        case interactionNotAllowed
        /// The endpoint rejected the token we hold and the item has not been
        /// written since, so the keychain still holds that same token. Not a
        /// failure to read — a refusal to ask a question whose answer we
        /// already have. `canSelfRenew` carries whether the rejected token had
        /// a refresh token, which is what decides between "Claude Code will fix
        /// this" and "sign in again".
        case awaitingRotation(canSelfRenew: Bool)
        case malformed
        case unexpected(OSStatus)
        /// Refused because this is a test run. See `RuntimeEnvironment`.
        case suppressedUnderTest

        var errorDescription: String? {
            switch self {
            case .notFound: "Claude Code is installed but not authenticated."
            case .accessDenied: "Tokenmax was denied access to the Claude Code keychain item."
            case .interactionNotAllowed: "The keychain could not ask for permission — it may be locked. Tokenmax will retry."
            case .awaitingRotation: "Claude Code's saved credential was rejected; Tokenmax is waiting for Claude Code to renew it."
            case .malformed: "The Claude Code credentials could not be read."
            case let .unexpected(status): "Keychain error \(status)."
            case .suppressedUnderTest: "Keychain access is refused during tests."
            }
        }
    }

    private struct Payload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            /// Epoch **milliseconds**.
            let expiresAt: Double?
            let subscriptionType: String?
        }

        let claudeAiOauth: OAuth
    }

    /// The one cache every caller shares.
    ///
    /// Shared rather than per-object on purpose: the app builds several
    /// credential readers at launch — the usage provider and the model catalog
    /// among them — and a cache per object would mean a dialog per object,
    /// which is the bug in miniature.
    private static let cache = ClaudeCredentialCache(
        read: readFromKeychain,
        // Lets the cache wait for Claude Code to rewrite the item instead of
        // re-reading a token the endpoint already rejected. Suppressed under
        // test for the same reason the read is: the suite must not reach the
        // real item, even for an attribute nobody needs consent to see.
        itemModified: { RuntimeEnvironment.isTesting ? nil : itemModificationDate() },
        log: { Log.shared.write($0) }
    )

    /// Serves the shared cache, reading the keychain only when it has nothing
    /// usable. See `ClaudeCredentialCache` for what that means.
    static func readCredentials() throws -> Credentials {
        try cache.credentials()
    }

    /// Drops the cached credentials, so the next read goes back to the keychain.
    ///
    /// The one caller that should reach for this is a 401 from the usage
    /// endpoint. Note what that does and does not establish: the token we hold
    /// was refused, which is not the same as Claude Code having written a new
    /// one. The cache keeps the two apart — see its rotation gate — because
    /// treating the 401 as proof of a rotation is what made the app re-read a
    /// dead token every five minutes.
    static func invalidateCache() {
        cache.invalidate()
    }

    /// Forgets a remembered denial, so the next read may ask macOS again.
    /// See `ClaudeCredentialCache.retryAfterDenial` for who may call this and
    /// why a timer never does.
    static func retryDeniedAccess() {
        cache.retryAfterDenial()
    }

    private static let readFromKeychain: @Sendable () throws -> Credentials = {
        // Guarded here rather than at the call sites because the call sites are
        // not the point: anything constructed with default arguments reaches
        // this function, and the app builds several such objects at launch.
        // One guard at the boundary is the only version that stays true as
        // callers are added.
        //
        // Guarded *inside* the cache's read rather than in front of it so a
        // test run can never leave real credentials sitting in the cache.
        guard !RuntimeEnvironment.isTesting else { throw KeychainError.suppressedUnderTest }

        // Timed so the log can say whether the consent dialog appeared: an
        // ACL-served read answers in milliseconds, a read that raised the
        // dialog blocks until the user answers. See `KeychainReadLog`.
        let started = Date()
        func log(_ outcome: KeychainReadLog.Outcome) {
            Log.shared.write(KeychainReadLog.line(
                outcome: outcome,
                elapsed: Date().timeIntervalSince(started),
                itemModified: itemModificationDate()
            ))
        }

        do {
            let credentials = try performRead()
            log(.ok)
            return credentials
        } catch let error as KeychainError {
            switch error {
            case .notFound: log(.notFound)
            case .accessDenied: log(.denied)
            case .interactionNotAllowed: log(.interactionNotAllowed)
            case .malformed: log(.malformed)
            case let .unexpected(status): log(.unexpected(status))
            // Neither can reach here: the cache throws them *instead of*
            // calling this read, so there is no read for the log to describe.
            case .awaitingRotation, .suppressedUnderTest: break
            }
            throw error
        }
    }

    /// When Claude Code last wrote the item — useful correlation for a likely
    /// token rotation, but not proof of why it changed.
    ///
    /// Attribute reads are not gated by the item's ACL, only reads of the
    /// secret data are, so this never raises a dialog. It is how each log
    /// line can carry the modification timestamp without costing a prompt.
    static func itemModificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Reads the secret through Apple's `security` tool rather than
    /// `SecItemCopyMatching`, and that choice is the whole reason Tokenmax does
    /// not prompt.
    ///
    /// Claude Code writes this item with `/usr/bin/security` itself, so the
    /// tool is in the item's decrypt ACL and covered by its `apple-tool:`
    /// partition entry — both put there by the owner, both kept across every
    /// rewrite. A read from our own process has neither: its grant is keyed to
    /// a cdhash that changes with every build, and each Claude Code token
    /// rotation evicts it (measured: the first read after a rewrite prompted 15
    /// times out of 15). No certificate fixes the second half; asking through
    /// the tool the owner already trusts does.
    ///
    /// This gives up the consent dialog, which earlier decisions treated as a
    /// trust boundary. For this item it never was one: any process the user
    /// runs can issue the same command and get the same answer silently. See
    /// `docs/KEYCHAIN_PROMPT_DECISIONS.md`, Decision 7.
    private static let performRead: @Sendable () throws -> Credentials = {
        let output = runSecurity(["find-generic-password", "-s", ClaudeKeychain.service, "-w"])
        return try credentials(fromSecurityExit: output.status, stdout: output.stdout, stderr: output.stderr)
    }

    /// Absolute on purpose: a `PATH` lookup would hand the user's token to
    /// whatever sits earlier on the path.
    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")

    /// How long a read may run before it counts as unanswered. Generous
    /// because on a machine whose item does not trust the tool, `security`
    /// raises the same consent dialog and has to wait for a human.
    static let securityTimeout: TimeInterval = 60

    /// Stands in for an exit status when the tool could not run or had to be
    /// killed. Outside the 0–255 range a real exit produces, so it cannot
    /// collide with one.
    static let securityDidNotFinish: Int32 = -1

    /// Turns the tool's result into credentials or the error the cache already
    /// understands. Pure, so the mapping is testable without the keychain.
    ///
    /// `security` reports failures as text on stderr and a small exit code (44
    /// for a missing item), not as an `OSStatus`, so the classification reads
    /// the message. What matters is keeping `accessDenied` to an answered
    /// dialog — the cache remembers that one — and everything environmental
    /// out of it.
    static func credentials(fromSecurityExit status: Int32, stdout: Data, stderr: Data) throws -> Credentials {
        guard status == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? ""
            if status == 44 || message.contains("could not be found") {
                throw KeychainError.notFound
            }
            if message.contains("User canceled") || message.contains("passphrase you entered is not correct") {
                throw KeychainError.accessDenied
            }
            // A dialog nobody answered is not a denial; retry it like a blip.
            if status == securityDidNotFinish || message.contains("User interaction is not allowed") {
                throw KeychainError.interactionNotAllowed
            }
            throw KeychainError.unexpected(status)
        }

        guard let data = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)
        else { throw KeychainError.malformed }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let oauth = payload.claudeAiOauth
            return Credentials(
                accessToken: oauth.accessToken,
                refreshToken: oauth.refreshToken,
                // Stored as epoch milliseconds.
                expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                subscriptionType: oauth.subscriptionType
            )
        } catch {
            throw KeychainError.malformed
        }
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = securityTool
        process.arguments = arguments
        // The tool needs nothing from the environment, and a child that will
        // print the user's token has no business inheriting ours.
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return (securityDidNotFinish, Data(), Data())
        }

        // Drained concurrently, as in `ClaudeCLIClient.run`: reading one pipe
        // to EOF first can deadlock a child that fills the other.
        let group = DispatchGroup()
        let outputBox = SecurityOutputBox()
        let errorBox = SecurityOutputBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(securityTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        var finished = true
        if process.isRunning {
            finished = false
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        group.wait()

        return (finished ? process.terminationStatus : securityDidNotFinish, outputBox.value, errorBox.value)
    }
}

/// Carries a pipe's contents out of the worker that drained it.
private final class SecurityOutputBox: @unchecked Sendable {
    var value = Data()
}
