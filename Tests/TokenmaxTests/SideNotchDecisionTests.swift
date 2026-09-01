import CoreGraphics
import Testing

@testable import Tokenmax

@Suite("Side Notch interaction")
struct SideNotchDecisionTests {
    @Test("The alpha stays absent until the user enables it")
    func disabledIsNamed() {
        #expect(SideNotchDecision.suppression(
            enabled: false, sessionIsActive: true, screenIsAvailable: true
        ) == .disabled)
    }

    @Test("A locked or sleeping session hides the widget")
    func inactiveSessionIsNamed() {
        #expect(SideNotchDecision.suppression(
            enabled: true, sessionIsActive: false, screenIsAvailable: true
        ) == .sessionInactive)
    }

    @Test("Hover expands the handle and then selects a provider")
    func hoverProgresses() {
        let rail = SideNotchDecision.reduce(.peek, event: .pointerEnteredHandle)
        let detail = SideNotchDecision.reduce(rail, event: .pointerEnteredProvider(.codex))

        #expect(rail == .rail)
        #expect(detail == .detail(provider: .codex, locked: false))
    }

    @Test("Click pins a hovered provider and a second click returns to the rail")
    func clickPinsAndReleases() {
        let hovered = SideNotchState.detail(provider: .claudeCode, locked: false)
        let pinned = SideNotchDecision.reduce(hovered, event: .providerClicked(.claudeCode))
        let released = SideNotchDecision.reduce(pinned, event: .providerClicked(.claudeCode))

        #expect(pinned == .detail(provider: .claudeCode, locked: true))
        #expect(released == .rail)
    }

    @Test("Hover cannot replace a provider while its detail is pinned")
    func pinResistsHover() {
        let pinned = SideNotchState.detail(provider: .claudeCode, locked: true)
        #expect(SideNotchDecision.reduce(
            pinned, event: .pointerEnteredProvider(.codex)
        ) == pinned)
    }

    @Test("The named close delay always collapses and releases selection")
    func delayedCloseCollapses() {
        #expect(SideNotchDecision.reduce(
            .detail(provider: .codex, locked: true),
            event: .closeDelayElapsed(keepRailVisible: false)
        ) == .peek)
    }

    @Test("A persistent Dock Notch dismisses detail without hiding its rail")
    func persistentDockCloseKeepsRail() {
        #expect(SideNotchDecision.reduce(
            .detail(provider: .codex, locked: false),
            event: .closeDelayElapsed(keepRailVisible: true)
        ) == .rail)
    }

    @Test("Dock placement follows the live Dock rectangle on either side")
    func dockPlacementFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 796)
        let size = CGSize(width: 158, height: 54)

        let left = SideNotchLayoutDecision.railFrame(
            placement: .dock, dockPlacement: .left,
            screen: screen, visibleScreen: visible,
            dockFrame: CGRect(x: 300, y: 10, width: 840, height: 52),
            size: size
        )
        let right = SideNotchLayoutDecision.railFrame(
            placement: .dock, dockPlacement: .right,
            screen: screen, visibleScreen: visible,
            dockFrame: CGRect(x: 300, y: 10, width: 840, height: 52),
            size: size
        )

        #expect(left.maxX == 268)
        #expect(right.minX == 1172)
        #expect(left.minY == 4)
        #expect(right.minY == 4)
    }

    @Test("Dock geometry cannot move an open rail away from the pointer")
    func openDockRailFreezesGeometry() {
        #expect(SideNotchDecision.shouldRefreshDockGeometry(state: .peek))
        #expect(!SideNotchDecision.shouldRefreshDockGeometry(state: .rail))
        #expect(!SideNotchDecision.shouldRefreshDockGeometry(
            state: .detail(provider: .claudeCode, locked: false)
        ))
    }

    @Test("Dock detail arrow follows the selected provider instead of the rail midpoint")
    func dockDetailFollowsProvider() {
        let rail = CGRect(x: 900, y: 4, width: 116, height: 54)
        let visible = CGRect(x: 0, y: 30, width: 1800, height: 970)
        let detail = CGSize(width: 340, height: 220)

        let claude = SideNotchLayoutDecision.detailFrame(
            placement: .dock, railFrame: rail, visibleScreen: visible,
            detailSize: detail, providerIndex: 0,
            railHeaderHeight: 22, providerRowHeight: 68, providerColumnWidth: 58
        )
        let codex = SideNotchLayoutDecision.detailFrame(
            placement: .dock, railFrame: rail, visibleScreen: visible,
            detailSize: detail, providerIndex: 1,
            railHeaderHeight: 22, providerRowHeight: 68, providerColumnWidth: 58
        )

        #expect(claude.midX == 929)
        #expect(codex.midX == 987)
    }

    @Test("Screen-edge placement retains the established right-hand centre")
    func sidePlacementFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = SideNotchLayoutDecision.railFrame(
            placement: .side, dockPlacement: .left,
            screen: visible, visibleScreen: visible, dockFrame: nil,
            size: CGSize(width: 16, height: 72)
        )

        #expect(frame == CGRect(x: 1184, y: 364, width: 16, height: 72))
    }

    @Test("An always-visible Dock Notch retains the compact rail")
    func persistentDockNotchStaysExpanded() {
        #expect(SideNotchDecision.resolvedState(
            .peek, placement: .dock, dockAlwaysExpanded: true
        ) == .rail)
        #expect(SideNotchDecision.resolvedState(
            .peek, placement: .side, dockAlwaysExpanded: true
        ) == .peek)
    }
}
