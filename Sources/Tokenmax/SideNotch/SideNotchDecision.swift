import CoreGraphics
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
    case closeDelayElapsed(keepRailVisible: Bool)
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

        case let .closeDelayElapsed(keepRailVisible):
            return keepRailVisible ? .rail : .peek
        }
    }

    /// A persistent Dock Notch still uses the same provider detail states, but
    /// never returns to the tiny hover handle between inspections.
    static func resolvedState(
        _ state: SideNotchState,
        placement: SideNotchPlacement,
        dockAlwaysExpanded: Bool
    ) -> SideNotchState {
        guard placement == .dock, dockAlwaysExpanded, state == .peek else { return state }
        return .rail
    }
}

/// Maps the stored placement choice to screen coordinates without consulting
/// AppKit. The coordinator supplies the live display rectangles and owns the
/// panels; this type keeps the placement contract testable.
enum SideNotchLayoutDecision {
    /// Breathing room between two independently rounded surfaces.
    private static let dockGap: CGFloat = 18
    private static let fallbackDockHalfWidth: CGFloat = 420

    static func railFrame(
        placement: SideNotchPlacement,
        dockPlacement: DockNotchPlacement,
        screen: CGRect,
        visibleScreen: CGRect,
        dockFrame: CGRect?,
        size: CGSize
    ) -> CGRect {
        switch placement {
        case .side:
            return CGRect(
                x: visibleScreen.maxX - size.width,
                y: visibleScreen.midY - size.height / 2,
                width: size.width,
                height: size.height
            )

        case .dock:
            let x: CGFloat
            if let dockFrame {
                switch dockPlacement {
                case .left:
                    x = dockFrame.minX - Self.dockGap - size.width
                case .right:
                    x = dockFrame.maxX + Self.dockGap
                }
            } else {
                switch dockPlacement {
                case .left:
                    x = screen.midX - Self.fallbackDockHalfWidth - Self.dockGap - size.width
                case .right:
                    x = screen.midX + Self.fallbackDockHalfWidth + Self.dockGap
                }
            }
            // The Dock itself meets the display edge. Sharing that baseline is
            // what makes the separate surface read as part of the same shelf.
            let y = screen.minY
            return CGRect(
                x: min(visibleScreen.maxX - size.width, max(visibleScreen.minX, x)),
                y: y,
                width: size.width,
                height: size.height
            )
        }
    }

    static func detailFrame(
        placement: SideNotchPlacement,
        railFrame: CGRect,
        visibleScreen: CGRect,
        detailSize: CGSize,
        providerIndex: Int,
        railHeaderHeight: CGFloat,
        providerRowHeight: CGFloat
    ) -> CGRect {
        switch placement {
        case .side:
            let cellCenterFromTop = railHeaderHeight
                + CGFloat(providerIndex) * providerRowHeight
                + providerRowHeight / 2
            let targetCenterY = railFrame.maxY - cellCenterFromTop
            return CGRect(
                x: railFrame.minX - detailSize.width,
                y: min(
                    visibleScreen.maxY - detailSize.height,
                    max(visibleScreen.minY, targetCenterY - detailSize.height / 2)
                ),
                width: detailSize.width,
                height: detailSize.height
            )

        case .dock:
            return CGRect(
                x: min(
                    visibleScreen.maxX - detailSize.width,
                    max(visibleScreen.minX, railFrame.midX - detailSize.width / 2)
                ),
                y: min(visibleScreen.maxY - detailSize.height, railFrame.maxY + 8),
                width: detailSize.width,
                height: detailSize.height
            )
        }
    }
}
