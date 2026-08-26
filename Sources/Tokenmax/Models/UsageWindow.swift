import Foundation

enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case session
    case weekly
    case modelSpecificWeekly
}

/// Where a window's numbers came from. The CLI-based and web-scraping sources
/// from the original spec do not exist — see the plan's research notes.
enum UsageSource: String, Codable, Sendable {
    case claudeOAuth
    case statusline
    case codexAppServer
    case manual

    var displayName: String {
        switch self {
        case .claudeOAuth: "Claude account"
        case .statusline: "Claude Code status line"
        case .codexAppServer: "Codex App Server"
        case .manual: "Manual"
        }
    }
}

enum UsageConfidence: String, Codable, Sendable {
    case authoritative
    case observed
    case estimated
    case stale
    case unavailable

    /// Ranking used when the same window is reported by more than one source.
    var rank: Int {
        switch self {
        case .authoritative: 4
        case .observed: 3
        case .estimated: 2
        case .stale: 1
        case .unavailable: 0
        }
    }
}

/// A single quota window.
///
/// Both upstream sources report *used* percentage, so that is the stored truth
/// and `remainingPercent` is derived. Persisting both independently would let
/// them drift.
struct UsageWindow: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let kind: UsageWindowKind
    let label: String

    var usedPercent: Double?
    var resetAt: Date?

    var observedAt: Date
    var source: UsageSource
    var confidence: UsageConfidence

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    var isExhausted: Bool {
        (remainingPercent ?? 100) <= 0.5
    }

    /// No window is currently running.
    ///
    /// A Claude Code session window starts on *first use*, not on a fixed
    /// schedule, so between the old window expiring and the next prompt the
    /// endpoint reports the window with nothing used and no reset time. That is
    /// a normal idle state, not missing data — conflating the two makes the app
    /// claim the reset time is "unknown" when the truth is that there is
    /// nothing to know yet.
    var hasNotStarted: Bool {
        resetAt == nil && (usedPercent ?? 0) <= 0
    }

    func timeUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let resetAt else { return nil }
        let interval = resetAt.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }
}

struct ProviderUsage: Codable, Sendable {
    let providerID: String
    let planName: String?
    let windows: [UsageWindow]
    let fetchedAt: Date
    /// Whether the account can spend past its plan allowance as a real charge.
    /// `nil` means the source did not say — which is *not* the same as "off",
    /// and anything that decides whether to spend must treat it as unknown.
    let extraUsageEnabled: Bool?
    /// Promotional, banked Codex resets. `nil` means the source is too old to
    /// report them; zero is an authoritative "none available".
    let availableResetCount: Int?
    let availableResetExpiresAt: Date?

    init(
        providerID: String,
        planName: String?,
        windows: [UsageWindow],
        fetchedAt: Date,
        extraUsageEnabled: Bool? = nil,
        availableResetCount: Int? = nil,
        availableResetExpiresAt: Date? = nil
    ) {
        self.providerID = providerID
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.extraUsageEnabled = extraUsageEnabled
        self.availableResetCount = availableResetCount
        self.availableResetExpiresAt = availableResetExpiresAt
    }
}

/// The last thing we successfully knew, persisted across launches so the
/// menubar is populated immediately on relaunch rather than blank.
struct UsageSnapshot: Codable, Sendable {
    let providerID: String
    let planName: String?
    let windows: [UsageWindow]
    let fetchedAt: Date
    let fetchDuration: TimeInterval
    let errorMessage: String?
    /// Carried from `ProviderUsage`. Optional is load-bearing twice over: it
    /// distinguishes "credits are off" from "the source did not say", and it is
    /// what lets a snapshot file written before this field existed still
    /// decode — synthesized `Codable` only tolerates an absent key when the
    /// property is optional.
    let extraUsageEnabled: Bool?
    /// Optional for the same compatibility reason as `extraUsageEnabled`:
    /// snapshots written before Codex reported reset credits still load.
    let availableResetCount: Int?
    let availableResetExpiresAt: Date?

    init(
        providerID: String,
        planName: String?,
        windows: [UsageWindow],
        fetchedAt: Date,
        fetchDuration: TimeInterval,
        errorMessage: String?,
        extraUsageEnabled: Bool? = nil,
        availableResetCount: Int? = nil,
        availableResetExpiresAt: Date? = nil
    ) {
        self.providerID = providerID
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.fetchDuration = fetchDuration
        self.errorMessage = errorMessage
        self.extraUsageEnabled = extraUsageEnabled
        self.availableResetCount = availableResetCount
        self.availableResetExpiresAt = availableResetExpiresAt
    }

    func window(_ kind: UsageWindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    var sessionWindow: UsageWindow? { window(.session) }
    var weeklyWindow: UsageWindow? { window(.weekly) }

    func isStale(now: Date = Date(), threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) > threshold
    }
}

/// Everything the UI needs to render, including all the failure modes the spec
/// requires be handled explicitly.
enum UsageState: Sendable {
    case loading
    case claudeCodeNotInstalled
    case notAuthenticated
    case keychainAccessDenied
    /// Transient: the saved credential was rejected, though a Claude Code
    /// session can still hold a working connection of its own. The last good
    /// reading is carried through because it is still the best information
    /// available — blanking the popover to "Never updated" over a credential
    /// that normally heals itself within minutes throws away data for nothing.
    case tokenExpired(lastGood: UsageSnapshot?)
    case needsReauthentication
    case unavailable(lastGood: UsageSnapshot?, message: String)
    case loaded(UsageSnapshot)

    var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot): snapshot
        case let .unavailable(lastGood, _): lastGood
        case let .tokenExpired(lastGood): lastGood
        default: nil
        }
    }

    /// A cached OAuth response is useful for rendering the last known quota,
    /// but it does not mean an expired Claude Code token became usable again.
    /// Keep the recovery state until a source actually observed data later than
    /// the snapshot that was present when the token failure occurred.
    /// Whether this state is carrying a reading at all, regardless of how the
    /// last refresh went.
    var hasLastGood: Bool { snapshot != nil }
}
