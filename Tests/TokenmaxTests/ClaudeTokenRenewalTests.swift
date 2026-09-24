import Foundation
import Testing

@testable import Tokenmax

@Suite("Claude token renewal")
struct ClaudeTokenRenewalTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func input(
        awaiting: Bool = true,
        dataSource: ClaudeDataSource = .keychain,
        enabled: Bool = true,
        cliFound: Bool = true,
        running: Bool = false,
        signIn: Bool = false,
        lastAttemptAt: Date? = nil,
        misses: Int = 0,
        userRequested: Bool = false
    ) -> ClaudeTokenRenewal.Input {
        ClaudeTokenRenewal.Input(
            awaitingRenewal: awaiting,
            dataSource: dataSource,
            claudeEnabled: enabled,
            cliFound: cliFound,
            isRunning: running,
            signInInProgress: signIn,
            lastAttemptAt: lastAttemptAt,
            attemptsWithoutEffect: misses,
            userRequested: userRequested,
            now: now
        )
    }

    // MARK: - Decision

    @Test("A rejected token with nothing in the way runs a renewal")
    func runsWhenAwaiting() {
        #expect(ClaudeTokenRenewal.decide(input()) == .run)
    }

    @Test("Nothing runs while the saved credential is not waiting for renewal, even on Refresh")
    func notAwaiting() {
        #expect(ClaudeTokenRenewal.decide(input(awaiting: false)) == .suppressed(.notAwaitingRenewal))
        #expect(ClaudeTokenRenewal.decide(input(awaiting: false, userRequested: true))
            == .suppressed(.notAwaitingRenewal))
    }

    @Test("Status line only mode never renews, even on Refresh")
    func statuslineOnlyRefuses() {
        #expect(ClaudeTokenRenewal.decide(input(dataSource: .statuslineOnly, userRequested: true))
            == .suppressed(.statuslineOnly))
    }

    @Test("A switched-off Claude provider never renews, even on Refresh")
    func disabledRefuses() {
        #expect(ClaudeTokenRenewal.decide(input(enabled: false, userRequested: true))
            == .suppressed(.providerDisabled))
    }

    @Test("A sign-in in progress wins over a renewal, even on Refresh")
    func signInRefuses() {
        #expect(ClaudeTokenRenewal.decide(input(signIn: true, userRequested: true))
            == .suppressed(.signInInProgress))
    }

    @Test("A second renewal never starts while one is running, even on Refresh")
    func runningRefuses() {
        #expect(ClaudeTokenRenewal.decide(input(running: true, userRequested: true))
            == .suppressed(.alreadyRunning))
    }

    @Test("A missing CLI is reported rather than silently skipped")
    func missingCLI() {
        #expect(ClaudeTokenRenewal.decide(input(cliFound: false)) == .suppressed(.cliMissing))
    }

    @Test("Automatic attempts wait out the cooldown")
    func cooldownHolds() {
        let last = now.addingTimeInterval(-60)
        #expect(ClaudeTokenRenewal.decide(input(lastAttemptAt: last))
            == .suppressed(.coolingDown(until: last.addingTimeInterval(ClaudeTokenRenewal.cooldown))))
    }

    @Test("An automatic attempt runs again once the cooldown has passed")
    func cooldownLapses() {
        let last = now.addingTimeInterval(-ClaudeTokenRenewal.cooldown)
        #expect(ClaudeTokenRenewal.decide(input(lastAttemptAt: last)) == .run)
    }

    @Test("Refresh skips the cooldown")
    func refreshSkipsCooldown() {
        #expect(ClaudeTokenRenewal.decide(input(lastAttemptAt: now, userRequested: true)) == .run)
    }

    @Test("Automatic attempts stop after two runs that did not renew")
    func noEffectStops() {
        let long = now.addingTimeInterval(-10 * ClaudeTokenRenewal.cooldown)
        #expect(ClaudeTokenRenewal.decide(input(lastAttemptAt: long, misses: 1)) == .run)
        #expect(ClaudeTokenRenewal.decide(input(lastAttemptAt: long, misses: 2)) == .suppressed(.noEffect))
    }

    @Test("Refresh tries again after the no-effect limit")
    func refreshSkipsNoEffect() {
        #expect(ClaudeTokenRenewal.decide(input(misses: 5, userRequested: true)) == .run)
    }

    @Test("Every suppression has copy the popover can show")
    func everyReasonExplains() {
        let reasons: [ClaudeTokenRenewal.Reason] = [
            .notAwaitingRenewal, .statuslineOnly, .providerDisabled, .cliMissing,
            .alreadyRunning, .signInInProgress, .coolingDown(until: now), .noEffect,
        ]
        for reason in reasons {
            #expect(!reason.explanation.isEmpty)
        }
    }

    // MARK: - Item change

    @Test("A newer write to the item is a renewal")
    func newerWriteRenews() {
        #expect(ClaudeTokenRenewal.itemChanged(baseline: now, current: now.addingTimeInterval(1)))
    }

    @Test("An unchanged or missing item is not a renewal")
    func unchangedIsNot() {
        #expect(!ClaudeTokenRenewal.itemChanged(baseline: now, current: now))
        #expect(!ClaudeTokenRenewal.itemChanged(baseline: now, current: nil))
        #expect(!ClaudeTokenRenewal.itemChanged(baseline: nil, current: nil))
    }

    @Test("An item that appears during the run is a renewal")
    func appearingItemRenews() {
        #expect(ClaudeTokenRenewal.itemChanged(baseline: nil, current: now))
    }

    // MARK: - Safety: nothing can reach a model

    @Test("The renewal never runs in print mode, never skips permissions, and carries no prompt")
    func argumentsCarryNoPrompt() {
        let arguments = ClaudeTokenRenewal.arguments
        #expect(!arguments.contains("-p"))
        #expect(!arguments.contains("--print"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--allow-dangerously-skip-permissions"))

        // Every non-flag token must be the value of the flag before it — a
        // bare positional argument is a prompt.
        let valued: Set<String> = ["--tools", "--setting-sources"]
        for (index, argument) in arguments.enumerated() where !argument.hasPrefix("-") {
            #expect(index > 0 && valued.contains(arguments[index - 1]), "positional argument \(argument)")
        }
    }

    @Test("The renewal disables tools, MCP servers and settings files")
    func argumentsDisableEverything() {
        let arguments = ClaudeTokenRenewal.arguments
        #expect(arguments.contains("--strict-mcp-config"))
        if let tools = arguments.firstIndex(of: "--tools") {
            #expect(arguments[tools + 1] == "")
        } else {
            Issue.record("--tools missing")
        }
        if let sources = arguments.firstIndex(of: "--setting-sources") {
            #expect(arguments[sources + 1] == "")
        } else {
            Issue.record("--setting-sources missing")
        }
    }

    @Test("The renewal environment drops an API key and a redirected browser")
    func environmentIsAllowlisted() {
        let environment = ClaudeTokenRenewal.environment(from: [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "sk-ant-test",
            "ANTHROPIC_AUTH_TOKEN": "token",
            "BROWSER": "/usr/bin/true",
        ])
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["BROWSER"] == nil)
        #expect(environment["TERM"] != nil)
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
    }

    @Test("The only keystrokes are Return, /status and Escape")
    func keystrokesAreAllowlisted() {
        let allowed: Set<String> = ["\r", "/status\r", "\u{1b}"]
        #expect(Set(ClaudeTokenRenewal.Keystroke.allCases.map(\.bytes)) == allowed)
    }

    // MARK: - Trust prompt

    @Test("The folder-trust question is recognised through terminal escapes")
    func trustPromptRecognised() {
        #expect(ClaudeTokenRenewal.showsTrustPrompt("Do you trust the files in this folder?"))
        #expect(ClaudeTokenRenewal.showsTrustPrompt("\u{1b}[1mYes, I\u{1b}[2C trust\u{1b}[0m this folder"))
    }

    @Test("An ordinary startup screen is not mistaken for the trust question")
    func trustPromptQuietOnLookalikes() {
        #expect(!ClaudeTokenRenewal.showsTrustPrompt("Welcome to Claude Code! /help for help"))
        #expect(!ClaudeTokenRenewal.showsTrustPrompt("This folder is trusted."))
    }
}
