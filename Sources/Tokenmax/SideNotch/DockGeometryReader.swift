import AppKit
import ApplicationServices

/// Reads the public Accessibility representation of the Dock list. Its frame
/// is the only live geometry that includes running and minimized items; Dock
/// preferences alone cannot describe either, so an item-count estimate drifts.
@MainActor
enum DockGeometryReader {
    static func screenHostingDock() -> NSScreen? {
        if let frame = accessibilityFrame() {
            return NSScreen.screens.first { $0.frame.intersects(frame) }
        }

        // A bottom Dock reserves the lower strip of its display. This remains
        // available when Tokenmax has not been granted Accessibility access.
        return NSScreen.screens.max { lhs, rhs in
            bottomInset(of: lhs) < bottomInset(of: rhs)
        }.flatMap { bottomInset(of: $0) > 0 ? $0 : NSScreen.main }
    }

    static func frame(on screen: NSScreen) -> CGRect? {
        if let frame = accessibilityFrame(), frame.intersects(screen.frame) {
            return frame
        }
        return estimatedFrame(on: screen)
    }

    private static func accessibilityFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier else { return nil }

        let application = AXUIElementCreateApplication(pid)
        guard let children = attribute(application, kAXChildrenAttribute) as? [AXUIElement],
              let dock = children.first(where: { role(of: $0) == kAXListRole }),
              let position = pointAttribute(dock, kAXPositionAttribute),
              let size = sizeAttribute(dock, kAXSizeAttribute),
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }

        // Accessibility uses a top-left global origin; AppKit uses bottom-left.
        let frame = CGRect(
            x: position.x,
            y: primaryTop - position.y - size.height,
            width: size.width,
            height: size.height
        )
        return frame
    }

    /// The running regular apps the Dock would show a tile for, recomputed only
    /// when that set can actually have changed.
    ///
    /// `estimatedFrame` is called from the Side Notch's half-second geometry
    /// poll, so this enumerated every running application twice a second, for
    /// the life of the app, to answer a question whose answer changes when you
    /// launch or quit something — about 1% of a core, permanently. AppKit
    /// already announces every event that can move it.
    ///
    /// Activation is observed too because an app may switch activation policy
    /// after launch, which is otherwise invisible here and used to be caught by
    /// the poll. The cache and its observers live for the life of the process,
    /// which is the life of the Dock reader.
    private static var cachedRunningRegularApps: Set<String>?
    private static var runningAppObservers: [NSObjectProtocol] = []

    private static func runningRegularApps() -> Set<String> {
        if let cachedRunningRegularApps { return cachedRunningRegularApps }

        if runningAppObservers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            for name: NSNotification.Name in [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didActivateApplicationNotification,
            ] {
                runningAppObservers.append(
                    workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                        Task { @MainActor in cachedRunningRegularApps = nil }
                    }
                )
            }
        }

        let apps = Set(
            NSWorkspace.shared.runningApplications.compactMap { application in
                application.activationPolicy == .regular ? application.bundleIdentifier : nil
            }
        )
        cachedRunningRegularApps = apps
        return apps
    }

    private static func bottomInset(of screen: NSScreen) -> CGFloat {
        max(0, screen.visibleFrame.minY - screen.frame.minY)
    }

    /// Accessibility can be unavailable without making Dock placement useless.
    /// Reconstruct the centred span from the same persisted tiles plus running
    /// regular apps that the Dock uses. One tile of breathing room accounts for
    /// transient minimized windows without risking overlap with the Dock.
    private static func estimatedFrame(on screen: NSScreen) -> CGRect? {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock") else { return nil }
        let persistentApps = defaults.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let persistentIdentifiers = Set(persistentApps.compactMap { entry in
            let data = entry["tile-data"] as? [String: Any]
            return data?["bundle-identifier"] as? String
        })
        let runningExtras = defaults.bool(forKey: "static-only")
            ? 0
            : runningRegularApps().subtracting(persistentIdentifiers).count
        let apps = persistentApps.count + runningExtras
        let others = defaults.array(forKey: "persistent-others")?.count ?? 0
        let recent = defaults.bool(forKey: "show-recents")
            ? (defaults.array(forKey: "recent-apps")?.count ?? 0)
            : 0
        let storedTileSize = defaults.double(forKey: "tilesize")
        let tileSize = storedTileSize > 0 ? storedTileSize : 48
        let pitch = tileSize + 2
        let separators = 18 * (recent > 0 ? 2.0 : 1.0)
        let minimizedWindowAllowance = pitch
        let width = CGFloat(apps + others + recent + 1) * pitch
            + separators
            + minimizedWindowAllowance
            + 6
        let height = tileSize + 14
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.minY + 10,
            width: min(screen.frame.width, width),
            height: height
        )
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name) as! AXValue?, AXValueGetType(value) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name) as! AXValue?, AXValueGetType(value) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
