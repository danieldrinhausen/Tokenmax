import Foundation

/// Runs `claude auth login` for the popover and refreshes once it lands.
///
/// Owned by `ProviderUsageCoordinator` rather than a view, because the sign-in
/// outlives the popover: the user clicks, the popover closes as the browser
/// takes focus, and the refresh still has to happen when they come back.
@MainActor
final class ClaudeSignInCoordinator: ObservableObject {
    enum Activity: Equatable {
        case idle
        /// `claude auth login` is running and waiting on the browser.
        case waitingForBrowser
        /// Signed in; the usage refresh is held until the request floor lifts.
        case waitingForReading(at: Date)
    }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastOutcome: ClaudeSignIn.Outcome?

    private let usage: UsageRefreshCoordinator
    private var process: Process?
    private var timeoutTask: Task<Void, Never>?
    private var cancelled = false
    private var timedOut = false

    init(usage: UsageRefreshCoordinator) {
        self.usage = usage
    }

    var isBusy: Bool { activity != .idle }

    func start() {
        guard !isBusy else { return }
        lastOutcome = nil
        cancelled = false
        timedOut = false

        guard let cli = ClaudeCLIClient.locate() else {
            finish(.cliMissing)
            return
        }

        let process = Process()
        process.executableURL = cli
        process.arguments = ClaudeSignIn.arguments
        process.environment = ClaudeSignIn.environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // No stdin: the CLI falls back to its "paste code here" prompt only
        // when the localhost callback never arrives, and there is no one here
        // to paste. Output is discarded — it is the authorize URL and a
        // spinner, and a pipe nobody drains can stall the CLI.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processExited(status: status) }
        }

        do {
            try process.run()
        } catch {
            finish(.failedToStart(error.localizedDescription))
            return
        }

        self.process = process
        activity = .waitingForBrowser
        Log.shared.write("sign-in: started claude \(ClaudeSignIn.arguments.joined(separator: " "))")

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ClaudeSignIn.timeout))
            guard !Task.isCancelled else { return }
            self?.stop(timedOut: true)
        }
    }

    func cancel() {
        stop(timedOut: false)
    }

    private func stop(timedOut: Bool) {
        guard let process, process.isRunning else { return }
        if timedOut { self.timedOut = true } else { cancelled = true }
        process.terminate()
    }

    private func processExited(status: Int32) {
        timeoutTask?.cancel()
        timeoutTask = nil
        process = nil

        let outcome = ClaudeSignIn.Outcome.from(exitCode: status, cancelled: cancelled, timedOut: timedOut)
        Log.shared.write("sign-in: \(outcome)")
        guard outcome == .signedIn else {
            finish(outcome)
            return
        }

        lastOutcome = .signedIn
        Task {
            let allowedAt = await usage.nextNetworkRefreshAllowedAt()
            let delay = ClaudeSignIn.refreshDelay(now: Date(), nextRequestAllowedAt: allowedAt)
            activity = .waitingForReading(at: Date().addingTimeInterval(delay))
            try? await Task.sleep(for: .seconds(delay))
            // Manual, so a keychain denial from before the sign-in is asked
            // again: Claude Code has just rewritten the item.
            await usage.refresh(reason: "sign-in", manual: true, retryDeniedKeychainAccess: true)
            activity = .idle
        }
    }

    private func finish(_ outcome: ClaudeSignIn.Outcome) {
        lastOutcome = outcome
        activity = .idle
    }
}
