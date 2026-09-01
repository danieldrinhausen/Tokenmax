import SwiftUI

enum TokenmaxWindow {
    static let queue = "tokenmax.queue"
}

@main
struct TokenmaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settingsStore: SettingsStore
    @StateObject private var taskStore: TaskStore
    @StateObject private var usage: ProviderUsageCoordinator
    @StateObject private var notificationManager: NotificationManager
    @StateObject private var notificationCoordinator: NotificationCoordinator
    @StateObject private var sideNotch: SideNotchCoordinator
    @StateObject private var resetCelebration: QuotaResetCelebrationCoordinator
    @StateObject private var sessionOpener: SessionOpenerCoordinator
    @StateObject private var autoRun: QueueAutoRunCoordinator
    @StateObject private var modelCatalog: ModelCatalogStore
    @StateObject private var codexModelCatalog: CodexModelCatalogStore
    @StateObject private var updates: UpdateCheckCoordinator
    @StateObject private var settingsWindow: SettingsWindowController

    init() {
        let settingsStore = SettingsStore()
        let taskStore = TaskStore()
        let usage = ProviderUsageCoordinator(settingsStore: settingsStore)
        let notificationManager = NotificationManager()
        let notificationCoordinator = NotificationCoordinator(
            manager: notificationManager,
            usage: usage,
            taskStore: taskStore,
            settingsStore: settingsStore
        )
        let resetCelebration = QuotaResetCelebrationCoordinator(usage: usage, settingsStore: settingsStore)
        let sideNotch = SideNotchCoordinator(
            settingsStore: settingsStore,
            usage: usage,
            notifications: notificationCoordinator
        )
        let sessionOpener = SessionOpenerCoordinator(usage: usage.claude, settingsStore: settingsStore)
        let autoRun = QueueAutoRunCoordinator(
            usage: usage,
            taskStore: taskStore,
            settingsStore: settingsStore
        )
        let modelCatalog = ModelCatalogStore()
        let codexModelCatalog = CodexModelCatalogStore()
        let updates = UpdateCheckCoordinator(settingsStore: settingsStore)
        let settingsWindow = SettingsWindowController()

        _settingsStore = StateObject(wrappedValue: settingsStore)
        _taskStore = StateObject(wrappedValue: taskStore)
        _usage = StateObject(wrappedValue: usage)
        _notificationManager = StateObject(wrappedValue: notificationManager)
        _notificationCoordinator = StateObject(wrappedValue: notificationCoordinator)
        _sideNotch = StateObject(wrappedValue: sideNotch)
        _resetCelebration = StateObject(wrappedValue: resetCelebration)
        _sessionOpener = StateObject(wrappedValue: sessionOpener)
        _autoRun = StateObject(wrappedValue: autoRun)
        _modelCatalog = StateObject(wrappedValue: modelCatalog)
        _codexModelCatalog = StateObject(wrappedValue: codexModelCatalog)
        _updates = StateObject(wrappedValue: updates)
        _settingsWindow = StateObject(wrappedValue: settingsWindow)

        // The status item is optional now, so it can no longer own app
        // startup. Deferred one main-runloop pass to let SwiftUI install the
        // StateObjects before their first published changes arrive. The test
        // host constructs this App too; starting production coordinators there
        // would escape the suite's otherwise isolated fixtures.
        if !RuntimeEnvironment.isTesting {
            Task { @MainActor in
                usage.start()
                notificationCoordinator.start()
                sideNotch.start()
                resetCelebration.start()
                sessionOpener.start()
                autoRun.start()
                updates.start()
                // Asked while the user is present, never when an unattended task
                // first discovers a protected project directory.
                WorkingDirectoryAccess.requestAccess(for: taskStore.tasks)
            }
        }
    }

    var body: some Scene {
        // `body` runs even when the menu bar item is intentionally hidden.
        // That lets a Side-Notch-only launch still open Settings from its own
        // context menu, using these installed shared objects.
        let environment = sharedEnvironment
        let _ = settingsWindow.configure {
            NSHostingController(rootView: SettingsView().modifier(environment))
        }

        MenuBarExtra(isInserted: menuBarItemBinding) {
            MenuBarPopoverView()
                .modifier(sharedEnvironment)
                .onAppear { usage.popoverOpened() }
                .onDisappear { usage.popoverClosed() }
        } label: {
            MenuBarLabel(
                mode: settingsStore.settings.menuBarDisplayMode,
                model: MenuBarIconModel.make(
                    // The *effective* layout: a disabled provider keeps its slot
                    // in the stored settings but must not be drawn.
                    layout: settingsStore.settings.effectiveMenuBarLayout,
                    countdownSource: settingsStore.settings.effectiveCountdownSource,
                    snapshot: { usage.snapshot(for: $0) },
                    isStale: { usage.isStale(for: $0) },
                    alerting: notificationCoordinator.alertingSources,
                    ready: usage.readySources
                ),
                now: usage.tick,
                isHighlighted: usage.burnOpportunity != nil,
                highlight: settingsStore.settings.menuBarHighlightColor,
                glow: settingsStore.settings.menuBarHighlightGlow,
                escalation: settingsStore.settings.effectiveEscalation
            )
            .onAppear {
                // Here rather than in `applicationDidFinishLaunching` because
                // the stores live in this struct, and because the status item
                // it watches for does not exist until this scene has been built.
                appDelegate.installMenuBarContextMenu(settingsStore: settingsStore, usage: usage)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Tokenmax Queue", id: TokenmaxWindow.queue) {
            QueueView()
                .modifier(sharedEnvironment)
                .onAppear { appDelegate.windowDidOpen() }
                .onDisappear { appDelegate.windowDidClose() }
        }
        // Wide enough for both filter groups and the search field to sit on one
        // row without the queue opening in a state the user has to resize their
        // way out of.
        .defaultSize(width: 860, height: 620)

    }

    private var sharedEnvironment: SharedEnvironment {
        SharedEnvironment(
            settingsStore: settingsStore,
            taskStore: taskStore,
            usage: usage,
            notificationManager: notificationManager,
            notificationCoordinator: notificationCoordinator,
            sideNotch: sideNotch,
            resetCelebration: resetCelebration,
            sessionOpener: sessionOpener,
            autoRun: autoRun,
            modelCatalog: modelCatalog,
            codexModelCatalog: codexModelCatalog,
            updates: updates
        )
    }

    private var menuBarItemBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.showMenuBarItem },
            set: { sceneState in
                let retained = MenuBarItemDecision.persistedVisibility(
                    afterSceneReconciliation: sceneState,
                    currentUserChoice: settingsStore.settings.showMenuBarItem
                )
                // Settings and Side Notch own the persisted intent. The scene
                // binding only reports lifecycle output and must not reverse it.
                guard retained != settingsStore.settings.showMenuBarItem else { return }
                settingsStore.settings.showMenuBarItem = retained
            }
        )
    }
}

/// Injects the shared stores into every scene without repeating four modifiers.
struct SharedEnvironment: ViewModifier {
    let settingsStore: SettingsStore
    let taskStore: TaskStore
    let usage: ProviderUsageCoordinator
    let notificationManager: NotificationManager
    let notificationCoordinator: NotificationCoordinator
    let sideNotch: SideNotchCoordinator
    let resetCelebration: QuotaResetCelebrationCoordinator
    let sessionOpener: SessionOpenerCoordinator
    let autoRun: QueueAutoRunCoordinator
    let modelCatalog: ModelCatalogStore
    let codexModelCatalog: CodexModelCatalogStore
    let updates: UpdateCheckCoordinator

    func body(content: Content) -> some View {
        content
            .environmentObject(settingsStore)
            .environmentObject(taskStore)
            .environmentObject(usage)
            // Claude-only opener settings deliberately keep their narrowly
            // typed dependency while the rest of the app uses both providers.
            .environmentObject(usage.claude)
            .environmentObject(notificationManager)
            .environmentObject(notificationCoordinator)
            .environmentObject(sideNotch)
            .environmentObject(resetCelebration)
            .environmentObject(sessionOpener)
            .environmentObject(autoRun)
            .environmentObject(modelCatalog)
            .environmentObject(codexModelCatalog)
            .environmentObject(updates)
    }
}

/// The menubar item itself. `MenuBarExtra` renders a `Label`, so the meter
/// glyph is drawn into an `NSImage` and handed over as the icon.
private struct MenuBarLabel: View {
    let mode: MenuBarDisplayMode
    let model: MenuBarIconModel
    /// `usage.tick` — advances every second so the countdown stays live.
    let now: Date
    let isHighlighted: Bool
    let highlight: HighlightColor
    let glow: Bool
    let escalation: MenuBarEscalation?

    @Environment(\.openWindow) private var openWindow

    /// Forces a re-render when the system appearance flips, since the bar
    /// colour resolves differently in light and dark.
    @State private var appearanceGeneration = 0

    var body: some View {
        Group {
            switch mode {
            case .iconOnly:
                animatedIcon
            case .textOnly:
                // Never allowed to be empty — a blank menu bar item would be
                // invisible and unclickable.
                Text(text ?? "--")
            case .iconAndText:
                HStack(spacing: 3) {
                    animatedIcon
                    if let text {
                        Text(text)
                    }
                }
            }
        }
        // "Open Queue" from a notification banner arrives here while the
        // status item exists, since this view has access to `openWindow`.
        .onReceive(NotificationCenter.default.publisher(for: .tokenmaxOpenQueue)) { _ in
            openWindow(id: TokenmaxWindow.queue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenmaxAppearanceChanged)) { _ in
            appearanceGeneration &+= 1
        }
        .id(appearanceGeneration)
    }

    /// Neutral by default, lit in the configured highlight colour while it is a
    /// good moment to spend quota. Redraws only when the reading itself changes.
    private var animatedIcon: some View {
        Image(nsImage: MenuBarIconRenderer.cachedImage(
            style: model.style,
            meters: model.meters,
            isStale: model.isStale,
            highlight: highlight,
            glow: glow,
            escalation: escalation
        ))
    }

    /// Text-only users get no glow, so the opportunity is marked with a bolt.
    /// `nil` while the window it follows is not running.
    private var text: String? {
        // A stale reset timestamp is useful for diagnostics, but not as a
        // live deadline. Keep the menu bar honest instead of showing a precise
        // countdown beside a stale-data indicator.
        guard !model.countdownIsStale,
              let countdown = MenuBarIconRenderer.countdownText(
                resetAt: model.countdownResetAt, now: now
              )
        else { return nil }
        return isHighlighted && mode == .textOnly ? "⚡︎ \(countdown)" : countdown
    }
}
