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
    func configure(makeContentController: @escaping () -> NSViewController) {
        guard self.makeContentController == nil else { return }
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
            (NSApp.delegate as? AppDelegate)?.windowDidOpen()
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
        (NSApp.delegate as? AppDelegate)?.windowDidClose()
    }

    private func makeWindow() -> NSWindow {
        guard let makeContentController else { preconditionFailure("Settings content was not configured") }
        let window = NSWindow(contentViewController: makeContentController())
        window.title = "Tokenmax Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 600)
        window.setFrameAutosaveName("TokenmaxSettings")
        window.center()
        window.delegate = self
        self.window = window
        return window
    }
}
