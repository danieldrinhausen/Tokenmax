import Foundation

/// The side-effect-free proof that an observed reset is a new, active quota
/// window. A countdown reaching zero is not proof: stale data and reset-time
/// jitter make that guess visibly wrong.
enum QuotaResetCelebrationDecision {
    struct Input: Sendable {
        let provider: TokenmaxProvider
        let kind: UsageWindowKind
        let previous: UsageWindow?
        let current: UsageWindow?
        let settings: QuotaResetCelebrationSettings
        let isStale: Bool
        let isQuietHours: Bool
        let now: Date
    }

    enum Suppression: String, Sendable, Equatable {
        case disabled, eventNotSelected, unsupportedWindow, dataStale, quietHours
        case noPreviousWindow, noResetTime, previousWindowStillActive, sameWindow, successorNotActive
    }

    enum Verdict: Sendable, Equatable {
        case celebrate(QuotaResetEvent)
        case suppress(Suppression)
    }

    static func decide(_ input: Input) -> Verdict {
        guard input.settings.enabled else { return .suppress(.disabled) }
        guard let event = QuotaResetEvent(provider: input.provider, kind: input.kind) else {
            return .suppress(.unsupportedWindow)
        }
        guard input.settings.includes(event) else { return .suppress(.eventNotSelected) }
        guard !input.isStale else { return .suppress(.dataStale) }
        guard !input.isQuietHours else { return .suppress(.quietHours) }
        guard let previous = input.previous else { return .suppress(.noPreviousWindow) }
        guard let oldReset = previous.resetAt, let newReset = input.current?.resetAt else {
            return .suppress(.noResetTime)
        }
        guard oldReset <= input.now else { return .suppress(.previousWindowStillActive) }
        guard newReset > oldReset else { return .suppress(.sameWindow) }
        guard newReset > input.now else { return .suppress(.successorNotActive) }
        return .celebrate(event)
    }
}
