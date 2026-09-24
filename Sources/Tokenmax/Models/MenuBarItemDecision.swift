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

    var explanation: String {
        switch self {
        case .sideNotchDisabled:
            "Turn on Side Notch before hiding the menu bar item, so Tokenmax always has a visible way back."
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

    /// `MenuBarExtra` writes its current insertion state while reconciling a
    /// removal. That callback describes the scene SwiftUI is tearing down, not
    /// a user action; accepting it restores the item the user just hid.
    /// The menu bar items to show, in order.
    ///
    /// Separate items only mean something with two providers on: with one,
    /// "one icon per provider" and "one combined icon" are the same icon, so the
    /// combined item is kept rather than swapping to a differently drawn one
    /// that says nothing more. Keeping it also means switching the second
    /// provider back on restores exactly the layout the user chose.
    static func items(
        showMenuBarItem: Bool,
        layout: MenuBarItemLayout,
        enabledProviders: [TokenmaxProvider]
    ) -> [MenuBarItemID] {
        guard showMenuBarItem else { return [] }
        let providers = TokenmaxProvider.allCases.filter(enabledProviders.contains)
        guard layout == .separate, providers.count > 1 else { return [.combined] }
        return providers.map { .provider($0) }
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

    static func persistedVisibility(
        afterSceneReconciliation _: Bool,
        currentUserChoice: Bool
    ) -> Bool {
        currentUserChoice
    }
}
