import Foundation

/// When a failed refresh is tried again. Pure, so the schedule and the retry
/// arithmetic are testable without a clock or a coordinator.
enum RefreshBackoff {
    /// Seconds to wait after the 1st, 2nd, 3rd… consecutive failure; the last
    /// entry repeats.
    static let schedule: [TimeInterval] = [30, 60, 120, 300]

    /// How long to stay quiet after the `failures`-th consecutive failure.
    static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        schedule[min(max(failures, 1) - 1, schedule.count - 1)]
    }

    /// Slack past the moment a floor lifts, so the retry never lands a hair
    /// inside it and replays the failure it was meant to get past.
    static let margin: TimeInterval = 1

    /// Seconds until the one-shot retry should run: the backoff, and never
    /// before the request floor ends. Retrying inside the floor could only
    /// repeat the last answer, and would count as another failure.
    static func retryDelay(backoff: TimeInterval, floorEndsAt: Date?, now: Date) -> TimeInterval {
        let floorWait = floorEndsAt.map { $0.timeIntervalSince(now) } ?? 0
        return max(backoff, floorWait) + margin
    }

    /// Whether a failure is the kind that clears by itself and so deserves a
    /// retry without anyone asking. A refused keychain, a missing install or a
    /// login that needs a person are not: retrying those only repeats the
    /// question (or the dialog) the user has already answered.
    static func isRetryable(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return true }
        switch providerError {
        case .underlying: return true
        case .notInstalled, .notAuthenticated, .accessDenied, .tokenExpired, .needsReauthentication,
             .noWindowsReturned, .statuslineNoData, .apiKeyConfigured, .requestFloorActive:
            return false
        }
    }
}
