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
    /// A Dock's icon span changes with magnification and is not a stable public
    /// geometry contract. The two choices therefore name the bottom display
    /// sides flanking the Dock zone, rather than pretending to know its live
    /// icon bounds.
    private static let dockEdgeInset: CGFloat = 12
    /// A bottom Dock's default, start-pinned footprint. Its exact icon bounds
    /// are unavailable, but this leaves the chosen side close to the Dock
    /// rather than marooned at the far display edge.
    private static let dockZoneWidth: CGFloat = 200
    private static let dockGap: CGFloat = 18

    static func railFrame(
        placement: SideNotchPlacement,
        dockPlacement: DockNotchPlacement,
        screen: CGRect,
        visibleScreen: CGRect,
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
            switch dockPlacement {
            case .left:
                x = visibleScreen.minX + Self.dockEdgeInset
            case .right:
                x = visibleScreen.minX + Self.dockZoneWidth + Self.dockGap
            }
            return CGRect(
                x: min(visibleScreen.maxX - size.width, max(visibleScreen.minX, x)),
                y: screen.minY + Self.dockEdgeInset,
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
