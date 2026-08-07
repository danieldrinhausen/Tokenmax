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
    /// Kept separate from the legacy Claude snapshot so upgrading never has to
    /// rewrite or risk the user's last known Claude reading.
    static var codexUsageSnapshotFile: URL { supportDirectory.appendingPathComponent("codex-usage-snapshot.json") }
    /// The fetched list of Claude models, cached so the task editor is
    /// populated at launch and keeps working offline.
    static var modelCatalogFile: URL { supportDirectory.appendingPathComponent("model-catalog.json") }
    /// The same, for Codex. Separate file rather than a shared one so a stale or
    /// corrupt catalog for one provider cannot empty the other's picker.
    static var codexModelCatalogFile: URL {
        supportDirectory.appendingPathComponent("codex-model-catalog.json")
    }
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

    /// Deletes every run log that no surviving run refers to.
    ///
    /// `QueueAutoRunState` keeps the last 40 runs and drops the rest, but the
    /// transcripts themselves were never removed with them — so they accumulated
    /// without bound, unreachable from the UI and holding whatever the task
    /// prompted and the CLI printed. Driving this from the live run IDs rather
    /// than a count also clears anything a previous version orphaned.
    ///
    /// Returns the number of files removed, for the log line.
    @discardableResult
    static func pruneRunLogs(keeping liveRunIDs: Set<UUID>) -> Int {
        let directory = runLogsDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }

        var removed = 0
        for name in names where name.hasSuffix(".log") {
            // Anything not named after a run id is not ours to delete.
            guard let id = UUID(uuidString: String(name.dropLast(4))), !liveRunIDs.contains(id) else {
                continue
            }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Written by the statusline shim, read by `StatuslineUsageReader`.
    static var statuslineFile: URL { supportDirectory.appendingPathComponent("statusline-latest.json") }

    static var statuslineScript: URL { supportDirectory.appendingPathComponent("tokenmax-statusline.sh") }

    /// The exact `statusLine` value displaced by the shim. Separate from the
    /// settings-file backup because uninstall must restore this across launches,
    /// after later Claude Code edits have legitimately changed other keys.
    static var statuslineBackupFile: URL {
        supportDirectory.appendingPathComponent("statusline-previous.json")
    }

    static var logsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var logFile: URL { logsDirectory.appendingPathComponent("tokenmax.log") }

    /// Claude Code's own configuration directory.
    ///
    /// Overridable for the same reason as `supportDirectory`, and more urgently:
    /// anything exercising the statusline installer writes here, and without an
    /// override a test run would edit the developer's real Claude Code setup.
    static var claudeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENMAX_CLAUDE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var claudeSettingsFile: URL {
        claudeDirectory.appendingPathComponent("settings.json")
    }
}
