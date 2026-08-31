import Testing

@testable import Tokenmax

@Suite("Menu bar item visibility")
struct MenuBarItemDecisionTests {
    @Test("The menu bar item cannot disappear without Side Notch")
    func hidingNeedsAnotherSurface() {
        #expect(MenuBarItemDecision.hideSuppression(sideNotchEnabled: false) == .sideNotchDisabled)
        #expect(MenuBarItemDecision.resolvedVisibility(
            requestedVisible: false,
            sideNotchEnabled: false
        ))
    }

    @Test("An active Side Notch may be the app's only surface")
    func sideNotchCanStandAlone() {
        #expect(MenuBarItemDecision.hideSuppression(sideNotchEnabled: true) == nil)
        #expect(!MenuBarItemDecision.resolvedVisibility(
            requestedVisible: false,
            sideNotchEnabled: true
        ))
    }

    @Test("An explicit visible choice always survives")
    func visibleAlwaysSurvives() {
        #expect(MenuBarItemDecision.resolvedVisibility(
            requestedVisible: true,
            sideNotchEnabled: false
        ))
        #expect(MenuBarItemDecision.resolvedVisibility(
            requestedVisible: true,
            sideNotchEnabled: true
        ))
    }

    /// Regression: removing `MenuBarExtra` produced one last `true` write from
    /// SwiftUI, which immediately flipped the user's off switch back on.
    @Test("Scene reconciliation cannot overwrite the user's hidden choice")
    func sceneWriteDoesNotRestoreHiddenItem() {
        #expect(!MenuBarItemDecision.persistedVisibility(
            afterSceneReconciliation: true,
            currentUserChoice: false
        ))
        #expect(MenuBarItemDecision.persistedVisibility(
            afterSceneReconciliation: false,
            currentUserChoice: true
        ))
    }
}
