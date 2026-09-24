import Foundation

/// One menu bar item: the combined one, or a single provider's.
enum MenuBarItemID: Hashable, Sendable {
    case combined
    case provider(TokenmaxProvider)

    /// The identity mark drawn before the meters. The combined item has none —
    /// it is drawn exactly as it was before separate items existed.
    var marker: MenuBarIconRenderer.ProviderMarker? {
        switch self {
        case .combined: nil
        case let .provider(provider): MenuBarIconRenderer.ProviderMarker(provider: provider)
        }
    }

    /// Read by VoiceOver, since the glyph alone is not a name.
    var accessibilityName: String {
        switch self {
        case .combined: "Tokenmax"
        case let .provider(provider): "Tokenmax — \(provider.displayName)"
        }
    }
}

enum MenuBarItemSuppressionReason: Equatable, Sendable {
    case sideNotchDisabled
    case lastProviderItem

    var explanation: String {
        switch self {
        case .sideNotchDisabled:
            "Turn on Side Notch before hiding the menu bar item, so Tokenmax always has a visible way back."
        case .lastProviderItem:
            "At least one provider keeps its icon. To hide them all, turn off the menu bar item above."
        }
    }
}

/// Keeps a menubar-only app reachable. Hiding the status item is safe only
/// while Side Notch remains available; decoding and both UI toggles use this
/// one rule so a hand-edited file cannot launch Tokenmax with no surface.
enum MenuBarItemDecision {
    static func hideSuppression(sideNotchEnabled: Bool) -> MenuBarItemSuppressionReason? {
        sideNotchEnabled ? nil : .sideNotchDisabled
    }

    static func resolvedVisibility(requestedVisible: Bool, sideNotchEnabled: Bool) -> Bool {
        requestedVisible || !sideNotchEnabled
    }

    /// The menu bar items to show, left to right.
    ///
    /// Separate items only mean something with two providers on: with one,
    /// "one icon per provider" and "one combined icon" are the same icon, so the
    /// combined item is kept rather than swapping to a differently drawn one
    /// that says nothing more. Keeping it also means switching the second
    /// provider back on restores exactly the layout the user chose.
    ///
    /// `hidden` drops a provider's icon, not the provider: it is still watched,
    /// reminded about and drawn in Side Notch. Hiding every icon is refused
    /// here as well as in Settings — a hand-edited file that hides them all
    /// shows them all, because "no icons" is what `showMenuBarItem` is for, and
    /// that switch has the Side Notch guard this list does not.
    static func items(
        showMenuBarItem: Bool,
        layout: MenuBarItemLayout,
        enabledProviders: [TokenmaxProvider],
        order: [TokenmaxProvider] = TokenmaxProvider.allCases,
        hidden: [TokenmaxProvider] = []
    ) -> [MenuBarItemID] {
        guard showMenuBarItem else { return [] }
        let providers = ordered(enabledProviders, by: order)
        guard layout == .separate, providers.count > 1 else { return [.combined] }
        let shown = providers.filter { !hidden.contains($0) }
        return (shown.isEmpty ? providers : shown).map { .provider($0) }
    }

    /// `providers` in the user's order. The stored order is normalized on
    /// read rather than trusted: a hand-edited file may repeat a provider or
    /// omit one, and a provider added in a later version is in nobody's saved
    /// order yet — it goes last, in canonical order, rather than nowhere.
    static func ordered(_ providers: [TokenmaxProvider], by order: [TokenmaxProvider]) -> [TokenmaxProvider] {
        var seen: Set<TokenmaxProvider> = []
        let complete = (order + TokenmaxProvider.allCases).filter { seen.insert($0).inserted }
        return complete.filter(providers.contains)
    }

    /// The stored order with `provider` swapped past its neighbour among
    /// `visible` — the providers the settings list actually shows. Moving
    /// against the full order instead would make a press swap with a switched-
    /// off provider and look like it did nothing.
    static func moving(
        _ provider: TokenmaxProvider,
        by offset: Int,
        in order: [TokenmaxProvider],
        visible: [TokenmaxProvider]
    ) -> [TokenmaxProvider] {
        var full = ordered(TokenmaxProvider.allCases, by: order)
        let list = ordered(visible, by: full)
        guard let index = list.firstIndex(of: provider), list.indices.contains(index + offset),
              let from = full.firstIndex(of: provider),
              let to = full.firstIndex(of: list[index + offset])
        else { return full }
        full.swapAt(from, to)
        return full
    }

    /// Why a provider's icon cannot be switched off, or nil if it can.
    static func hideSuppression(
        for provider: TokenmaxProvider,
        enabledProviders: [TokenmaxProvider],
        hidden: [TokenmaxProvider]
    ) -> MenuBarItemSuppressionReason? {
        let shown = enabledProviders.filter { !hidden.contains($0) }
        return shown == [provider] ? .lastProviderItem : nil
    }

    /// Which item the scene in `slot` draws. Slot 0 is the combined item's;
    /// slots 1 and up are the provider items'.
    ///
    /// Slots rather than one scene per provider because the order is a
    /// setting, and nothing can move a status item — macOS places one and
    /// remembers where. Each slot keeps its status item and its position, and
    /// reordering changes which provider it draws.
    ///
    /// Counted from the right: macOS inserts a new status item to the left of
    /// the ones already there, so slot 1 is the rightmost and a slot added
    /// later lands left of the rest. Filling from the right is what keeps the
    /// slots in order when one is added later: the newest status item is the
    /// leftmost, and it is also the highest-numbered slot.
    static func item(inSlot slot: Int, of items: [MenuBarItemID]) -> MenuBarItemID? {
        guard slot > 0 else { return items.contains(.combined) ? .combined : nil }
        let providerItems = items.filter { $0 != .combined }
        guard slot <= providerItems.count else { return nil }
        return providerItems[providerItems.count - slot]
    }

    /// What one provider's own item draws: its session over its week, in the
    /// configured style.
    ///
    /// Fixed rather than taken from the bar editor. The editor lays out quotas
    /// *across* providers, and filtering that layout per provider could leave an
    /// item with one bar or none; an item that exists to show one provider
    /// should always show the two windows that provider has.
    static func layout(for provider: TokenmaxProvider, style: MenuBarIconStyle) -> MenuBarIconLayout {
        let sources = sources(for: provider)
        return switch style {
        case .bars: .bars(MenuBarBars(sources))
        case .rings: .rings(MenuBarRings(sources))
        }
    }

    /// A provider's own two meters: its short window over its long one, or for
    /// Cursor its API usage over Auto — the meter that runs out leads.
    static func sources(for provider: TokenmaxProvider) -> [MenuBarQuotaSource] {
        switch provider {
        case .claudeCode: [.claudeSession, .claudeWeekly]
        case .codex: [.codexSession, .codexWeekly]
        case .cursor: [.cursorAPI, .cursorAuto]
        }
    }

    /// The countdown a provider's own item follows: that provider's own
    /// session or week, never another provider's.
    static func countdownSource(
        for provider: TokenmaxProvider,
        countdown: MenuBarProviderCountdown
    ) -> MenuBarQuotaSource {
        switch (provider, countdown) {
        case (.claudeCode, .session): .claudeSession
        case (.claudeCode, .week): .claudeWeekly
        case (.codex, .session): .codexSession
        case (.codex, .week): .codexWeekly
        // One billing cycle behind both meters, so both choices land on the
        // same reset.
        case (.cursor, _): .cursorAPI
        }
    }

    /// `MenuBarExtra` writes its current insertion state while reconciling a
    /// removal. That callback describes the scene SwiftUI is tearing down, not
    /// a user action; accepting it restores the item the user just hid.
    static func persistedVisibility(
        afterSceneReconciliation _: Bool,
        currentUserChoice: Bool
    ) -> Bool {
        currentUserChoice
    }
}
