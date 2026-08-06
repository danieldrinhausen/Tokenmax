import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindowCount = 0

    private var appearanceObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_: Notification) {
        // Menubar-only: no Dock icon, no ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.shared.write("launched Tokenmax \(version)")

        // Bar colour is `labelColor`, which resolves to white on a dark menu
        // bar and black on a light one. Cached images have to be thrown away
        // when the user switches appearance or the icon keeps the old colour.
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

    /// Activation belongs to every window that opens, not only the first. The
    /// count is already at one whenever the queue window is up, so tying this
    /// to `== 1` meant Settings opened from the popover never asked to come
    /// forward at all — it was placed behind whatever the user had in front.
    ///
    /// Twice, deliberately. The `.accessory` → `.regular` switch is not in
    /// effect for the rest of the runloop pass that requests it, and an
    /// `activate` issued inside that same pass can be dropped. The second call
    /// costs nothing when the first one worked and is the one that lands when
    /// it did not.
    private func raise() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
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
