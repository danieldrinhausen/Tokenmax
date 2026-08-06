import Foundation

/// Why a check did not run, or ran and offered nothing.
///
/// Per the house rule, every branch that declines to act names itself instead
/// of returning quietly: the reason is shown in Settings → About and written to
/// the log, so "it never tells me about updates" is answerable without a
/// debugger.
enum UpdateCheckSuppression: String, Equatable, Sendable {
    case switchedOff
    case checkedRecently
    case unreadableTag
    case unreadableOwnVersion
    case notNewer

    var summary: String {
        switch self {
        case .switchedOff: "Update checks are switched off."
        case .checkedRecently: "Checked recently."
        case .unreadableTag: "The latest release tag was not a version number."
        case .unreadableOwnVersion: "This build does not report a readable version."
        case .notNewer: "Tokenmax is up to date."
        }
    }
}

/// Whether to spend a request at all.
enum UpdateCheckDecision: Equatable, Sendable {
    case check
    case skip(UpdateCheckSuppression)
}

/// What the answer turned out to mean.
enum UpdateOffer: Equatable, Sendable {
    case available(AppVersion)
    case none(UpdateCheckSuppression)
}

/// The rules, with no clock, no network and no settings file of their own — so
/// every one of them is testable without running the app. `UpdateCheckCoordinator`
/// owns the side effects.
enum UpdateCheck {
    /// Once a day. This is a courtesy notice about a hobby project's releases,
    /// not a quota meter: checking more often would spend somebody's
    /// unauthenticated GitHub rate limit to learn nothing.
    static let interval: TimeInterval = 24 * 60 * 60

    /// `force` is the explicit "Check Now" button, and only that. An automatic
    /// caller that sets it turns a daily request into a per-tick one — the same
    /// trap `ClaudeModelCatalogClient.fetch` guards against.
    static func decide(
        enabled: Bool,
        lastCheckedAt: Date?,
        now: Date,
        force: Bool = false
    ) -> UpdateCheckDecision {
        // Ahead of the enablement check on purpose: pressing the button in
        // Settings is a direct instruction, and refusing it because the
        // background check is off would look broken.
        if force { return .check }
        guard enabled else { return .skip(.switchedOff) }
        guard let lastCheckedAt else { return .check }
        guard now.timeIntervalSince(lastCheckedAt) >= interval else {
            return .skip(.checkedRecently)
        }
        return .check
    }

    /// Strictly newer, never merely different. A user running a build *ahead*
    /// of the latest release — anyone who built from source — must not be
    /// nagged to downgrade to it.
    static func offer(currentVersion: String, latestTag: String) -> UpdateOffer {
        guard let current = AppVersion(currentVersion) else {
            return .none(.unreadableOwnVersion)
        }
        guard let latest = AppVersion(latestTag) else {
            return .none(.unreadableTag)
        }
        return latest > current ? .available(latest) : .none(.notNewer)
    }
}
