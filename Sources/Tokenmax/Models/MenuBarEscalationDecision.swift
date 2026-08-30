import Foundation

/// Which escalation level, if any, a reading has reached.
///
/// A decision type in the sense the rest of the app uses one: it takes the
/// reading and the configured ladder as parameters and returns a verdict. It
/// reads no file, spawns nothing, and never calls `Date()`.
///
/// Separate from the renderer because the interesting part is the precedence,
/// not the drawing — and because "does exactly 25% trip a level set at 25%" is a
/// question that deserves a test rather than a squint at a PNG.
enum MenuBarEscalationDecision {
    struct Reached: Equatable {
        var color: HighlightColor

        /// Whether this level beats the "spend it now" highlight.
        ///
        /// A percentage-triggered level does: a window with 15% left is not an
        /// opportunity however close its reset is, and painting it the
        /// highlight colour would have the icon contradict the popover.
        ///
        /// A reminder-triggered level does not, for exactly the reason
        /// `MenuBarIconRenderer.meterColor` already gives about `isAlerting` —
        /// "already announced" is notification bookkeeping, not a statement
        /// about quota. A window with 80% left that happens to have been
        /// announced is still an opportunity.
        var outranksHighlight: Bool
    }

    /// `fraction` is percent *remaining*, or nil when the reading is unknown.
    ///
    /// An unknown reading reaches nothing: without a number there is nothing to
    /// be alarmed about, and colouring it would dress up missing data as a
    /// measurement. The stale case is handled a level up, in `meterColor`,
    /// which mutes before it ever gets here.
    static func reached(
        fraction: Double?,
        isAlerting: Bool,
        escalation: MenuBarEscalation
    ) -> Reached? {
        // `levels` is sorted most severe first, so the first match is the
        // answer and there is nothing to compare.
        for level in escalation.levels {
            switch level.trigger {
            case let .remainingAtOrBelow(percent):
                guard let fraction, !fraction.isNaN, fraction <= percent else { continue }
                return Reached(color: level.color, outranksHighlight: true)
            case .reminderFired:
                guard isAlerting else { continue }
                return Reached(color: level.color, outranksHighlight: false)
            }
        }
        return nil
    }
}
