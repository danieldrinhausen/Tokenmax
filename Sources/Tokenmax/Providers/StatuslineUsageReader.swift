import Foundation

/// Reads the payload captured by the statusline shim.
///
/// This is the *documented* source (`code.claude.com/docs/en/statusline`), but
/// it only updates while a Claude Code session is running and only appears
/// after the first API response in that session — so it is a fallback, not the
/// primary. `resets_at` here is epoch **seconds**.
struct StatuslinePayload: Decodable, Sendable {
    struct RateLimitWindow: Decodable, Sendable {
        let usedPercentage: Double?
        let resetsAt: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        var resetDate: Date? { resetsAt.map { DateNormalizer.fromEpoch($0) } }
    }

    struct RateLimits: Decodable, Sendable {
        let fiveHour: RateLimitWindow?
        let sevenDay: RateLimitWindow?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    let rateLimits: RateLimits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

enum StatuslineUsageReader {
    /// Returns the payload plus the file's modification time, which is the only
    /// honest "observed at" we have for this source.
    static func read(from url: URL = FileLocations.statuslineFile) -> (StatuslinePayload, Date)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(StatuslinePayload.self, from: data) else {
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date()
        return (payload, modified)
    }

    static func windows(from payload: StatuslinePayload, observedAt: Date) -> [UsageWindow] {
        var result: [UsageWindow] = []

        if let five = payload.rateLimits?.fiveHour, five.usedPercentage != nil {
            result.append(UsageWindow(
                id: "claude.session",
                kind: .session,
                label: "Session",
                usedPercent: five.usedPercentage,
                resetAt: five.resetDate,
                observedAt: observedAt,
                source: .statusline,
                confidence: .observed
            ))
        }

        if let week = payload.rateLimits?.sevenDay, week.usedPercentage != nil {
            result.append(UsageWindow(
                id: "claude.weekly",
                kind: .weekly,
                label: "Weekly",
                usedPercent: week.usedPercentage,
                resetAt: week.resetDate,
                observedAt: observedAt,
                source: .statusline,
                confidence: .observed
            ))
        }

        return result
    }
}
