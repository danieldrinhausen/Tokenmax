import Foundation

struct SideNotchMeterPresentation: Equatable, Identifiable, Sendable {
    let source: MenuBarQuotaSource
    let window: UsageWindow?
    let isStale: Bool
    let color: HighlightColor?
    let glow: Bool

    var id: MenuBarQuotaSource { source }
    var remainingPercent: Double? { isStale ? nil : window?.remainingPercent }
    var fraction: Double? { remainingPercent.map { max(0, min(1, $0 / 100)) } }

    var shortLabel: String {
        switch source.kind {
        case .session: "Current session"
        case .weekly: "Weekly limit"
        case .modelSpecificWeekly: "Model limit"
        }
    }
}

struct SideNotchProviderPresentation: Equatable, Identifiable, Sendable {
    let provider: TokenmaxProvider
    let outer: SideNotchMeterPresentation
    let inner: SideNotchMeterPresentation

    var id: TokenmaxProvider { provider }
}

/// Resolves the freely arranged menu-bar ring slots into one unambiguous ring
/// per provider. First appearance orders providers; relative appearance of a
/// provider's two sources decides outer versus inner.
enum SideNotchPresentation {
    static func make(
        layout: MenuBarRings,
        enabledProviders: [TokenmaxProvider],
        snapshot: (TokenmaxProvider) -> UsageSnapshot?,
        isStale: (TokenmaxProvider) -> Bool,
        alerting: Set<MenuBarQuotaSource>,
        ready: Set<MenuBarQuotaSource>,
        colors: SideNotchColorSettings
    ) -> [SideNotchProviderPresentation] {
        orderedProviders(layout: layout, enabledProviders: enabledProviders).compactMap { provider in
            let sources = layout.sources.filter { $0.provider == provider }
            guard sources.count >= 2 else { return nil }
            let stale = isStale(provider)
            let current = snapshot(provider)
            return SideNotchProviderPresentation(
                provider: provider,
                outer: meter(
                    source: sources[0], snapshot: current, isStale: stale,
                    alerting: alerting, ready: ready, colors: colors
                ),
                inner: meter(
                    source: sources[1], snapshot: current, isStale: stale,
                    alerting: alerting, ready: ready, colors: colors
                )
            )
        }
    }

    static func orderedProviders(
        layout: MenuBarRings,
        enabledProviders: [TokenmaxProvider]
    ) -> [TokenmaxProvider] {
        var seen: Set<TokenmaxProvider> = []
        let placed = layout.sources.compactMap { source in
            enabledProviders.contains(source.provider) && seen.insert(source.provider).inserted
                ? source.provider
                : nil
        }
        return placed + enabledProviders.filter { seen.insert($0).inserted }
    }

    private static func meter(
        source: MenuBarQuotaSource,
        snapshot: UsageSnapshot?,
        isStale: Bool,
        alerting: Set<MenuBarQuotaSource>,
        ready: Set<MenuBarQuotaSource>,
        colors: SideNotchColorSettings
    ) -> SideNotchMeterPresentation {
        let window = snapshot?.window(source.kind)
        let fraction = isStale ? nil : window?.remainingPercent
        let isAlerting = alerting.contains(source)
        let isReady = !isStale && ready.contains(source)
        let escalation = colors.scheme == .escalating ? colors.escalation : nil
        let reached = escalation.flatMap {
            MenuBarEscalationDecision.reached(
                fraction: fraction,
                isAlerting: isAlerting,
                escalation: $0
            )
        }

        let color: HighlightColor?
        if isStale || fraction == nil {
            color = nil
        } else if let reached, reached.outranksHighlight {
            color = reached.color
        } else if isReady {
            color = colors.opportunityColor
        } else if let reached {
            color = reached.color
        } else if isAlerting, escalation == nil {
            // The fixed orange is part of the menu-bar palette even though it
            // predates the configurable ladder. Following the menu bar means
            // following that signal too.
            color = HighlightColor(red: 1.00, green: 0.58, blue: 0.10)
        } else {
            color = escalation?.baseColor
        }

        return SideNotchMeterPresentation(
            source: source,
            window: window,
            isStale: isStale,
            color: color,
            glow: colors.glow && color != nil
        )
    }
}
