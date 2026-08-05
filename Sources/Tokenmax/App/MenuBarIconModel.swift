import Foundation

/// Everything the menubar label needs, resolved from the configured bar layout
/// against the current snapshots.
///
/// Pure and separate from the view because the interesting part is no longer the
/// drawing: with bars spanning two providers, "is this stale?" stopped being one
/// question about one snapshot. A bar whose own provider is stale must stub out
/// while the others keep reading live, and the countdown must disappear when the
/// window it follows goes stale even if the rest of the icon is fine.
struct MenuBarIconModel: Equatable {
    var bars: [MenuBarIconRenderer.Bar]
    /// Every shown provider is stale, so the whole icon mutes. One stale
    /// provider among several only stubs its own bar.
    var isStale: Bool
    /// The countdown window's reset time, and whether it can be trusted as a
    /// live deadline. Its source is configured separately from the bars, so it
    /// may well be a window no bar is showing.
    var countdownResetAt: Date?
    var countdownIsStale: Bool

    /// `layout` and `countdownSource` are expected to be the *effective* ones —
    /// see `AppSettings.effectiveMenuBarBars`. A disabled provider is filtered
    /// out before it reaches here rather than being special-cased inside, so
    /// this stays a pure function of what is on screen.
    ///
    /// `countdownSource` is optional because the countdown is: there may be no
    /// enabled source whose window is worth counting down to.
    static func make(
        layout: MenuBarBars,
        countdownSource: MenuBarQuotaSource?,
        snapshot: (TokenmaxProvider) -> UsageSnapshot?,
        isStale: (TokenmaxProvider) -> Bool,
        alerting: Set<MenuBarQuotaSource>
    ) -> MenuBarIconModel {
        let sources = layout.sources

        let bars = sources.map { source -> MenuBarIconRenderer.Bar in
            let window = snapshot(source.provider)?.window(source.kind)
            // A stale provider contributes no number. Nil lands on the same
            // stub the renderer already draws for an unknown reading, which is
            // the honest picture: the bar is there, the value is not.
            let fraction = isStale(source.provider) ? nil : window?.remainingPercent
            return MenuBarIconRenderer.Bar(
                fraction: fraction,
                isAlerting: alerting.contains(source)
            )
        }

        let shownProviders = Set(sources.map(\.provider))

        return MenuBarIconModel(
            bars: bars,
            isStale: !shownProviders.isEmpty && shownProviders.allSatisfy { isStale($0) },
            countdownResetAt: countdownSource.flatMap {
                snapshot($0.provider)?.window($0.kind)?.resetAt
            },
            // No source is indistinguishable from an unreadable one as far as
            // the label is concerned: either way there is no countdown to show.
            countdownIsStale: countdownSource.map { isStale($0.provider) } ?? true
        )
    }
}
