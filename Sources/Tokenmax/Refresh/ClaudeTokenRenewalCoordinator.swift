import Combine
import Foundation

/// Asks Claude Code to renew its login when the usage endpoint has rejected
/// the saved token, and refreshes once it has.
///
/// Owned by `ProviderUsageCoordinator` beside the sign-in, for the same reason:
/// the run outlives any popover. The rules are `ClaudeTokenRenewal.decide`; this
/// type owns the clock, the process and the bookkeeping, and nothing else.
@MainActor
final class ClaudeTokenRenewalCoordinator: ObservableObject {
    enum Activity: Equatable {
        case idle
        /// `claude` is running in the hidden terminal.
        case renewing
        /// Claude Code renewed; the usage refresh is held until the request
        /// floor lifts, exactly as after a sign-in.
        case waitingForReading(at: Date)
    }

    @Published private(set) var activity: Activity = .idle
    /// Why the last evaluation did not run, for the popover. Nil when there is
    /// nothing worth saying — not awaiting renewal, or a run in progress.
    @Published private(set) var lastSuppression: ClaudeTokenRenewal.Reason?

    typealias Runner = @Sendable (URL) async -> ClaudeTokenRenewal.RunResult

    private let usage: UsageRefreshCoordinator
    private let signIn: ClaudeSignInCoordinator
    private let claudeEnabled: () -> Bool
    private let locateCLI: @Sendable () -> URL?
    private let runner: Runner
    private let dataSource: () -> ClaudeDataSource
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var cancellables: Set<AnyCancellable> = []
    private var lastAttemptAt: Date?
    private var attemptsWithoutEffect = 0
    /// Resolved on first need rather than at launch: finding the CLI can mean
    /// starting a login shell, which is not worth doing for a token that never
    /// expires while the app is open.
    private var cli: URL?
    private var hasLookedForCLI = false
    private var isLookingForCLI = false
    private var lastLoggedSuppression: ClaudeTokenRenewal.Reason?

    init(
        usage: UsageRefreshCoordinator,
        signIn: ClaudeSignInCoordinator,
        settingsStore: SettingsStore,
        claudeEnabled: (() -> Bool)? = nil,
        locateCLI: @escaping @Sendable () -> URL? = { ClaudeCLIClient.locate() },
        runner: Runner? = nil,
        dataSource: @escaping () -> ClaudeDataSource = { ClaudeDataSourceFlag.shared.current },
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.usage = usage
        self.signIn = signIn
        self.claudeEnabled = claudeEnabled ?? { [weak settingsStore] in
            settingsStore?.settings.isEnabled(.claudeCode) ?? false
        }
        self.locateCLI = locateCLI
        self.runner = runner ?? { cli in
            await Task.detached(priority: .utility) {
                ClaudeRenewalSession.run(
                    cli: cli,
                    itemModified: { ClaudeKeychain.itemModificationDate() },
                    log: { Log.shared.write($0) }
                )
            }.value
        }
        self.dataSource = dataSource
        self.now = now
        self.sleep = sleep

        // Every state assignment, not only the first rejection: a refresh tick
        // that lands on a still-rejected token is exactly when the cooldown may
        // have lapsed. `@Published` fires before the value is stored, so the
        // evaluation is deferred to read the state after it.
        usage.$state
            .sink { [weak self] _ in
                Task { @MainActor in await self?.evaluate(userRequested: false) }
            }
            .store(in: &cancellables)
    }

    /// The popover's Refresh while the saved credential is rejected. Skips the
    /// cooldown and the no-effect limit — see `ClaudeTokenRenewal.decide`.
    func userRequested() {
        Task { await evaluate(userRequested: true) }
    }

    func evaluate(userRequested: Bool) async {
        let awaiting = usage.isAwaitingTokenRenewal
        // An evaluation that lands mid-lookup has nothing to add: the lookup's
        // own evaluation decides, and deciding here would report a CLI as
        // missing that is only not found *yet*.
        guard !isLookingForCLI else { return }
        if awaiting, cli == nil, !hasLookedForCLI || userRequested {
            hasLookedForCLI = true
            isLookingForCLI = true
            let locate = locateCLI
            cli = await Task.detached(priority: .utility) { locate() }.value
            isLookingForCLI = false
        }

        let verdict = ClaudeTokenRenewal.decide(input(userRequested: userRequested, awaiting: awaiting))
        switch verdict {
        case .run:
            guard let cli else { return }
            await perform(cli: cli, userRequested: userRequested)
        case let .suppressed(reason):
            record(reason)
        }
    }

    private func input(userRequested: Bool, awaiting: Bool) -> ClaudeTokenRenewal.Input {
        ClaudeTokenRenewal.Input(
            awaitingRenewal: awaiting,
            dataSource: dataSource(),
            claudeEnabled: claudeEnabled(),
            cliFound: cli != nil,
            isRunning: activity != .idle,
            signInInProgress: signIn.isBusy,
            lastAttemptAt: lastAttemptAt,
            attemptsWithoutEffect: attemptsWithoutEffect,
            userRequested: userRequested,
            now: now()
        )
    }

    private func record(_ reason: ClaudeTokenRenewal.Reason) {
        switch reason {
        case .notAwaitingRenewal:
            lastSuppression = nil
            lastLoggedSuppression = nil
            return
        // The activity line already says a run is going on.
        case .alreadyRunning:
            return
        default:
            lastSuppression = reason
        }
        // Once per change of reason: a rejected token is re-evaluated on every
        // refresh tick, and the same line every five minutes says nothing new.
        guard reason != lastLoggedSuppression else { return }
        lastLoggedSuppression = reason
        Log.shared.write("renewal: not running — \(reason.explanation)")
    }

    private func perform(cli: URL, userRequested: Bool) async {
        if userRequested { attemptsWithoutEffect = 0 }
        activity = .renewing
        lastSuppression = nil
        lastLoggedSuppression = nil
        lastAttemptAt = now()
        Log.shared.write("renewal: asking Claude Code to renew its login\(userRequested ? " (Refresh)" : "")")

        let result = await runner(cli)

        switch result {
        case .renewed:
            attemptsWithoutEffect = 0
            let allowedAt = await usage.nextNetworkRefreshAllowedAt()
            let delay = ClaudeSignIn.refreshDelay(now: now(), nextRequestAllowedAt: allowedAt)
            activity = .waitingForReading(at: now().addingTimeInterval(delay))
            await sleep(delay)
            activity = .idle
            // Manual so the refresh coordinator's failure backoff does not hold
            // back the one reading this whole run existed to produce. No denial
            // retry: a denial is the user's answer, not something a renewal
            // changes.
            await usage.refresh(reason: "renewal", manual: true)
        case .unchanged:
            attemptsWithoutEffect += 1
            activity = .idle
            record(suppressionAfterMiss())
        case let .failedToStart(detail):
            attemptsWithoutEffect += 1
            activity = .idle
            Log.shared.write("renewal: could not start claude: \(detail)")
            record(suppressionAfterMiss())
        }
    }

    /// What the popover should say after a run that did not renew. Derived
    /// from the same rules rather than restated, so the copy cannot promise a
    /// retry the decision would refuse.
    private func suppressionAfterMiss() -> ClaudeTokenRenewal.Reason {
        let verdict = ClaudeTokenRenewal.decide(
            input(userRequested: false, awaiting: usage.isAwaitingTokenRenewal)
        )
        if case let .suppressed(reason) = verdict { return reason }
        return .noEffect
    }
}
