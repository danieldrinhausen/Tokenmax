import Testing

@testable import Tokenmax

@Suite("The Dock icon follows the set of open windows")
struct OpenWindowTrackerTests {
    @Test("The first window to open is what turns the Dock icon on, and only the first")
    func firstOpenTurnsItOn() {
        var tracker = OpenWindowTracker()
        let first = tracker.opened("queue")
        let second = tracker.opened("settings")
        #expect(first)
        #expect(!second)
    }

    @Test("A repeated appear without a disappear cannot leave the app with a Dock icon")
    func repeatedAppearIsIdempotent() {
        var tracker = OpenWindowTracker()
        _ = tracker.opened("queue")
        _ = tracker.opened("queue")
        _ = tracker.opened("queue")
        let closed = tracker.closed("queue")
        #expect(closed)
        #expect(tracker.isEmpty)
    }

    @Test("The icon goes only when the last window closes")
    func lastCloseTurnsItOff() {
        var tracker = OpenWindowTracker()
        _ = tracker.opened("queue")
        _ = tracker.opened("settings")
        let queueClosed = tracker.closed("queue")
        let settingsClosed = tracker.closed("settings")
        #expect(!queueClosed)
        #expect(settingsClosed)
    }

    @Test("Closing a window that was never counted changes nothing")
    func strayCloseIsIgnored() {
        var tracker = OpenWindowTracker()
        let beforeAnything = tracker.closed("queue")
        _ = tracker.opened("settings")
        let strayWhileOpen = tracker.closed("queue")
        #expect(!beforeAnything)
        #expect(!strayWhileOpen)
        #expect(!tracker.isEmpty)
    }
}
