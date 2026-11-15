import Foundation

struct SideNotchMeterPresentation: Equatable, Identifiable, Sendable {
    let source: MenuBarQuotaSource
    let window: UsageWindow?
    let isStale: Bool
    let projection: UsageProjection?
    let reminderStatus: ReminderStatus?
    let color: HighlightColor?
    let glow: Bool
    /// Which way the ring and the text run. Defaulted so a presentation built
    /// without one reads as every build before the setting did.
    var readout: QuotaReadout = .remaining

    var id: MenuBarQuotaSource { source }
    var remainingPercent: Double? { isStale ? nil : window?.remainingPercent }
    /// How far the ring or bar is filled, at the resolution the text prints,
    /// and nil at 0% — a round-capped trim of nothing still draws a dot, which
    /// beside "0% used" or "Limit reached" would claim a reading that is not
    /// there.
    var fraction: Double? {
        remainingPercent.map { readout.displayFill(forRemaining: $0) }.flatMap { $0 > 0 ? $0 : nil }
    }
    /// The ring's centre figure: "88%", or "—" when there is no current reading.
    var percentText: String {
        remainingPercent.map { "\(readout.displayPercent(forRemaining: $0))%" } ?? "—"
    }
    var readingText: String {
        window.map { UsageWindowPresentation.remainingText(for: $0, readout: readout) } ?? "Unavailable"
    }

    var shortLabel: String {
        switch source {
        case .cursorAPI: return "API usage"
        case .cursorAuto: return "Auto usage"
        default: break
        }
        return switch source.kind {
        case .session: "Current session"
        case .weekly: "Weekly limit"
        case .modelSpecificWeekly: "Model limit"
        case .billingCycle: "Billing cycle"
        }
    }
}

struct SideNotchProviderPresentation: Equatable, Identifiable, Sendable {
    let provider: TokenmaxProvider
    let planName: String?
    let updatedText: String
    let isStale: Bool
    let availableResetLines: [String]
    let oneTimeCreditText: String?
    let outer: SideNotchMeterPresentation
    let inner: SideNotchMeterPresentation

    var id: TokenmaxProvider { provider }
    var detailMeters: [SideNotchMeterPresentation] {
        [outer, inner].filter { $0.window != nil }
    }

    /// What the rail button's ring says to a screen reader, which cannot see it:
    /// each window's share left, or that its reading is out of date — the ring
    /// shows "—" then, and a stale number read aloud would be a claim about now.
    var accessibilityValue: String {
        let meters = detailMeters
        guard !meters.isEmpty else { return "No quota reading" }
        return meters.map { meter in
            let state = meter.isStale
                ? "reading out of date"
                : meter.window.map { UsageWindowPresentation.remainingText(for: $0, readout: meter.readout) } ?? "unknown"
            return "\(meter.shortLabel), \(state)"
        }.joined(separator: "; ")
    }
}

struct SideNotchDetailDimensions: Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Sizes the detail panel from the information it will actually draw. This is
/// presentation policy rather than window management, so it stays pure and a
/// weekly-only provider cannot regress into reserving an empty session row.
enum SideNotchDetailLayout {
    static func dimensions(for presentation: SideNotchProviderPresentation) -> SideNotchDetailDimensions {
        let meters = presentation.detailMeters
        var height = 62.0

        if meters.isEmpty {
            height += 28
        } else {
            for meter in meters {
                height += 35
                if meter.projection != nil { height += 16 }
                if meter.reminderStatus != nil { height += 16 }
            }
            height += Double(max(0, meters.count - 1)) * 9
        }

        height += Double(presentation.availableResetLines.count) * 22
        if presentation.oneTimeCreditText != nil { height += 22 }
        return SideNotchDetailDimensions(width: 340, height: height)
    }
}

/// Resolves the freely arranged menu-bar ring slots into one unambiguous ring
/// per provider. First appearance orders providers; relative appearance of a
/// provider's two sources decides outer versus inner.
///
/// The menu bar draws at most four rings' worth of sources, which is two
/// providers. A third enabled provider — or one whose pair the user did not
/// place — gets its own fixed pair instead of vanishing from the notch: the
/// notch lists providers, and a watched provider missing from that list reads
/// as a provider that is not being watched.
enum SideNotchPresentation {
    static func make(
        layout: MenuBarRings,
        enabledProviders: [TokenmaxProvider],
        snapshot: (TokenmaxProvider) -> UsageSnapshot?,
        isStale: (TokenmaxProvider) -> Bool,
        alerting: Set<MenuBarQuotaSource>,
        ready: Set<MenuBarQuotaSource>,
        colors: SideNotchColorSettings,
        readout: QuotaReadout = .remaining,
        now: Date,
        projection: (UsageWindow) -> UsageProjection?,
        reminderStatus: (TokenmaxProvider, UsageWindowKind) -> ReminderStatus?
    ) -> [SideNotchProviderPresentation] {
        orderedProviders(layout: layout, enabledProviders: enabledProviders).compactMap { provider in
            let placed = layout.sources.filter { $0.provider == provider }
            let sources = placed.count >= 2 ? placed : MenuBarItemDecision.sources(for: provider)
            let stale = isStale(provider)
            let current = snapshot(provider)
            return SideNotchProviderPresentation(
                provider: provider,
                planName: current?.planName,
                updatedText: current.map {
                    "Updated \(RelativeTime.short(now.timeIntervalSince($0.fetchedAt))) ago"
                } ?? "Never updated",
                isStale: stale,
                availableResetLines: current.map {
                    UsageWindowPresentation.availableResetLines(for: $0, now: now)
                } ?? [],
                oneTimeCreditText: current.flatMap {
                    UsageWindowPresentation.oneTimeCreditText(for: $0, now: now)
                },
                outer: meter(
                    source: sources[0], snapshot: current, isStale: stale,
                    alerting: alerting, ready: ready, colors: colors, readout: readout,
                    projection: projection, reminderStatus: reminderStatus
                ),
                inner: meter(
                    source: sources[1], snapshot: current, isStale: stale,
                    alerting: alerting, ready: ready, colors: colors, readout: readout,
                    projection: projection, reminderStatus: reminderStatus
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
        colors: SideNotchColorSettings,
        readout: QuotaReadout,
        projection: (UsageWindow) -> UsageProjection?,
        reminderStatus: (TokenmaxProvider, UsageWindowKind) -> ReminderStatus?
    ) -> SideNotchMeterPresentation {
        let window = snapshot?.window(for: source)
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
            projection: isStale ? nil : window.flatMap(projection),
            reminderStatus: reminderStatus(source.provider, source.kind),
            color: color,
            glow: colors.glow && color != nil,
            readout: readout
        )
    }
}
