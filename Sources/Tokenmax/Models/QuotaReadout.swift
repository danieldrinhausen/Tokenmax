import Foundation

/// Which way every quota surface reads: how much is left, or how much is gone.
///
/// Presentation only. Every decision — the opener's weekly floor, auto-run's
/// reserve, reminders, the escalation ladder, the burn highlight — keeps working
/// in percent *remaining*, whatever this says. Flipping the arithmetic of a
/// rule that spends quota is how a sign error ends up spending it; flipping the
/// words and the bars costs nothing.
///
/// Remaining is the default, upgrade included, because the menu bar is where
/// people read by shape: a bar that suddenly grows instead of shrinking would
/// read as the opposite of what it means. Used is what Claude's and Codex's own
/// usage pages print, which is why someone coming from them reads a bare "88%"
/// in the menu bar as 88% gone.
enum QuotaReadout: String, Codable, Sendable, CaseIterable, Identifiable {
    /// "88% left"; the meter starts full and empties as quota is spent.
    case remaining
    /// "12% used"; the meter starts empty and fills as quota is spent.
    case used

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remaining: "Remaining"
        case .used: "Used"
        }
    }

    /// The word after a percentage, so a written-out reading cannot be taken
    /// for the other direction.
    var suffix: String {
        switch self {
        case .remaining: "left"
        case .used: "used"
        }
    }

    /// The whole percentage to print for a reading given as percent remaining.
    ///
    /// Derived from the remaining figure rather than rounded on its own, so
    /// both directions keep `UsageWindow.displayPercent`'s rule: "0% used" only
    /// for an untouched window, "100% used" exactly when the window reads
    /// "Limit reached".
    func displayPercent(forRemaining remaining: Double) -> Int {
        let left = UsageWindow.displayPercent(forRemaining: remaining)
        return switch self {
        case .remaining: left
        case .used: 100 - left
        }
    }

    /// How far a meter should be filled, 0...1, at whole-percent resolution.
    /// Zero means draw no fill: an exhausted window when reading what is left,
    /// an untouched one when reading what is gone.
    func displayFill(forRemaining remaining: Double) -> Double {
        Double(displayPercent(forRemaining: remaining)) / 100
    }

    /// Where a point stated in percent remaining — the even-pace marker — sits
    /// along a meter drawn in this direction, 0...1.
    func position(forRemaining remaining: Double) -> Double {
        let fraction = max(0, min(1, remaining / 100))
        return switch self {
        case .remaining: fraction
        case .used: 1 - fraction
        }
    }
}
