import Foundation
import Testing

@testable import Tokenmax

/// The rule these guard: the `security` tool's text output maps onto the same
/// errors the credential cache was built around, and only an answered dialog
/// ever becomes `accessDenied` — the one error the cache remembers.
@Suite("Security tool read")
struct SecurityToolReadTests {
    private func read(
        status: Int32, stdout: String = "", stderr: String = ""
    ) throws -> ClaudeKeychain.Credentials {
        try ClaudeKeychain.credentials(
            fromSecurityExit: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)
        )
    }

    private func error(status: Int32, stdout: String = "", stderr: String = "") -> ClaudeKeychain.KeychainError? {
        do {
            _ = try read(status: status, stdout: stdout, stderr: stderr)
            return nil
        } catch {
            return error as? ClaudeKeychain.KeychainError
        }
    }

    @Test("A successful read decodes the payload, trailing newline and all")
    func decodesPayload() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1774000000000,"subscriptionType":"max"}}"#
        let credentials = try read(status: 0, stdout: json + "\n")
        #expect(credentials.accessToken == "a")
        #expect(credentials.refreshToken == "r")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_774_000_000))
    }

    @Test("An expiry sent as a string, or as nonsense, never makes the credentials unreadable")
    func tolerantExpiry() throws {
        func credentials(_ expiry: String) throws -> ClaudeKeychain.Credentials {
            try read(status: 0, stdout: #"{"claudeAiOauth":{"accessToken":"a","expiresAt":\#(expiry)}}"#)
        }
        #expect(try credentials(#""1774000000000""#).expiresAt == Date(timeIntervalSince1970: 1_774_000_000))
        #expect(try credentials(#""2026-03-20T09:46:40Z""#).expiresAt != nil)
        #expect(try credentials(#"{"nested": true}"#).expiresAt == nil)
        #expect(try credentials(#""soon""#).expiresAt == nil)
    }

    @Test("A missing access token is still malformed, not silently empty")
    func accessTokenStaysRequired() {
        let result = error(status: 0, stdout: #"{"claudeAiOauth":{"expiresAt":1}}"#)
        guard case .malformed = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("Exit 44 is a missing item, not a denial")
    func missingItem() {
        let result = error(
            status: 44,
            stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
        )
        guard case .notFound = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("A cancelled dialog is a denial")
    func cancelledDialog() {
        let result = error(status: 128, stderr: "security: SecKeychainItemCopyContent: User canceled the operation.")
        guard case .accessDenied = result else { Issue.record("got \(String(describing: result))"); return }
    }

    /// A dialog that nobody answered is the locked-screen case in another
    /// form; remembering it as a denial would switch monitoring off for the
    /// rest of the launch.
    @Test("A killed or unlaunchable tool is transient, never a denial")
    func unfinishedIsTransient() {
        let result = error(status: ClaudeKeychain.securityDidNotFinish)
        guard case .interactionNotAllowed = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("A keychain that cannot show UI is transient, never a denial")
    func interactionNotAllowed() {
        let result = error(status: 1, stderr: "security: User interaction is not allowed.")
        guard case .interactionNotAllowed = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("An unrecognised failure keeps its exit status and is not a denial")
    func unrecognisedFailure() {
        let result = error(status: 1, stderr: "security: something new")
        guard case .unexpected(1) = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("A successful exit with a reshaped payload is malformed")
    func reshapedPayload() {
        let result = error(status: 0, stdout: #"{"somethingElse":{}}"#)
        guard case .malformed = result else { Issue.record("got \(String(describing: result))"); return }
    }

    @Test("The tool is called by absolute path, never looked up on PATH")
    func absolutePath() {
        #expect(ClaudeKeychain.securityTool.path == "/usr/bin/security")
    }
}
