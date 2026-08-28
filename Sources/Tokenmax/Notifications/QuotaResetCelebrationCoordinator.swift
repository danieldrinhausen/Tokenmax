import AppKit
import Foundation

/// Watches successive successful snapshots and presents the visual only once a
/// fresh response has proved that a window actually rolled over.
@MainActor
final class QuotaResetCelebrationCoordinator {
    private let usage: ProviderUsageCoordinator
    private let settingsStore: SettingsStore
    private let presenter: FireworksPresenter
    private var previous: [TokenmaxProvider: UsageSnapshot] = [:]
    private var observer: NSObjectProtocol?

    init(usage: ProviderUsageCoordinator, settingsStore: SettingsStore, presenter: FireworksPresenter = FireworksPresenter()) {
        self.usage = usage
        self.settingsStore = settingsStore
        self.presenter = presenter
    }

    func start() {
        guard observer == nil else { return }
        // A snapshot loaded from disk is the last confirmed state before a
        // relaunch, so a reset while Tokenmax was closed still has evidence.
        for provider in TokenmaxProvider.allCases {
            if let snapshot = usage.snapshot(for: provider) { previous[provider] = snapshot }
        }
        observer = NotificationCenter.default.addObserver(forName: .tokenmaxUsageUpdated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    private func evaluate() {
        let settings = settingsStore.settings.resetCelebration
        let now = Date()
        var shouldCelebrate = false
        for provider in TokenmaxProvider.allCases {
            guard let current = usage.snapshot(for: provider) else { continue }
            for kind in [UsageWindowKind.session, .weekly] {
                let verdict = QuotaResetCelebrationDecision.decide(.init(
                    provider: provider, kind: kind, previous: previous[provider]?.window(kind),
                    current: current.window(kind), settings: settings,
                    isStale: usage.isStale(for: provider),
                    isQuietHours: settingsStore.settings.quietHours.contains(now), now: now
                ))
                if case .celebrate(let event) = verdict {
                    shouldCelebrate = true
                    Log.shared.write("celebration: \(event.rawValue) reset confirmed")
                }
            }
            // Enabling it later means future resets, not an overdue surprise.
            previous[provider] = current
        }
        if shouldCelebrate { presenter.show() }
    }
}
