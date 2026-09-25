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

    // MARK: - Which provider icons, in what order

    @Test("Separate items follow the configured order, left to right")
    func separateFollowsOrder() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate,
            enabledProviders: [.claudeCode, .codex, .cursor], order: [.cursor, .claudeCode, .codex]
        ) == [.provider(.cursor), .provider(.claudeCode), .provider(.codex)])
    }

    @Test("A partial or repeated order keeps every provider once, the missing ones last in canonical order")
    func partialOrderIsCompleted() {
        #expect(MenuBarItemDecision.ordered(
            [.claudeCode, .codex, .cursor], by: [.cursor, .cursor]
        ) == [.cursor, .claudeCode, .codex])
        #expect(MenuBarItemDecision.ordered([.codex, .claudeCode], by: []) == [.claudeCode, .codex])
    }

    @Test("A disabled provider has no item even though it has a place in the order")
    func disabledProviderHasNoItemDespiteOrder() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate,
            enabledProviders: [.claudeCode, .codex], order: [.cursor, .codex, .claudeCode]
        ) == [.provider(.codex), .provider(.claudeCode)])
    }

    @Test("A hidden provider loses its icon and the rest keep their order")
    func hiddenProviderLosesItsIcon() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate,
            enabledProviders: [.claudeCode, .codex, .cursor], hidden: [.codex]
        ) == [.provider(.claudeCode), .provider(.cursor)])
    }

    @Test("One provider left showing gets its own icon, not the combined one")
    func singleShownProviderKeepsItsOwnIcon() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate,
            enabledProviders: [.claudeCode, .codex], hidden: [.claudeCode]
        ) == [.provider(.codex)])
    }

    @Test("Hiding every provider's icon shows them all rather than none")
    func hidingEveryIconShowsAll() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate,
            enabledProviders: [.claudeCode, .codex], hidden: [.claudeCode, .codex]
        ) == [.provider(.claudeCode), .provider(.codex)])
    }

    @Test("The hidden list and the order change nothing about the combined icon")
    func combinedIgnoresHiddenAndOrder() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .combined,
            enabledProviders: [.claudeCode, .codex], order: [.codex], hidden: [.claudeCode, .codex]
        ) == [.combined])
    }

    @Test("The last icon showing cannot be switched off, and any other can")
    func lastShownIconIsSuppressed() {
        #expect(MenuBarItemDecision.hideSuppression(
            for: .codex, enabledProviders: [.claudeCode, .codex], hidden: [.claudeCode]
        ) == .lastProviderItem)
        #expect(MenuBarItemDecision.hideSuppression(
            for: .codex, enabledProviders: [.claudeCode, .codex], hidden: []
        ) == nil)
        // Already hidden: switching it back on is never refused.
        #expect(MenuBarItemDecision.hideSuppression(
            for: .claudeCode, enabledProviders: [.claudeCode, .codex], hidden: [.claudeCode]
        ) == nil)
    }

    @Test("Dropping a provider onto another puts it in that place and shifts the rows between")
    func droppingInsertsAtTarget() {
        let order: [TokenmaxProvider] = [.claudeCode, .codex, .cursor]
        #expect(MenuBarItemDecision.moving(.cursor, to: .claudeCode, in: order, visible: order)
            == [.cursor, .claudeCode, .codex])
        #expect(MenuBarItemDecision.moving(.claudeCode, to: .cursor, in: order, visible: order)
            == [.codex, .cursor, .claudeCode])
        #expect(MenuBarItemDecision.moving(.codex, to: .claudeCode, in: order, visible: order)
            == [.codex, .claudeCode, .cursor])
    }

    @Test("A switched-off provider keeps its place when the others are dragged around it")
    func droppingLeavesDisabledProvidersInPlace() {
        #expect(MenuBarItemDecision.moving(
            .codex, to: .claudeCode, in: [.claudeCode, .cursor, .codex], visible: [.claudeCode, .codex]
        ) == [.codex, .cursor, .claudeCode])
    }

    @Test("Dropping a provider onto itself, or dropping one the list does not show, changes nothing")
    func strayDropsAreIgnored() {
        let order: [TokenmaxProvider] = [.claudeCode, .codex, .cursor]
        #expect(MenuBarItemDecision.moving(.codex, to: .codex, in: order, visible: order) == order)
        #expect(MenuBarItemDecision.moving(.cursor, to: .claudeCode, in: order, visible: [.claudeCode, .codex])
            == order)
        #expect(MenuBarItemDecision.moving(.claudeCode, to: .cursor, in: order, visible: [.claudeCode, .codex])
            == order)
    }

    @Test("Provider slots fill from the right, so the leftmost item is the highest slot")
    func slotsFillFromTheRight() {
        let items: [MenuBarItemID] = [.provider(.cursor), .provider(.claudeCode), .provider(.codex)]
        #expect(MenuBarItemDecision.item(inSlot: 0, of: items) == nil)
        #expect(MenuBarItemDecision.item(inSlot: 1, of: items) == .provider(.codex))
        #expect(MenuBarItemDecision.item(inSlot: 2, of: items) == .provider(.claudeCode))
        #expect(MenuBarItemDecision.item(inSlot: 3, of: items) == .provider(.cursor))
    }

    @Test("The combined item takes slot 0 and leaves every provider slot empty")
    func combinedTakesSlotZero() {
        #expect(MenuBarItemDecision.item(inSlot: 0, of: [.combined]) == .combined)
        for slot in 1...3 {
            #expect(MenuBarItemDecision.item(inSlot: slot, of: [.combined]) == nil)
        }
    }

    @Test("A slot beyond the items shown, or any slot with no items, is empty")
    func unusedSlotsAreEmpty() {
        #expect(MenuBarItemDecision.item(inSlot: 3, of: [.provider(.claudeCode), .provider(.codex)]) == nil)
        for slot in 0...3 {
            #expect(MenuBarItemDecision.item(inSlot: slot, of: []) == nil)
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
