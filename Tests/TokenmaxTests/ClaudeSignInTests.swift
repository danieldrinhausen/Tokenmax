import Foundation
import Testing

@testable import Tokenmax

@Suite("Claude sign-in")
struct ClaudeSignInTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    @Test("The sign-in always asks for the subscription login, never Console API billing")
    func pinsSubscriptionLogin() {
        #expect(ClaudeSignIn.arguments == ["auth", "login", "--claudeai"])
        #expect(!ClaudeSignIn.arguments.contains("--console"))
    }

    @Test("The sign-in environment drops an API key and a redirected browser")
    func environmentIsAllowlisted() {
        let environment = ClaudeSignIn.environment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "BROWSER": "/usr/bin/true",
        ])
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["BROWSER"] == nil)
    }

    @Test("A menu bar app's missing PATH is filled in so the CLI can find its runtime")
    func environmentSuppliesPath() {
        #expect(ClaudeSignIn.environment(from: [:])["PATH"] != nil)
    }

    @Test("A clean exit is a sign-in")
    func zeroExitSignsIn() {
        #expect(ClaudeSignIn.Outcome.from(exitCode: 0, cancelled: false, timedOut: false) == .signedIn)
    }

    @Test("A non-zero exit is a failure that carries its status")
    func nonZeroExitFails() {
        #expect(ClaudeSignIn.Outcome.from(exitCode: 1, cancelled: false, timedOut: false) == .failed(exitCode: 1))
    }

    @Test("A cancelled sign-in is never reported as signed in, whatever the exit status")
    func cancelWinsOverExitCode() {
        #expect(ClaudeSignIn.Outcome.from(exitCode: 0, cancelled: true, timedOut: false) == .cancelled)
        #expect(ClaudeSignIn.Outcome.from(exitCode: 15, cancelled: true, timedOut: false) == .cancelled)
    }

    @Test("A timed-out sign-in is never reported as signed in, whatever the exit status")
    func timeoutWinsOverExitCode() {
        #expect(ClaudeSignIn.Outcome.from(exitCode: 0, cancelled: false, timedOut: true) == .timedOut)
    }

    @Test("Success and a user's own cancel need no message; every failure says what to do")
    func messages() {
        #expect(ClaudeSignIn.Outcome.signedIn.message == nil)
        #expect(ClaudeSignIn.Outcome.cancelled.message == nil)
        for outcome: ClaudeSignIn.Outcome in [.cliMissing, .failedToStart("x"), .timedOut, .failed(exitCode: 1)] {
            #expect(outcome.message?.isEmpty == false)
        }
    }

    @Test("The post-sign-in refresh waits out the request floor, so it cannot replay the rejected reading")
    func refreshWaitsForFloor() {
        let delay = ClaudeSignIn.refreshDelay(now: now, nextRequestAllowedAt: now.addingTimeInterval(120))
        #expect(delay > 120)
    }

    @Test("The post-sign-in refresh is immediate once the floor has already lifted")
    func refreshIsPromptAfterFloor() {
        let delay = ClaudeSignIn.refreshDelay(now: now, nextRequestAllowedAt: now.addingTimeInterval(-300))
        #expect(delay >= 0 && delay <= 1)
    }
}
