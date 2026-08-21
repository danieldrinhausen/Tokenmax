import AppKit

/// What the menubar icon's right-click menu offers.
///
/// Split out from the presenting code so the one rule it has — the queue is
/// hideable, and a hidden queue must not be offered — is testable without a
/// status item to click on.
enum MenuBarContextMenuItem: String, CaseIterable {
    case settings
    case openQueue
    case refresh
    case quit

    var title: String {
        switch self {
        case .settings: "Settings…"
        case .openQueue: "Open Queue"
        case .refresh: "Refresh"
        case .quit: "Quit Tokenmax"
        }
    }

    /// In menu order. Quit sits last, where macOS puts it and where a stray
    /// click is least likely to land on it.
    static func items(queueEnabled: Bool) -> [MenuBarContextMenuItem] {
        var items: [MenuBarContextMenuItem] = [.settings]
        if queueEnabled { items.append(.openQueue) }
        items.append(contentsOf: [.refresh, .quit])
        return items
    }
}

/// Right-click, and control-click, on the menubar icon.
///
/// `MenuBarExtra` owns its status item and exposes only the primary click, so
/// there is no scene API to hang a secondary menu off. The event is instead
/// intercepted before AppKit dispatches it. A *local* monitor sees only this
/// application's own events, and the status bar window is one of ours — right
/// clicks anywhere else in the system are never observed, and any event that
/// does not resolve to our status item is handed straight back untouched.
///
/// This is also where Quit lives now. The popover used to hide it behind an
/// overflow menu next to Settings; Settings is worth a permanent button there
/// and Quit is not, so Quit moved to the place macOS menubar apps conventionally
/// keep it.
@MainActor
final class MenuBarContextMenu: NSObject {
    private let settingsStore: SettingsStore
    private let usage: ProviderUsageCoordinator

    private var monitor: Any?

    init(settingsStore: SettingsStore, usage: ProviderUsageCoordinator) {
        self.settingsStore = settingsStore
        self.usage = usage
    }

    func install() {
        guard monitor == nil else { return }
        // Control-click is the same gesture on a one-button mouse, and arrives
        // as a left click that AppKit does not translate for us.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            // A `Bool` back out rather than the event itself: `assumeIsolated`
            // requires a `Sendable` result and `NSEvent` is not one.
            let handled = MainActor.assumeIsolated { self.handle(event) }
            // Swallowed once handled, or AppKit opens the popover behind the menu.
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
              let button = Self.statusBarButton(in: event.window)
        else { return false }
        present(from: button)
        return true
    }

    /// Finding an `NSStatusBarButton` in the event's window is how a click is
    /// attributed to the menubar icon rather than to the popover or the queue
    /// window. Returning `nil` for anything else is what keeps ordinary clicks
    /// in this app working.
    ///
    /// The search is recursive because the button is not where you would first
    /// look: the window's `contentView` is an `NSStatusBarContentView`, and the
    /// button hangs below that. A one-level scan finds nothing and the menu
    /// silently never appears, which is exactly how this was first written.
    private static func statusBarButton(in window: NSWindow?) -> NSStatusBarButton? {
        guard let root = window?.contentView else { return nil }
        return descendantButton(of: root)
    }

    private static func descendantButton(of view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = descendantButton(of: subview) { return button }
        }
        return nil
    }

    private func present(from button: NSStatusBarButton) {
        let menu = NSMenu()
        // Without this every item is disabled unless something answers
        // `validateMenuItem:`, and nothing here does.
        menu.autoenablesItems = false

        for item in MenuBarContextMenuItem.items(queueEnabled: settingsStore.settings.queueEnabled) {
            if item == .quit { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            // A second refresh while one is in flight would be swallowed by the
            // per-provider request floor anyway; say so rather than no-op.
            menuItem.isEnabled = item != .refresh || !usage.isRefreshingAny
            menu.addItem(menuItem)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = MenuBarContextMenuItem(rawValue: raw)
        else { return }

        switch item {
        case .settings:
            requestWindow(.tokenmaxOpenSettings)
        case .openQueue:
            requestWindow(.tokenmaxOpenQueue)
        case .refresh:
            Task {
                await usage.refreshAll(
                    reason: "menubar menu",
                    manual: true,
                    retryDeniedKeychainAccess: true
                )
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// Windows are opened by SwiftUI's `openWindow`, which only exists inside a
    /// view — so the request is posted and the menubar label, the one view alive
    /// for the whole run, answers it. Activation stays here because it is an
    /// `NSApp` concern and has to happen either way.
    private func requestWindow(_ name: Notification.Name) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: name, object: nil)
    }
}
