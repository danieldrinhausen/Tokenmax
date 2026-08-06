import Foundation
import Testing

@testable import Tokenmax

@Suite("Menubar right-click menu")
struct MenuBarContextMenuTests {
    @Test("Every action is offered while the queue is on")
    func fullMenu() {
        #expect(MenuBarContextMenuItem.items(queueEnabled: true) == [.settings, .openQueue, .refresh, .quit])
    }

    /// Turning the queue off hides it everywhere else in the app, and a menu
    /// entry that opens a window the user has switched off would be the one
    /// place it leaked back in.
    @Test("A disabled queue is not offered")
    func queueDisabled() {
        let items = MenuBarContextMenuItem.items(queueEnabled: false)
        #expect(!items.contains(.openQueue))
        #expect(items == [.settings, .refresh, .quit])
    }

    /// Quit is the only destructive entry, so it stays pinned to the end rather
    /// than shifting up a row when the queue is off.
    @Test("Quit is last either way")
    func quitIsLast() {
        #expect(MenuBarContextMenuItem.items(queueEnabled: true).last == .quit)
        #expect(MenuBarContextMenuItem.items(queueEnabled: false).last == .quit)
    }

    @Test("Every case has a title")
    func titles() {
        for item in MenuBarContextMenuItem.allCases {
            #expect(!item.title.isEmpty)
        }
    }
}
