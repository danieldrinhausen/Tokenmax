import AppKit
import SwiftUI

/// Owns the preferences window outside the optional menu-bar scene.
///
/// SwiftUI's Settings action reports success even when it leaves the window
/// behind another app or Space. This controller owns a normal AppKit window, so
/// every entry point can make the same concrete promise: Settings is visible
/// and key on the active Space.
@MainActor
final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var makeContentController: (() -> NSViewController)?
    private var window: NSWindow?
    private var countsAsOpenWindow = false
    /// Handed in rather than found through `NSApp.delegate`: with
    /// `@NSApplicationDelegateAdaptor` that is SwiftUI's own proxy, so
    /// `as? AppDelegate` is nil and Settings never switched the app out of
    /// `.accessory` (no Dock icon, and a window that cannot take focus).
    private weak var appDelegate: AppDelegate?
    private static let windowName = "settings"
    private static let autosaveName = "TokenmaxSettings"

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsRequested),
            name: .tokenmaxOpenSettings,
            object: nil,
        )
    }

    /// The App value can be rebuilt by SwiftUI. Configure only after its
    /// StateObjects are installed, or Settings would retain a parallel set of
    /// stores whose changes reach disk but not the live coordinators.
    func configure(appDelegate: AppDelegate, makeContentController: @escaping () -> NSViewController) {
        guard self.makeContentController == nil else { return }
        self.appDelegate = appDelegate
        self.makeContentController = makeContentController
    }

    func show() {
        guard makeContentController != nil else {
            Log.shared.write("window: Settings requested before its content was ready")
            return
        }
        let window = window ?? makeWindow()
        if !countsAsOpenWindow {
            countsAsOpenWindow = true
            appDelegate?.windowDidOpen(Self.windowName)
        }

        // A context menu can remain the active event target until this turn
        // completes. Ordering first, then activating, avoids a visible but
        // unfocused Settings window behind the frontmost app.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.shared.write("window: Settings shown")
    }

    @objc private func settingsRequested() {
        // The context menu finishes tracking only after its action returns.
        // One turn later the window can safely become key.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.show()
        }
    }

    func windowWillClose(_: Notification) {
        guard countsAsOpenWindow else { return }
        countsAsOpenWindow = false
        appDelegate?.windowDidClose(Self.windowName)
    }

    private func makeWindow() -> NSWindow {
        guard let makeContentController else { preconditionFailure("Settings content was not configured") }
        let window = NSWindow(contentViewController: makeContentController())
        window.title = "Tokenmax Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 600)
        // Centering after the autosave name is applied overwrote the frame it
        // had just restored, so the window forgot where the user left it.
        let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.autosaveName)") != nil
        window.setFrameAutosaveName(Self.autosaveName)
        if !hadSavedFrame { window.center() }
        window.delegate = self
        self.window = window
        return window
    }
}
