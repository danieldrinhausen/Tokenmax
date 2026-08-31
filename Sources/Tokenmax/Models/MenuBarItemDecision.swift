import Foundation

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
}
