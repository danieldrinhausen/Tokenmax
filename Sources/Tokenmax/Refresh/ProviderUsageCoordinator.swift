import Combine
import Foundation

/// Keeps provider refresh work behind one environment object, and owns which
/// providers are polled at all.
@MainActor
final class ProviderUsageCoordinator: ObservableObject {
    @Published private(set) var tick = Date()
    let claude: UsageRefreshCoordinator
    let codex: UsageRefreshCoordinator
    private let settingsStore: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        claude = UsageRefreshCoordinator(settingsStore: settingsStore)
        codex = UsageRefreshCoordinator(
            provider: CodexProvider(), settingsStore: settingsStore,
            snapshotURL: FileLocations.codexUsageSnapshotFile
        )

        claude.objectWillChange.merge(with: codex.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Merged, not Claude's alone. This tick drives auto-run evaluation, the
        // session opener, and every countdown label in the app — sourcing it
        // from one provider means disabling that provider freezes all of them,
        // leaving an app that looks alive and is not.
        claude.$tick.merge(with: codex.$tick)
            .sink { [weak self] value in self?.tick = value }
            .store(in: &cancellables)
    }

    /// The provider the single-meter screens speak for.
    ///
    /// Hardcoding Claude was safe only while both providers were always on.
    /// With Claude switched off it would name a coordinator that has stopped
    /// refreshing. The fallback is unreachable — `AppSettings.init(from:)`
    /// guarantees a non-empty list — and exists only to keep this total.
    var selectedProvider: TokenmaxProvider {
        settingsStore.settings.enabledProviders.first ?? .claudeCode
    }

    func isEnabled(_ provider: TokenmaxProvider) -> Bool {
        settingsStore.settings.isEnabled(provider)
    }

    private var enabledProviders: [TokenmaxProvider] { settingsStore.settings.enabledProviders }

    func coordinator(for provider: TokenmaxProvider) -> UsageRefreshCoordinator {
        provider == .codex ? codex : claude
    }

    func state(for provider: TokenmaxProvider) -> UsageState { coordinator(for: provider).state }
    func isStale(for provider: TokenmaxProvider) -> Bool { coordinator(for: provider).isStale }
    func snapshot(for provider: TokenmaxProvider) -> UsageSnapshot? { state(for: provider).snapshot }
    /// Whether this provider's last refresh found an API-key login. Read by the
    /// queue, which must not start a run that would be billed per token.
    func isAPIKeyOnly(for provider: TokenmaxProvider) -> Bool {
        coordinator(for: provider).isAPIKeyOnly
    }

    /// The windows currently in their "spend it now" stretch, per source.
    ///
    /// Deliberately shaped like `NotificationCoordinator.alertingSources`, and
    /// for the same reason: the menubar draws one bar per source, so anything
    /// that colours a bar has to be answerable *per source*. The single
    /// `burnOpportunity` below is the selected provider's alone, and passing it
    /// to every bar told a window with four days left that it was about to
    /// evaporate.
    ///
    /// Only session windows can appear here. `burnOpportunity` is a statement
    /// about the session window specifically — a weekly window measured in days
    /// is never the thing that is about to be lost.
    var readySources: Set<MenuBarQuotaSource> {
        Set(
            MenuBarQuotaSource.allCases.filter { source in
                source.kind == .session
                    && isEnabled(source.provider)
                    && coordinator(for: source.provider).burnOpportunity != nil
            }
        )
    }

    // Compatibility conveniences for the selected meter.
    var state: UsageState { coordinator(for: selectedProvider).state }
    var isStale: Bool { coordinator(for: selectedProvider).isStale }
    var isRefreshing: Bool { coordinator(for: selectedProvider).isRefreshing }
    var burnOpportunity: BurnOpportunity? { coordinator(for: selectedProvider).burnOpportunity }
    var lastUpdatedText: String { coordinator(for: selectedProvider).lastUpdatedText }
    func projection(for window: UsageWindow) -> UsageProjection? {
        let provider: TokenmaxProvider = window.id.hasPrefix("codex.") ? .codex : .claudeCode
        return coordinator(for: provider).projection(for: window)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // No `.dropFirst()` here, unlike `NotificationCoordinator`: `@Published`
        // republishes its current value on subscribe, and that first delivery
        // *is* the initial start. `start()`/`stop()` on the children are both
        // idempotent, so this subscription is the whole lifecycle.
        settingsStore.$settings
            .map { Set($0.enabledProviders) }
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.apply(enabled: enabled) }
            }
            .store(in: &cancellables)
    }

    private func apply(enabled: Set<TokenmaxProvider>) {
        for provider in TokenmaxProvider.allCases {
            let child = coordinator(for: provider)
            if enabled.contains(provider) { child.start() } else { child.stop() }
        }
    }

    func popoverOpened() { for p in enabledProviders { coordinator(for: p).popoverOpened() } }
    func popoverClosed() { for p in enabledProviders { coordinator(for: p).popoverClosed() } }
    func refresh(
        reason: String,
        manual: Bool = false,
        retryDeniedKeychainAccess: Bool = false,
        provider: TokenmaxProvider? = nil
    ) async {
        await coordinator(for: provider ?? selectedProvider).refresh(
            reason: reason,
            manual: manual,
            retryDeniedKeychainAccess: retryDeniedKeychainAccess
        )
    }

    /// True while *any* enabled provider is in flight, so a control that acts on
    /// all of them reports honestly instead of tracking only the selected one.
    var isRefreshingAny: Bool {
        enabledProviders.contains { coordinator(for: $0).isRefreshing }
    }

    /// Backs the popover's footer button, which sits below every provider
    /// section and so must refresh every one of them. Concurrently: they hit
    /// different endpoints and each enforces its own request floor.
    func refreshAll(
        reason: String,
        manual: Bool = false,
        retryDeniedKeychainAccess: Bool = false
    ) async {
        let tasks = enabledProviders.map { provider in
            Task { @MainActor in
                await self.coordinator(for: provider).refresh(
                    reason: reason,
                    manual: manual,
                    retryDeniedKeychainAccess: retryDeniedKeychainAccess
                )
            }
        }
        for task in tasks { await task.value }
    }
    /// Previews on whichever meter is actually on screen — the glow is a
    /// menu-bar setting, and the menu bar may not be showing Claude.
    func previewBurnGlow(seconds: TimeInterval = 8) {
        coordinator(for: selectedProvider).previewBurnGlow(seconds: seconds)
    }
    func nextNetworkRefreshAllowedAt(for provider: TokenmaxProvider) async -> Date {
        await coordinator(for: provider).nextNetworkRefreshAllowedAt()
    }
}
