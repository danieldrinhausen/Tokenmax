import Foundation

/// What became of one opener run.
enum SessionOpenerOutcome: String, Codable, Sendable, Equatable {
    /// The CLI answered. Whether a new window actually opened is not yet known.
    case sent
    /// The usage endpoint confirmed the reset timestamp advanced.
    case verified
    /// The CLI answered but the reset never advanced within the verification
    /// budget. Deliberately terminal — see `SessionOpenerCoordinator`.
    case unverified
    /// The process never produced a usable result. Treated as "probably spent
    /// nothing", which is why it alone permits a retry.
    case failed
}

struct SessionOpenerAttempt: Codable, Sendable, Equatable, Identifiable {
    var cycleID: String
    var startedAt: Date
    var outcome: SessionOpenerOutcome
    var model: String
    var resultText: String?
    var errorMessage: String?
    var costUSD: Double?
    var sessionID: String?
    var verifyAttempts: Int
    var verifiedResetAt: Date?

    var id: String { "\(cycleID)@\(startedAt.timeIntervalSince1970)" }

    init(
        cycleID: String,
        startedAt: Date,
        outcome: SessionOpenerOutcome,
        model: String,
        resultText: String? = nil,
        errorMessage: String? = nil,
        costUSD: Double? = nil,
        sessionID: String? = nil,
        verifyAttempts: Int = 0,
        verifiedResetAt: Date? = nil
    ) {
        self.cycleID = cycleID
        self.startedAt = startedAt
        self.outcome = outcome
        self.model = model
        self.resultText = resultText
        self.errorMessage = errorMessage
        self.costUSD = costUSD
        self.sessionID = sessionID
        self.verifyAttempts = verifyAttempts
        self.verifiedResetAt = verifiedResetAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try container.decodeIfPresent(String.self, forKey: .cycleID) ?? ""
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        // An unreadable outcome must not read as "still open for business".
        outcome = (try? container.decodeIfPresent(SessionOpenerOutcome.self, forKey: .outcome)) ?? .unverified
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "haiku"
        resultText = try container.decodeIfPresent(String.self, forKey: .resultText)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        verifyAttempts = try container.decodeIfPresent(Int.self, forKey: .verifyAttempts) ?? 0
        verifiedResetAt = try container.decodeIfPresent(Date.self, forKey: .verifiedResetAt)
    }
}

/// Persisted so a relaunch cannot re-open a cycle Tokenmax already acted on.
///
/// This is not derived data. Losing `session-opener-state.json` means losing the
/// record of what was already spent, which is the one thing that must survive a
/// crash — hence the attempt is written *before* the process is spawned.
struct SessionOpenerState: Codable, Sendable, Equatable {
    var attempts: [SessionOpenerAttempt] = []
    /// The most recent session `resetAt` ever observed. Survives relaunch, which
    /// is what lets the opener still know a window ended while nothing was
    /// running to watch it end.
    var lastKnownSessionResetAt: Date?
    /// Cycles for which the coordinator already burned its one backoff-bypassing
    /// refresh. Bounded so a long stale spell cannot churn the network.
    var forcedRefreshCycleIDs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attempts = try container.decodeIfPresent([SessionOpenerAttempt].self, forKey: .attempts) ?? []
        lastKnownSessionResetAt = try container.decodeIfPresent(Date.self, forKey: .lastKnownSessionResetAt)
        forcedRefreshCycleIDs = try container.decodeIfPresent([String].self, forKey: .forcedRefreshCycleIDs) ?? []
    }

    // MARK: - Queries

    func attempts(for cycleID: String) -> [SessionOpenerAttempt] {
        attempts.filter { $0.cycleID == cycleID }
    }

    /// A cycle is settled once any attempt actually reached Claude. Only
    /// `.failed` — where nothing was confirmed spent — leaves it open.
    func isSettled(_ cycleID: String) -> Bool {
        attempts(for: cycleID).contains { $0.outcome != .failed }
    }

    func lastAttempt(for cycleID: String) -> SessionOpenerAttempt? {
        attempts(for: cycleID).max { $0.startedAt < $1.startedAt }
    }

    var mostRecentAttempt: SessionOpenerAttempt? {
        attempts.max { $0.startedAt < $1.startedAt }
    }

    // MARK: - Mutation

    mutating func record(_ attempt: SessionOpenerAttempt) {
        if let index = attempts.firstIndex(where: { $0.id == attempt.id }) {
            attempts[index] = attempt
        } else {
            attempts.append(attempt)
        }
        if attempts.count > 40 {
            attempts.removeFirst(attempts.count - 40)
        }
    }

    mutating func markForcedRefresh(_ cycleID: String) {
        guard !forcedRefreshCycleIDs.contains(cycleID) else { return }
        forcedRefreshCycleIDs.append(cycleID)
        if forcedRefreshCycleIDs.count > 40 {
            forcedRefreshCycleIDs.removeFirst(forcedRefreshCycleIDs.count - 40)
        }
    }

    func hasForcedRefresh(_ cycleID: String) -> Bool {
        forcedRefreshCycleIDs.contains(cycleID)
    }
}
