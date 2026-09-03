import Foundation

/// The one-second clock every countdown label reads.
///
/// Split out of `UsageRefreshCoordinator` because `ObservableObject`
/// invalidation is per *object*, never per property. While the tick sat beside
/// the usage state, one shared object carried both, so a clock that has to
/// advance every second rebuilt every view holding `@EnvironmentObject var
/// usage` — including settings panes that show no countdown at all and keep the
/// reference only to call an action from a button. `GeneralSettingsView` was
/// the expensive case: a several-hundred-row `Form` relaid out once a second,
/// which on its own saturated the main thread and made every click queue behind
/// a layout pass.
///
/// So observe this object *only* where a label actually counts down. Everything
/// that wants a reading rather than a clock keeps observing the usage
/// coordinator, and no longer pays for the tick.
@MainActor
final class CountdownClock: ObservableObject {
    @Published private(set) var now = Date()

    private var timer: Timer?

    /// Idempotent, like the coordinators that drive it.
    func start() {
        guard timer == nil else { return }
        // `.common` so countdowns keep moving while a menu is tracking; the
        // menu bar popover is exactly where a frozen countdown would show.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
