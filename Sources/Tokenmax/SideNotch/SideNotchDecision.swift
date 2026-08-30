import Foundation

enum SideNotchSuppressionReason: Equatable, Sendable {
    case disabled
    case sessionInactive
    case noScreen

    var explanation: String {
        switch self {
        case .disabled: "The Side Notch alpha is switched off."
        case .sessionInactive: "The Side Notch is hidden while this Mac is locked or asleep."
        case .noScreen: "The Side Notch is waiting for an available display."
        }
    }
}

enum SideNotchState: Equatable, Sendable {
    case peek
    case rail
    case detail(provider: TokenmaxProvider, locked: Bool)

    var selectedProvider: TokenmaxProvider? {
        guard case let .detail(provider, _) = self else { return nil }
        return provider
    }

    var isLocked: Bool {
        guard case let .detail(_, locked) = self else { return false }
        return locked
    }
}

enum SideNotchEvent: Equatable, Sendable {
    case pointerEnteredHandle
    case pointerEnteredRail
    case pointerEnteredProvider(TokenmaxProvider)
    case providerClicked(TokenmaxProvider)
    case closeDelayElapsed
}

/// The interaction state machine. Timers and tracking areas belong to the
/// coordinator; what an event means stays here where every branch is testable.
enum SideNotchDecision {
    static func suppression(
        enabled: Bool,
        sessionIsActive: Bool,
        screenIsAvailable: Bool
    ) -> SideNotchSuppressionReason? {
        if !enabled { return .disabled }
        if !sessionIsActive { return .sessionInactive }
        if !screenIsAvailable { return .noScreen }
        return nil
    }

    static func reduce(_ state: SideNotchState, event: SideNotchEvent) -> SideNotchState {
        switch event {
        case .pointerEnteredHandle:
            return state == .peek ? .rail : state

        case .pointerEnteredRail:
            return state.isLocked ? state : .rail

        case let .pointerEnteredProvider(provider):
            return state.isLocked ? state : .detail(provider: provider, locked: false)

        case let .providerClicked(provider):
            if case let .detail(selected, locked) = state, selected == provider {
                return locked ? .rail : .detail(provider: provider, locked: true)
            }
            return .detail(provider: provider, locked: true)

        case .closeDelayElapsed:
            return .peek
        }
    }
}
