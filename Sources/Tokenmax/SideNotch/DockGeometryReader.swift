import AppKit
import ApplicationServices

/// Reads the public Accessibility representation of the Dock list. Its frame
/// is the only live geometry that includes running and minimized items; Dock
/// preferences alone cannot describe either, so an item-count estimate drifts.
@MainActor
enum DockGeometryReader {
    static func frame(on screen: NSScreen) -> CGRect? {
        accessibilityFrame(on: screen) ?? estimatedFrame(on: screen)
    }

    private static func accessibilityFrame(on screen: NSScreen) -> CGRect? {
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
        return frame.intersects(screen.frame) ? frame : nil
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
        let runningExtras = defaults.bool(forKey: "static-only") ? 0 : Set<String>(
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.activationPolicy == .regular,
                      let identifier = application.bundleIdentifier,
                      !persistentIdentifiers.contains(identifier) else { return nil }
                return identifier
            }
        ).count
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
