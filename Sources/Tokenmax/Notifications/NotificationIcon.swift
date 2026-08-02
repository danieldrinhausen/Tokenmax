import AppKit
import UserNotifications

/// Puts the Tokenmax icon on its own notifications.
///
/// The icon in a banner's leading slot is drawn by macOS from the app bundle and
/// is not something an app can set. When that slot shows the generic placeholder
/// — which it does for a bundle that gets torn down and recopied on every
/// `make install`, because the notification daemon caches its own copy keyed by
/// bundle id — there is nothing to override. An attachment is the one part of
/// the banner the app does control, so the icon travels with the notification
/// itself and no longer depends on a daemon cache being fresh.
enum NotificationIcon {
    static let attachmentIdentifier = "tokenmax-app-icon"

    /// `.icns` is not one of the types `UNNotificationAttachment` accepts, so
    /// the icon has to be handed over as a PNG. Rendered once and kept, since
    /// this runs on the path that delivers a reminder.
    private static let cachedPNG: URL? = {
        let destination = FileLocations.supportDirectory
            .appendingPathComponent("notification-icon.png")

        // Re-rendered whenever it is missing, so deleting the support directory
        // (or a future icon change) heals on the next launch rather than
        // pinning the old artwork forever.
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        // 256pt: the banner draws it far smaller, but an attachment is also what
        // the notification shows when expanded, and upscaling a 64pt icon there
        // looks like a mistake.
        let side = 256

        // Read the bundle's own `.icns` rather than `NSApp.applicationIconImage`
        // — this runs wherever a reminder happens to be built, and `NSApp` is
        // main-actor only. `NSWorkspace` covers the case of a bundle whose icon
        // resource is named something else.
        let icon: NSImage? = if let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSImage(contentsOf: icns)
        } else {
            NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }

        // Drawn into an explicit bitmap instead of via `lockFocus`, which wants
        // the main thread.
        guard let icon,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: side,
                  pixelsHigh: side,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else {
            Log.shared.write("notify: could not render the app icon for attachment")
            return nil
        }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            Log.shared.write("notify: could not encode the app icon as PNG")
            return nil
        }

        do {
            try png.write(to: destination)
            return destination
        } catch {
            Log.shared.write("notify: could not write the notification icon: \(error.localizedDescription)")
            return nil
        }
    }()

    /// A fresh attachment for one notification.
    ///
    /// `UNNotificationAttachment` **moves** the file it is given into its own
    /// store, so the cached PNG can never be handed over directly — the second
    /// notification would find it gone. Each call gets its own throwaway copy
    /// and lets the framework consume that.
    ///
    /// Returns nil rather than throwing: an icon is decoration, and a reminder
    /// that arrives plain is enormously better than one that does not arrive.
    static func attachment() -> UNNotificationAttachment? {
        guard let cachedPNG else { return nil }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-icon-\(UUID().uuidString).png")

        do {
            try FileManager.default.copyItem(at: cachedPNG, to: scratch)
            return try UNNotificationAttachment(
                identifier: attachmentIdentifier,
                url: scratch,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            Log.shared.write("notify: could not attach the app icon: \(error.localizedDescription)")
            return nil
        }
    }

    /// Adds the icon to a notification, or leaves it untouched if the icon could
    /// not be prepared.
    static func attach(to content: UNMutableNotificationContent) {
        guard let attachment = attachment() else { return }
        content.attachments = [attachment]
    }
}
