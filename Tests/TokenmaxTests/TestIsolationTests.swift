import Foundation
import Testing

@testable import Tokenmax

/// The suite runs inside the app, so "the tests do not touch my real machine"
/// is a property that has to be asserted, not assumed. These are the assertions.
@Suite("Test isolation")
struct TestIsolationTests {
    @Test("The suite knows it is a test run")
    func detectsTestRun() {
        #expect(RuntimeEnvironment.isTesting)
    }

    /// The regression this exists for: two consent dialogs per `make test`,
    /// raised by an ad-hoc-signed test host that no grant can ever satisfy,
    /// because its cdhash changes on every build.
    @Test("Reading real credentials is refused, not attempted")
    func refusesTheRealKeychain() {
        #expect(throws: ClaudeKeychain.KeychainError.self) {
            _ = try ClaudeKeychain.readCredentials()
        }

        do {
            _ = try ClaudeKeychain.readCredentials()
            Issue.record("expected the read to be refused")
        } catch let error as ClaudeKeychain.KeychainError {
            guard case .suppressedUnderTest = error else {
                Issue.record("refused for the wrong reason: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// Writes go to a scratch directory, so a test run cannot overwrite a real
    /// queue or the user's settings.
    @Test("Support files are redirected away from the real directory")
    func supportDirectoryIsRedirected() {
        let path = FileLocations.supportDirectory.path
        #expect(path.hasPrefix("/tmp/"), "support directory escaped to \(path)")
    }
}
