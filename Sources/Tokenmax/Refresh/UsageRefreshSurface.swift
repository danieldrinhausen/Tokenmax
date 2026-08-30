import Foundation

/// A visible surface that benefits from foreground quota polling. A set is
/// used because closing one surface must not slow another one that is still on
/// screen.
enum UsageRefreshSurface: Hashable, Sendable {
    case popover
    case sideNotch

    var logName: String {
        switch self {
        case .popover: "popover"
        case .sideNotch: "side notch"
        }
    }
}
