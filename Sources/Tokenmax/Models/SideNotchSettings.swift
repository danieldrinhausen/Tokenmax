import Foundation

/// Where the side notch gets the colours that give a reading meaning.
enum SideNotchColorSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case menuBar
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menuBar: "Follow menu bar"
        case .custom: "Custom"
        }
    }
}

/// The surface can stay at the display edge or move down beside the Dock.
/// Keeping this separate from the side choice makes an old settings file mean
/// exactly what it meant before: the right-hand screen edge.
enum SideNotchPlacement: String, Codable, Sendable, CaseIterable, Identifiable {
    case side
    case dock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .side: "Side Notch"
        case .dock: "Dock Notch"
        }
    }
}

enum DockNotchPlacement: String, Codable, Sendable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: "Left of Dock"
        case .right: "Right of Dock"
        }
    }
}

/// One complete palette for the side notch.
///
/// The types are shared with the menu bar because a percentage threshold must
/// mean the same thing everywhere. The drawing is deliberately not shared: a
/// 48pt animated ring on black has none of the menu bar renderer's 16pt,
/// template-image constraints.
struct SideNotchColorSettings: Codable, Sendable, Equatable {
    var scheme: MenuBarColorScheme = .monochrome
    var escalation: MenuBarEscalation = .default
    var opportunityColor: HighlightColor = .default
    var glow = false

    init(
        scheme: MenuBarColorScheme = .monochrome,
        escalation: MenuBarEscalation = .default,
        opportunityColor: HighlightColor = .default,
        glow: Bool = false
    ) {
        self.scheme = scheme
        self.escalation = escalation
        self.opportunityColor = opportunityColor
        self.glow = glow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = SideNotchColorSettings()
        scheme = (try? container.decodeIfPresent(MenuBarColorScheme.self, forKey: .scheme)) ?? d.scheme
        escalation = (try? container.decodeIfPresent(MenuBarEscalation.self, forKey: .escalation)) ?? d.escalation
        opportunityColor = (try? container.decodeIfPresent(HighlightColor.self, forKey: .opportunityColor))
            ?? d.opportunityColor
        glow = try container.decodeIfPresent(Bool.self, forKey: .glow) ?? d.glow
    }
}

/// The opt-in edge widget. Off by default because it occupies every Space and
/// an upgrade must never place a new always-on surface over somebody's work.
struct SideNotchSettings: Codable, Sendable, Equatable {
    var enabled = false
    var placement: SideNotchPlacement = .side
    var dockPlacement: DockNotchPlacement = .left
    /// Dock placement can serve as a persistent meter without consuming the
    /// screen edge; keep the more interruptive behaviour opt-in.
    var dockAlwaysExpanded = false
    var colorSource: SideNotchColorSource = .menuBar
    /// nil until Custom is chosen for the first time. That first choice copies
    /// the current menu bar palette; afterwards switching back and forth keeps
    /// the user's independent notch colours intact.
    var customColors: SideNotchColorSettings?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = SideNotchSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        placement = (try? container.decodeIfPresent(SideNotchPlacement.self, forKey: .placement)) ?? d.placement
        dockPlacement = (try? container.decodeIfPresent(DockNotchPlacement.self, forKey: .dockPlacement))
            ?? d.dockPlacement
        dockAlwaysExpanded = try container.decodeIfPresent(Bool.self, forKey: .dockAlwaysExpanded)
            ?? d.dockAlwaysExpanded
        colorSource = (try? container.decodeIfPresent(SideNotchColorSource.self, forKey: .colorSource))
            ?? d.colorSource
        customColors = try? container.decodeIfPresent(SideNotchColorSettings.self, forKey: .customColors)
    }
}

extension AppSettings {
    var menuBarColorsForSideNotch: SideNotchColorSettings {
        SideNotchColorSettings(
            scheme: menuBarColorScheme,
            escalation: menuBarEscalation,
            opportunityColor: menuBarHighlightColor,
            glow: menuBarHighlightGlow
        )
    }

    var effectiveSideNotchColors: SideNotchColorSettings {
        switch sideNotch.colorSource {
        case .menuBar: menuBarColorsForSideNotch
        case .custom: sideNotch.customColors ?? menuBarColorsForSideNotch
        }
    }
}
