import Foundation

/// Every path Tokenmax writes to. Nothing outside this directory is touched
/// except `~/.claude/settings.json`, and only when the user explicitly installs
/// the statusline shim.
enum FileLocations {
    static let supportDirectory: URL = {
        // Tests set TOKENMAX_SUPPORT_DIR to a scratch path. Without it a test
        // run writes its fixtures straight into the user's real data.
        let base: URL = if let override = ProcessInfo.processInfo.environment["TOKENMAX_SUPPORT_DIR"] {
            URL(fileURLWithPath: override, isDirectory: true)
        } else {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tokenmax", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var tasksFile: URL { supportDirectory.appendingPathComponent("tokenmax.json") }
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var usageSnapshotFile: URL { supportDirectory.appendingPathComponent("usage-snapshot.json") }
    static var notificationStateFile: URL { supportDirectory.appendingPathComponent("notification-state.json") }
    /// Which reset cycles the session opener has already acted on. Not derived
    /// data — losing it would let the same cycle be opened twice.
    static var sessionOpenerStateFile: URL { supportDirectory.appendingPathComponent("session-opener-state.json") }

    /// Every task run Tokenmax has started. Not derived data either: it is the
    /// only record of quota already spent, and the only way a relaunch can tell
    /// an abandoned run from one that never happened.
    static var queueAutoRunStateFile: URL { supportDirectory.appendingPathComponent("queue-autorun-state.json") }

    /// One `<runID>.log` per task run, holding the raw CLI stream.
    static var runLogsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("run-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func runLogFile(runID: UUID) -> URL {
        runLogsDirectory.appendingPathComponent("\(runID.uuidString).log")
    }

    /// Written by the statusline shim, read by `StatuslineUsageReader`.
    static var statuslineFile: URL { supportDirectory.appendingPathComponent("statusline-latest.json") }

    static var statuslineScript: URL { supportDirectory.appendingPathComponent("tokenmax-statusline.sh") }

    static var logsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var logFile: URL { logsDirectory.appendingPathComponent("tokenmax.log") }

    static var claudeSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
}
