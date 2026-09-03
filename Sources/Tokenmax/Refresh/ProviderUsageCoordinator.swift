import Combine
import Foundation

/// Keeps provider refresh work behind one environment object, and owns which
/// providers are polled at all.
@MainActor
final class ProviderUsageCoordinator: ObservableObject {
    /// The shared one-second clock. Held here so there is one of them, and
    /// exposed so a view that genuinely counts down can observe it *instead of*
    /// this coordinator — see `CountdownClock` for why that distinction is the
    /// difference between an idle app and a saturated one.
    let clock = CountdownClock()
    let claude: UsageRefreshCoordinator
    let codex: UsageRefreshCoordinator
    private let settingsStore: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var activeSurfaces: Set<UsageRefreshSurface> = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        claude = UsageRefreshCoordinator(settingsStore: settingsStore)
        codex = UsageRefreshCoordinator(
            provider: CodexProvider(), settingsStore: settingsStore,
            snapshotURL: FileLocations.codexUsageSnapshotFile
        )

        // A reading on either child is a change to what this object reports,
        // so it has to reach the views. This forward used to carry the
        // per-second tick as well, which is what made a settings pane rebuild
        // four times a second — twice per provider, once for the forwarded
        // change and once for the mirrored `@Published tick`. With the clock
        // out of the children this fires only on real state changes.
        claude.objectWillChange.merge(with: codex.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
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

        // One clock for both providers. Sourcing it from a provider would mean
        // that disabling that provider froze every countdown in the app, plus
        // auto-run and the session opener, leaving something that looks alive
        // and is not.
        clock.start()
        clock.$now
            .sink { [weak self] now in
                guard let self else { return }
                for provider in TokenmaxProvider.allCases {
                    self.coordinator(for: provider).advance(to: now)
                }
            }
            .store(in: &cancellables)

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
            if enabled.contains(provider) {
                child.start()
                for surface in activeSurfaces { child.surfaceOpened(surface) }
            } else {
                child.stop()
            }
        }
    }

    func popoverOpened() { surfaceOpened(.popover) }
    func popoverClosed() { surfaceClosed(.popover) }
    func sideNotchOpened() { surfaceOpened(.sideNotch) }
    func sideNotchClosed() { surfaceClosed(.sideNotch) }

    private func surfaceOpened(_ surface: UsageRefreshSurface) {
        guard activeSurfaces.insert(surface).inserted else { return }
        for provider in enabledProviders { coordinator(for: provider).surfaceOpened(surface) }
    }

    private func surfaceClosed(_ surface: UsageRefreshSurface) {
        guard activeSurfaces.remove(surface) != nil else { return }
        for provider in enabledProviders { coordinator(for: provider).surfaceClosed(surface) }
    }
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
