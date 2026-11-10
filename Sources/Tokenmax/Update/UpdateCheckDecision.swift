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

/// What survives a relaunch, so the daily cadence is real and a found update
/// is still on screen after a restart.
///
/// Without `lastCheckedAt` every launch looked like a first check and asked
/// GitHub again, so "once a day" held only for a Mac that never restarted. The
/// tag and page are kept too: skipping today's check because yesterday's ran
/// would otherwise blank the badge that check found, until the day was up.
struct UpdateCheckRecord: Codable, Equatable, Sendable {
    var lastCheckedAt: Date?
    var latestTag: String?
    var releasePage: String?

    init(lastCheckedAt: Date? = nil, latestTag: String? = nil, releasePage: String? = nil) {
        self.lastCheckedAt = lastCheckedAt
        self.latestTag = latestTag
        self.releasePage = releasePage
    }

    /// Tolerant like every persisted shape here: a missing or mistyped field is
    /// "never checked", which only costs one request.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)) ?? nil
        latestTag = (try? container.decodeIfPresent(String.self, forKey: .latestTag)) ?? nil
        releasePage = (try? container.decodeIfPresent(String.self, forKey: .releasePage)) ?? nil
    }
}

extension UpdateCheck {
    /// The offer is re-derived from the remembered tag against the version
    /// running *now*: the user may have updated since the check, and a stored
    /// "available" must not outlive the update it announced.
    static func restoredState(from record: UpdateCheckRecord, currentVersion: String) -> UpdateCheckState {
        guard let tag = record.latestTag else { return .idle }
        switch offer(currentVersion: currentVersion, latestTag: tag) {
        case let .available(version):
            guard let page = record.releasePage.flatMap(URL.init(string:)) else { return .idle }
            return .available(version, page: page)
        case .none:
            return .upToDate
        }
    }

    /// A failed check says it could not complete, but never replaces an offer
    /// already found: being unable to ask again does not make the release go
    /// away. Stale data postpones; it never cancels.
    static func stateAfterFailure(previous: UpdateCheckState, message: String) -> UpdateCheckState {
        if case .available = previous { return previous }
        return .unavailable(message)
    }
}
