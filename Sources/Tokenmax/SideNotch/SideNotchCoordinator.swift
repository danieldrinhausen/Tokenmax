import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Owns the two focus-free panels and translates pointer tracking into the
/// pure `SideNotchDecision` state machine. The panels never become key, so a
/// glance at quota cannot steal typing from the app underneath it.
@MainActor
final class SideNotchCoordinator: ObservableObject {
    @Published private(set) var state: SideNotchState = .peek
    @Published private(set) var suppression: SideNotchSuppressionReason? = .disabled

    let settingsStore: SettingsStore
    let usage: ProviderUsageCoordinator
    let notifications: NotificationCoordinator

    private var railPanel: SideNotchPanel?
    private var detailPanel: SideNotchPanel?
    private var currentScreen: NSScreen?
    private var sessionIsActive = true
    private var pointerInsideRail = false
    private var pointerInsideDetail = false
    private var closeWorkItem: DispatchWorkItem?
    private var screenTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var refreshSurfaceIsOpen = false

    /// The collapsed window is wider than what it draws. That invisible margin
    /// buys a humane hover target without turning the edge mark into a tab.
    private static let peekSize = NSSize(width: 16, height: 72)
    private static let railWidth: CGFloat = 76
    private static let railHeaderHeight: CGFloat = 22
    private static let providerRowHeight: CGFloat = 64
    private static let closeDelay: TimeInterval = 0.4

    init(
        settingsStore: SettingsStore,
        usage: ProviderUsageCoordinator,
        notifications: NotificationCoordinator
    ) {
        self.settingsStore = settingsStore
        self.usage = usage
        self.notifications = notifications
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        settingsStore.$settings
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.reevaluate()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        usage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        notifications.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        observeWorkspace()
        startScreenTimer()
        reevaluate()
    }

    var presentations: [SideNotchProviderPresentation] {
        let settings = settingsStore.settings
        return SideNotchPresentation.make(
            layout: settings.effectiveMenuBarRings,
            enabledProviders: settings.enabledProviders,
            snapshot: { usage.snapshot(for: $0) },
            isStale: { usage.isStale(for: $0) },
            alerting: notifications.alertingSources,
            ready: usage.readySources,
            colors: settings.effectiveSideNotchColors,
            now: usage.tick,
            projection: { usage.projection(for: $0) },
            reminderStatus: { notifications.status(for: $0, kind: $1) }
        )
    }

    var selectedPresentation: SideNotchProviderPresentation? {
        guard let provider = state.selectedProvider else { return nil }
        return presentations.first { $0.provider == provider }
    }

    func pointerEnteredHandle() {
        pointerInsideRail = true
        cancelClose()
        currentScreen = screenUnderPointer() ?? currentScreen
        transition(.pointerEnteredHandle)
    }

    func pointerEnteredRail() {
        pointerInsideRail = true
        cancelClose()
        transition(.pointerEnteredRail)
    }

    func pointerExitedRail() {
        pointerInsideRail = false
        scheduleCloseIfOutside()
    }

    func pointerEnteredProvider(_ provider: TokenmaxProvider) {
        pointerInsideRail = true
        cancelClose()
        transition(.pointerEnteredProvider(provider))
    }

    func providerClicked(_ provider: TokenmaxProvider) {
        cancelClose()
        transition(.providerClicked(provider))
    }

    func pointerEnteredDetail() {
        pointerInsideDetail = true
        cancelClose()
    }

    func pointerExitedDetail() {
        pointerInsideDetail = false
        scheduleCloseIfOutside()
    }

    func toggleMenuBarItem() {
        settingsStore.settings.showMenuBarItem.toggle()
    }

    func refreshFromContextMenu() {
        Task {
            await usage.refreshAll(
                reason: "side notch menu",
                manual: true,
                retryDeniedKeychainAccess: true
            )
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func transition(_ event: SideNotchEvent) {
        let next = SideNotchDecision.reduce(state, event: event)
        guard next != state else { return }
        state = next
        applyPanelState()
    }

    private func scheduleCloseIfOutside() {
        guard !pointerInsideRail, !pointerInsideDetail else { return }
        cancelClose()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.pointerInsideRail, !self.pointerInsideDetail else { return }
                self.transition(.closeDelayElapsed)
            }
        }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: item)
    }

    private func cancelClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
    }

    private func reevaluate() {
        let screen = screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        currentScreen = currentScreen.flatMap { old in
            NSScreen.screens.first { $0 === old }
        } ?? screen
        let reason = SideNotchDecision.suppression(
            enabled: settingsStore.settings.sideNotch.enabled,
            sessionIsActive: sessionIsActive,
            screenIsAvailable: currentScreen != nil
        )

        if let reason {
            if suppression != reason {
                Log.shared.write("side notch: hidden — \(reason.explanation)")
            }
            suppression = reason
            hidePanels()
            return
        }

        ensurePanels()
        if let selected = state.selectedProvider,
           !presentations.contains(where: { $0.provider == selected }) {
            state = .rail
        }
        applyPanelState()
    }

    private func ensurePanels() {
        guard railPanel == nil else { return }

        let rail = SideNotchPanel()
        rail.contentView = NSHostingView(rootView: SideNotchRailView(coordinator: self))
        railPanel = rail

        let detail = SideNotchPanel()
        detail.hasShadow = true
        detail.contentView = NSHostingView(rootView: SideNotchDetailView(coordinator: self))
        detailPanel = detail
    }

    private func applyPanelState() {
        guard settingsStore.settings.sideNotch.enabled, sessionIsActive, let screen = currentScreen else {
            hidePanels()
            return
        }

        if suppression != nil {
            Log.shared.write("side notch: visible on \(screen.localizedName)")
        }
        suppression = nil
        let providerCount = max(1, presentations.count)
        let expandedHeight = Self.railHeaderHeight + CGFloat(providerCount) * Self.providerRowHeight
        let size = state == .peek
            ? Self.peekSize
            : NSSize(width: Self.railWidth, height: expandedHeight)
        let railFrame = NSRect(
            x: screen.visibleFrame.maxX - size.width,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        if state == .peek {
            detailPanel?.orderOut(nil)
        } else if let selected = state.selectedProvider,
                  let index = presentations.firstIndex(where: { $0.provider == selected }) {
            let presentation = presentations[index]
            let dimensions = SideNotchDetailLayout.dimensions(for: presentation)
            let detailSize = NSSize(width: dimensions.width, height: dimensions.height)
            let cellCenterFromTop = Self.railHeaderHeight
                + CGFloat(index) * Self.providerRowHeight
                + Self.providerRowHeight / 2
            let targetCenterY = railFrame.maxY - cellCenterFromTop
            let detailY = min(
                screen.visibleFrame.maxY - detailSize.height,
                max(screen.visibleFrame.minY, targetCenterY - detailSize.height / 2)
            )
            let detailFrame = NSRect(
                x: railFrame.minX - detailSize.width,
                y: detailY,
                width: detailSize.width,
                height: detailSize.height
            )
            showDetail(frame: detailFrame)
        } else {
            detailPanel?.orderOut(nil)
        }

        animateRail(to: railFrame)
        railPanel?.orderFrontRegardless()
        updateRefreshSurface(open: state != .peek)
    }

    private func animateRail(to frame: NSRect) {
        guard let railPanel else { return }
        if railPanel.frame.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            railPanel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            railPanel.animator().setFrame(frame, display: true)
        }
    }

    private func showDetail(frame: NSRect) {
        guard let detailPanel else { return }
        let wasVisible = detailPanel.isVisible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if wasVisible, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                detailPanel.animator().setFrame(frame, display: true)
            }
        } else {
            detailPanel.setFrame(frame, display: true)
        }
        detailPanel.orderFrontRegardless()

        guard !wasVisible, !reduceMotion else {
            detailPanel.alphaValue = 1
            return
        }
        detailPanel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailPanel.animator().alphaValue = 1
        }
    }

    private func hidePanels() {
        cancelClose()
        pointerInsideRail = false
        pointerInsideDetail = false
        if state != .peek { state = .peek }
        railPanel?.orderOut(nil)
        detailPanel?.orderOut(nil)
        updateRefreshSurface(open: false)
    }

    private func updateRefreshSurface(open: Bool) {
        guard open != refreshSurfaceIsOpen else { return }
        refreshSurfaceIsOpen = open
        if open { usage.sideNotchOpened() } else { usage.sideNotchClosed() }
    }

    private func startScreenTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .peek else { return }
                let screen = self.screenUnderPointer()
                if !Self.sameScreen(screen, self.currentScreen) {
                    self.currentScreen = screen
                    self.reevaluate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func sameScreen(_ lhs: NSScreen?, _ rhs: NSScreen?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs === rhs
        default: false
        }
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionIsActive = false
                self?.reevaluate()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionIsActive = true
                self?.reevaluate()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionIsActive = false
                self?.reevaluate()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessionIsActive = true
                self?.reevaluate()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        })
    }
}

/// A borderless panel that participates in every Space without ever becoming
/// the app's active window.
private final class SideNotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
