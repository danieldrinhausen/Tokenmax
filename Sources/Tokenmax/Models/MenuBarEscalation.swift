import Foundation

/// What turns a meter a warning colour.
///
/// Two kinds rather than one because they answer different questions. A
/// percentage is a statement about the quota itself and is true whether or not
/// anything has been announced; a fired reminder is a statement about what the
/// user has already been told. `MenuBarEscalationDecision` keeps them apart for
/// exactly that reason — see the precedence note there.
enum MenuBarEscalationTrigger: Sendable, Equatable, Hashable {
    /// Remaining quota at or below this percentage. Stored 1...99: a level at 0
    /// could only fire on an exhausted window, and one at 100 would fire always.
    case remainingAtOrBelow(Double)
    /// This window's reminder has fired and it has not reset yet — the same
    /// condition that drives `MenuBarIconRenderer.Meter.isAlerting`.
    case reminderFired

    static let minimumPercent: Double = 1
    static let maximumPercent: Double = 99

    /// Lower is more severe. A reminder-triggered level has no place on the
    /// percentage scale, so it sorts last and is compared only against itself —
    /// the normalizer allows at most one.
    var severity: Double {
        switch self {
        case let .remainingAtOrBelow(percent): percent
        case .reminderFired: .greatestFiniteMagnitude
        }
    }
}

/// One rung of the colour ladder.
struct MenuBarEscalationLevel: Sendable, Equatable, Hashable, Identifiable {
    var trigger: MenuBarEscalationTrigger
    var color: HighlightColor

    /// Stable across a colour change so a SwiftUI row keeps its identity while
    /// the user is picking. The trigger is what the row *is*; two rows can
    /// never share one, because the normalizer deduplicates them.
    var id: String {
        switch trigger {
        case let .remainingAtOrBelow(percent): "percent-\(Int(percent))"
        case .reminderFired: "reminder"
        }
    }
}

/// The configured colour ladder for the menubar meters.
///
/// Applies to both icon styles. Colour is a property of a reading, not of a
/// shape, and giving bars and rings separate ladders would mean two things to
/// keep in step for no gain.
struct MenuBarEscalation: Codable, Sendable, Equatable, Hashable {
    /// Three is where the ladder stops being readable. At 2.2pt of stroke the
    /// eye cannot rank four warm colours, and a fourth rung would mostly serve
    /// to make the other three ambiguous.
    static let maximumLevels = 3

    /// nil means "leave it neutral", which keeps the icon a template image and
    /// lets macOS tint it to the menu bar until a level is actually reached.
    ///
    /// That is the default for a reason: a colour that is always on says
    /// nothing, and it costs templating permanently — an untemplated icon has
    /// no correct neutral available, because menu bar contrast follows the
    /// wallpaper rather than the light/dark setting. A base colour is offered
    /// anyway for someone who wants green-when-healthy, which is a real and
    /// common way to read a gauge.
    var baseColor: HighlightColor?

    /// Most severe first. Normalization guarantees that, so no reader has to
    /// sort and no editor has to keep the list ordered while the user types.
    private(set) var levels: [MenuBarEscalationLevel]

    /// Amber at half, red at a quarter, neutral above. Only ever drawn once the
    /// scheme is switched to escalating, so this repaints nobody on upgrade.
    ///
    /// Both clear `HighlightColor.minimumContrastRatio` against a light and a
    /// dark menu bar, which a saturated red does not — the warning colour is
    /// the one that most needs to survive both.
    static let `default` = MenuBarEscalation(
        baseColor: nil,
        levels: [
            MenuBarEscalationLevel(
                trigger: .remainingAtOrBelow(50),
                color: HighlightColor(red: 1.00, green: 0.75, blue: 0.20)
            ),
            MenuBarEscalationLevel(
                trigger: .remainingAtOrBelow(25),
                color: HighlightColor(red: 1.00, green: 0.36, blue: 0.30)
            ),
        ]
    )

    /// Normalizes rather than rejects, for the same reason `MenuBarBars` does:
    /// this is on the path from a hand-editable `settings.json` and from an
    /// editor a future change could get wrong, and neither is worth an icon
    /// that cannot be drawn.
    init(baseColor: HighlightColor?, levels: [MenuBarEscalationLevel]) {
        self.baseColor = baseColor

        var seenReminder = false
        var seenPercents: Set<Int> = []
        var kept: [MenuBarEscalationLevel] = []

        for level in levels {
            switch level.trigger {
            case .reminderFired:
                // A second reminder level could never fire: the first one
                // already matches every reading it would.
                guard !seenReminder else { continue }
                seenReminder = true
                kept.append(level)
            case let .remainingAtOrBelow(percent):
                let clamped = Int(
                    max(
                        MenuBarEscalationTrigger.minimumPercent,
                        min(MenuBarEscalationTrigger.maximumPercent, percent.isNaN ? 50 : percent)
                    ).rounded()
                )
                // Two levels at the same threshold are one level and a colour
                // nobody will ever see.
                guard seenPercents.insert(clamped).inserted else { continue }
                kept.append(MenuBarEscalationLevel(
                    trigger: .remainingAtOrBelow(Double(clamped)),
                    color: level.color
                ))
            }
        }

        // Sorted here rather than at every read, so "the most severe level that
        // has been reached" is just the first match.
        self.levels = Array(kept.sorted { $0.trigger.severity < $1.trigger.severity }.prefix(Self.maximumLevels))
    }

    /// The percentage rungs, most severe first. The editor shows these as rows;
    /// the reminder rung, being at most one, is presented on its own.
    var percentLevels: [MenuBarEscalationLevel] {
        levels.filter { if case .remainingAtOrBelow = $0.trigger { true } else { false } }
    }

    var reminderLevel: MenuBarEscalationLevel? {
        levels.first { $0.trigger == .reminderFired }
    }

    /// Every colour the ladder can paint, for the legibility warning.
    var colors: [HighlightColor] {
        (baseColor.map { [$0] } ?? []) + levels.map(\.color)
    }

    func replacingLevels(_ levels: [MenuBarEscalationLevel]) -> MenuBarEscalation {
        MenuBarEscalation(baseColor: baseColor, levels: levels)
    }

    /// The next rung the editor should offer, or nil when the ladder is full.
    /// Half of whatever the most severe percentage rung is, so "add a level"
    /// lands somewhere plausible rather than on a duplicate the normalizer
    /// would immediately drop.
    var suggestedLevel: MenuBarEscalationLevel? {
        guard levels.count < Self.maximumLevels else { return nil }
        let lowest = percentLevels.last.flatMap { level -> Double? in
            guard case let .remainingAtOrBelow(percent) = level.trigger else { return nil }
            return percent
        }
        let percent = max(MenuBarEscalationTrigger.minimumPercent, ((lowest ?? 100) / 2).rounded())
        guard !percentLevels.contains(where: { $0.trigger == .remainingAtOrBelow(percent) }) else {
            return MenuBarEscalationLevel(trigger: .reminderFired, color: .default)
        }
        return MenuBarEscalationLevel(
            trigger: .remainingAtOrBelow(percent),
            color: levels.last?.color ?? .default
        )
    }

    // MARK: - Codable

    /// A wire type with every field optional, kept separate from the domain
    /// type so the model itself needs no optionals to describe a level.
    ///
    /// It is what lets one broken rung fall out on its own: a level whose
    /// trigger no longer decodes is dropped and the rest of the ladder
    /// survives, the same way `MenuBarBars` drops a retired source rather than
    /// losing the whole setting.
    private struct WireLevel: Codable {
        var remainingAtOrBelow: Double?
        var reminderFired: Bool?
        var color: HighlightColor?

        var level: MenuBarEscalationLevel? {
            guard let color else { return nil }
            if let percent = remainingAtOrBelow {
                return MenuBarEscalationLevel(trigger: .remainingAtOrBelow(percent), color: color)
            }
            if reminderFired == true {
                return MenuBarEscalationLevel(trigger: .reminderFired, color: color)
            }
            return nil
        }

        init(_ level: MenuBarEscalationLevel) {
            color = level.color
            switch level.trigger {
            case let .remainingAtOrBelow(percent):
                remainingAtOrBelow = percent
                reminderFired = nil
            case .reminderFired:
                remainingAtOrBelow = nil
                reminderFired = true
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case baseColor
        case levels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wire = (try? container.decodeIfPresent([WireLevel].self, forKey: .levels)) ?? []
        self.init(
            baseColor: (try? container.decodeIfPresent(HighlightColor.self, forKey: .baseColor)) ?? nil,
            levels: wire.compactMap(\.level)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(baseColor, forKey: .baseColor)
        try container.encode(levels.map(WireLevel.init), forKey: .levels)
    }
}

/// Whether the menubar meters carry colour from their own reading.
enum MenuBarColorScheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case monochrome
    case escalating

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monochrome: "Monochrome"
        case .escalating: "Escalating"
        }
    }
}
