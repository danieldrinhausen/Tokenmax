import Foundation

/// The shape the menubar icon is drawn in.
///
/// Bars and rings answer the same question with different trade-offs. Bars are
/// easier to compare against each other — length is the channel the eye reads
/// most accurately — and cap out at three, because a fourth does not fit 16pt
/// of height. Rings hold four quotas in two objects and show the nesting that
/// the numbers actually have, since a session runs inside a week, but they cost
/// width and a percentage is harder to estimate from an arc.
enum MenuBarIconStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case bars
    case rings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: "Bars"
        case .rings: "Rings"
        }
    }
}

/// What the icon draws, resolved: a style together with the layout belonging to
/// it.
///
/// A single value rather than a style plus two optionals, so nothing downstream
/// can be handed `.rings` alongside a bar layout. `MenuBarIconModel.make` then
/// keeps taking exactly one layout argument, as it did before rings existed.
enum MenuBarIconLayout: Equatable, Sendable {
    case bars(MenuBarBars)
    case rings(MenuBarRings)

    var style: MenuBarIconStyle {
        switch self {
        case .bars: .bars
        case .rings: .rings
        }
    }

    /// Flat, in drawing order: top to bottom for bars, outer-then-inner and
    /// left to right for rings.
    var sources: [MenuBarQuotaSource] {
        switch self {
        case let .bars(bars): bars.sources
        case let .rings(rings): rings.sources
        }
    }
}
