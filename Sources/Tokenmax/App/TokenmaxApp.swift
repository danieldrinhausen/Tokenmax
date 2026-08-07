import SwiftUI

enum TokenmaxWindow {
    static let queue = "tokenmax.queue"
    static let settings = "tokenmax.settings"
}

@main
struct TokenmaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settingsStore: SettingsStore
    @StateObject private var taskStore: TaskStore
    @StateObject private var usage: ProviderUsageCoordinator
    @StateObject private var notificationManager: NotificationManager
    @StateObject private var notificationCoordinator: NotificationCoordinator
    @StateObject private var sessionOpener: SessionOpenerCoordinator
    @StateObject private var autoRun: QueueAutoRunCoordinator
    @StateObject private var modelCatalog = ModelCatalogStore()
    @StateObject private var codexModelCatalog = CodexModelCatalogStore()
    @StateObject private var updates: UpdateCheckCoordinator

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
        let sessionOpener = SessionOpenerCoordinator(usage: usage.claude, settingsStore: settingsStore)
        let autoRun = QueueAutoRunCoordinator(
            usage: usage,
            taskStore: taskStore,
            settingsStore: settingsStore
        )
        let updates = UpdateCheckCoordinator(settingsStore: settingsStore)

        _settingsStore = StateObject(wrappedValue: settingsStore)
        _taskStore = StateObject(wrappedValue: taskStore)
        _usage = StateObject(wrappedValue: usage)
        _notificationManager = StateObject(wrappedValue: notificationManager)
        _notificationCoordinator = StateObject(wrappedValue: notificationCoordinator)
        _sessionOpener = StateObject(wrappedValue: sessionOpener)
        _autoRun = StateObject(wrappedValue: autoRun)
        _updates = StateObject(wrappedValue: updates)
    }

    var body: some Scene {
        MenuBarExtra {
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
                    layout: settingsStore.settings.effectiveMenuBarBars,
                    countdownSource: settingsStore.settings.effectiveCountdownSource,
                    snapshot: { usage.snapshot(for: $0) },
                    isStale: { usage.isStale(for: $0) },
                    alerting: notificationCoordinator.alertingSources,
                    ready: usage.readySources
                ),
                now: usage.tick,
                isHighlighted: usage.burnOpportunity != nil,
                highlight: settingsStore.settings.menuBarHighlightColor,
                glow: settingsStore.settings.menuBarHighlightGlow
            )
            // The menubar label is the one view that exists from launch, so it
            // is where the coordinators get started.
            .onAppear {
                usage.start()
                notificationCoordinator.start()
                sessionOpener.start()
                autoRun.start()
                updates.start()
                // Here rather than in `applicationDidFinishLaunching` because
                // the stores live in this struct, and because the status item
                // it watches for does not exist until this scene has been built.
                appDelegate.installMenuBarContextMenu(settingsStore: settingsStore, usage: usage)
                // Asked now, not when a task runs. Reading a protected folder
                // raises a consent dialog that blocks until answered, and an
                // unattended run is exactly when nobody will answer it — so the
                // question has to be put while the user is still here.
                WorkingDirectoryAccess.requestAccess(for: taskStore.tasks)
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

        Window("Tokenmax Settings", id: TokenmaxWindow.settings) {
            SettingsView()
                .modifier(sharedEnvironment)
                .onAppear { appDelegate.windowDidOpen() }
                .onDisappear { appDelegate.windowDidClose() }
        }
        .windowResizability(.contentSize)
    }

    private var sharedEnvironment: SharedEnvironment {
        SharedEnvironment(
            settingsStore: settingsStore,
            taskStore: taskStore,
            usage: usage,
            notificationManager: notificationManager,
            notificationCoordinator: notificationCoordinator,
            sessionOpener: sessionOpener,
            autoRun: autoRun,
            modelCatalog: modelCatalog,
            codexModelCatalog: codexModelCatalog,
            updates: updates
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
            .environmentObject(sessionOpener)
            .environmentObject(autoRun)
            .environmentObject(modelCatalog)
            .environmentObject(codexModelCatalog)
            .environmentObject(updates)
    }
}

/// The menubar item itself. `MenuBarExtra` renders a `Label`, so the two-meter
/// glyph is drawn into an `NSImage` and handed over as the icon.
private struct MenuBarLabel: View {
    let mode: MenuBarDisplayMode
    let model: MenuBarIconModel
    /// `usage.tick` — advances every second so the countdown stays live.
    let now: Date
    let isHighlighted: Bool
    let highlight: HighlightColor
    let glow: Bool

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
        // "Open Queue" from a notification banner arrives here, since this view
        // is always alive and has access to `openWindow`.
        .onReceive(NotificationCenter.default.publisher(for: .tokenmaxOpenQueue)) { _ in
            openWindow(id: TokenmaxWindow.queue)
        }
        // Same reason: the right-click menu is AppKit and has no `openWindow`.
        .onReceive(NotificationCenter.default.publisher(for: .tokenmaxOpenSettings)) { _ in
            openWindow(id: TokenmaxWindow.settings)
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
            bars: model.bars,
            isStale: model.isStale,
            highlight: highlight,
            glow: glow
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
