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
            .detail(provider: .codex, locked: true), event: .closeDelayElapsed
        ) == .peek)
    }

    @Test("Dock placement sits above the reserved Dock edge on either side")
    func dockPlacementFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 796)
        let size = CGSize(width: 76, height: 150)

        let left = SideNotchLayoutDecision.railFrame(
            placement: .dock, dockPlacement: .left,
            screen: screen, visibleScreen: visible, size: size
        )
        let right = SideNotchLayoutDecision.railFrame(
            placement: .dock, dockPlacement: .right,
            screen: screen, visibleScreen: visible, size: size
        )

        #expect(left.minX == 12)
        #expect(right.minX == 218)
        #expect(left.minY == 12)
        #expect(right.minY == 12)
    }

    @Test("Screen-edge placement retains the established right-hand centre")
    func sidePlacementFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = SideNotchLayoutDecision.railFrame(
            placement: .side, dockPlacement: .left,
            screen: visible, visibleScreen: visible, size: CGSize(width: 16, height: 72)
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
