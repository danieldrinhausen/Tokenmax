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

    // MARK: - One item or one per provider

    @Test("The combined layout is one item")
    func combinedIsOneItem() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .combined, enabledProviders: [.claudeCode, .codex]
        ) == [.combined])
    }

    @Test("Separate items are one per enabled provider, Claude first")
    func separateIsOnePerProvider() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate, enabledProviders: [.codex, .claudeCode]
        ) == [.provider(.claudeCode), .provider(.codex)])
    }

    @Test("With one provider on, separate items fall back to the combined one")
    func singleProviderStaysCombined() {
        for provider in TokenmaxProvider.allCases {
            #expect(MenuBarItemDecision.items(
                showMenuBarItem: true, layout: .separate, enabledProviders: [provider]
            ) == [.combined])
        }
    }

    @Test("A hidden menu bar item hides every item whatever the layout")
    func hiddenMeansNone() {
        for layout in MenuBarItemLayout.allCases {
            #expect(MenuBarItemDecision.items(
                showMenuBarItem: false, layout: layout, enabledProviders: [.claudeCode, .codex]
            ).isEmpty)
        }
    }

    @Test("A provider's item draws only that provider's session over its week, in both styles")
    func providerLayoutIsItsOwn() {
        for style in MenuBarIconStyle.allCases {
            #expect(MenuBarItemDecision.layout(for: .claudeCode, style: style).sources
                == [.claudeSession, .claudeWeekly])
            #expect(MenuBarItemDecision.layout(for: .codex, style: style).sources
                == [.codexSession, .codexWeekly])
            #expect(MenuBarItemDecision.layout(for: .codex, style: style).style == style)
        }
    }

    @Test("A provider's item counts down to its own session or week, never another provider's")
    func providerCountdownIsItsOwn() {
        #expect(MenuBarItemDecision.countdownSource(for: .claudeCode, countdown: .session) == .claudeSession)
        #expect(MenuBarItemDecision.countdownSource(for: .claudeCode, countdown: .week) == .claudeWeekly)
        #expect(MenuBarItemDecision.countdownSource(for: .codex, countdown: .session) == .codexSession)
        #expect(MenuBarItemDecision.countdownSource(for: .codex, countdown: .week) == .codexWeekly)
        for provider in TokenmaxProvider.allCases {
            for countdown in MenuBarProviderCountdown.allCases {
                #expect(MenuBarItemDecision.countdownSource(for: provider, countdown: countdown).provider == provider)
            }
        }
    }

    @Test("Only a provider's item carries a marker")
    func onlyProviderItemsAreMarked() {
        #expect(MenuBarItemID.combined.marker == nil)
        #expect(MenuBarItemID.provider(.claudeCode).marker == .claude)
        #expect(MenuBarItemID.provider(.codex).marker == .codex)
        #expect(MenuBarItemID.provider(.codex).accessibilityName.contains("Codex"))
    }
}
