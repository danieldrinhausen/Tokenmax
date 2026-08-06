import Foundation

/// What kind of process this is.
///
/// It exists for one reason: `xcodebuild test` hosts the unit tests **inside
/// the app**, so `@main TokenmaxApp.init()` runs for real during a test run.
/// Every coordinator it builds with default arguments then does what it does in
/// production — including reading the login keychain.
///
/// That read is the visible problem. The test host is ad-hoc signed
/// (`CODE_SIGN_IDENTITY: "-"`), so it cannot satisfy the designated requirement
/// stored in the credential item's ACL by the installed, certificate-signed
/// copy — even though both claim `com.tokenmax.Tokenmax`. macOS therefore
/// treats it as a different program asking for someone else's secret and raises
/// a consent dialog. Its cdhash changes on every build, so "Always Allow" can
/// never make it stop: there is no stable identity for the grant to attach to.
///
/// Two prompts per `make test`, one for each object that reads credentials at
/// launch, on a developer machine, forever.
enum RuntimeEnvironment {
    /// Detected two ways on purpose.
    ///
    /// `XCTestConfigurationFilePath` is set by the test runner itself, so this
    /// holds however the suite was started — `make test`, Xcode's UI, a single
    /// test re-run — and cannot be defeated by editing a scheme.
    /// `TOKENMAX_TESTING` is the explicit form, set alongside the other test
    /// overrides in `project.yml`, so the intent is greppable from the scheme
    /// rather than only discoverable in this file.
    static let isTesting: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["TOKENMAX_TESTING"] == "1"
    }()
}
