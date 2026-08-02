import AppKit
import Testing
import UserNotifications

@testable import Tokenmax

@Suite("Notification icon attachment")
struct NotificationIconTests {
    @Test("The app icon can be attached to a notification")
    func attachmentIsProduced() throws {
        let attachment = try #require(
            NotificationIcon.attachment(),
            "the app bundle should always yield an icon to attach"
        )
        #expect(attachment.identifier == NotificationIcon.attachmentIdentifier)
    }

    /// `UNNotificationAttachment` moves the file it is handed into its own
    /// store. Handing over the cached PNG directly would work exactly once and
    /// then silently stop — every reminder after the first would arrive bare.
    @Test("A second notification still gets an icon")
    func attachmentSurvivesRepeatedUse() throws {
        let first = NotificationIcon.attachment()
        let second = NotificationIcon.attachment()
        let third = NotificationIcon.attachment()

        #expect(first != nil)
        #expect(second != nil)
        #expect(third != nil)
    }

    @Test("The rendered icon is a real image, not a blank square")
    func renderedIconHasContent() throws {
        // Producing an attachment is what renders the cached PNG.
        _ = NotificationIcon.attachment()

        let cached = FileLocations.supportDirectory.appendingPathComponent("notification-icon.png")
        let data = try #require(
            try? Data(contentsOf: cached),
            "attaching an icon should leave a reusable PNG behind"
        )
        let image = try #require(NSBitmapImageRep(data: data))

        #expect(image.pixelsWide == 256)
        #expect(image.pixelsHigh == 256)

        // A fully transparent bitmap would satisfy every check above while
        // showing nothing at all in the banner.
        var opaquePixels = 0
        for x in stride(from: 0, to: image.pixelsWide, by: 8) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 8) {
                if let colour = image.colorAt(x: x, y: y), colour.alphaComponent > 0.5 {
                    opaquePixels += 1
                }
            }
        }
        #expect(opaquePixels > 100, "the icon rendered essentially empty")
    }

    /// The attachment is decoration. A reminder that arrives plain is enormously
    /// better than one that does not arrive.
    @Test("Attaching never replaces existing content")
    func attachingLeavesContentIntact() {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code window ending soon"
        content.body = "Your five-hour window resets in 42m."

        NotificationIcon.attach(to: content)

        #expect(content.title == "Claude Code window ending soon")
        #expect(content.body == "Your five-hour window resets in 42m.")
        #expect(content.attachments.count <= 1)
    }
}
