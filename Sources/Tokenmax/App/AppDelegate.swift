import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindowCount = 0

    private var appearanceObserver: NSKeyValueObservation?

    private var menuBarContextMenu: MenuBarContextMenu?

    /// Called from the menubar label's `onAppear`, which is where the stores it
    /// needs are in scope. Held here so it outlives that view and so the event
    /// monitor is torn down with the app rather than leaked per redraw.
    func installMenuBarContextMenu(settingsStore: SettingsStore, usage: ProviderUsageCoordinator) {
        guard menuBarContextMenu == nil else { return }
        let menu = MenuBarContextMenu(settingsStore: settingsStore, usage: usage)
        menu.install()
        menuBarContextMenu = menu
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Menubar-only: no Dock icon, no ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        Log.shared.write("launched Tokenmax \(AppInfo.version) (\(AppInfo.build))")
        // Keychain grants are keyed to this hash. A different value than the
        // previous launch line means macOS treats this as a new program and
        // will ask consent again — the expected once-per-build prompt.
        Log.shared.write("launch: cdhash \(CodeIdentity.cdhash ?? "unknown") — keychain consent is keyed to this; a changed hash means one new prompt")

        // A meter that has abandoned templating resolves its neutral against
        // the current appearance, so cached images have to be thrown away when
        // the user switches appearance or the icon keeps the old colour.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in
                MenuBarIconRenderer.invalidateCache()
                NotificationCenter.default.post(name: .tokenmaxAppearanceChanged, object: nil)
            }
        }
    }

    /// An `.accessory` app cannot bring a real window forward, so flip to
    /// `.regular` while any window is open and back again afterwards.
    func windowDidOpen() {
        openWindowCount += 1
        if openWindowCount == 1 {
            NSApp.setActivationPolicy(.regular)
        }
        raise()
    }

    /// Raising is for every window that opens, not only the first. The count is
    /// already at one whenever the queue window is up, so tying this to `== 1`
    /// meant a second window never asked to come forward at all.
    ///
    /// The order of the three calls below is the whole fix, and it was arrived
    /// at by measurement rather than reasoning. Opening a window while the app
    /// is still `.accessory` put it *behind* the frontmost app every time;
    /// opening one while a window was already up worked every time. Since macOS
    /// 14 activation is cooperative: an app that is not already frontmost is not
    /// granted focus merely for asking, and `ignoringOtherApps` no longer
    /// overrides that. The app only becomes eligible once the switch to
    /// `.regular` has settled — a pass too late for the window that caused it.
    ///
    /// So the window is ordered up *before* the app is activated.
    /// `orderFrontRegardless` is the one call not subject to cooperative
    /// activation, and with the window already on top the subsequent `activate`
    /// is granted. Activating first and ordering after leaves the window visible
    /// but the app unfocused — measurably, the same code in the other order gets
    /// the stacking right and the keyboard focus wrong.
    ///
    /// The sweep covers every window this app owns rather than the one that just
    /// opened, because `onAppear` does not say which that was. Back to front, so
    /// the app's own stacking order survives it.
    private func raise() {
        Task { @MainActor in
            // Let the click's contextual menu finish dismissing and let an
            // accessory-to-regular policy change settle before competing for
            // key focus.
            await Task.yield()
            let keyCandidate = NSApp.orderedWindows.first {
                $0.isVisible && $0.canBecomeKey
            }
            for window in NSApp.orderedWindows.reversed()
            where window.isVisible && window.canBecomeMain {
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            keyCandidate?.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidClose() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
