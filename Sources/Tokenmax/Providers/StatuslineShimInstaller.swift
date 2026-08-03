import Foundation

/// Installs the optional statusline shim.
///
/// This writes to the user's `~/.claude/settings.json`, so it is **never**
/// automatic — it only runs when the user clicks Install in Settings. The shim
/// re-execs any previously configured statusline command so an existing setup
/// keeps working.
enum StatuslineShimInstaller {
    enum InstallError: LocalizedError {
        case cannotReadSettings
        case cannotWriteSettings(String)

        var errorDescription: String? {
            switch self {
            case .cannotReadSettings:
                "~/.claude/settings.json could not be parsed, so Tokenmax will not touch it — "
                    + "rewriting it from here would discard everything already in it. Fix the JSON "
                    + "and try again."
            case let .cannotWriteSettings(message):
                "Could not update ~/.claude/settings.json: \(message)"
            }
        }
    }

    private static func script(wrapping previous: String?) -> String {
        let passthrough: String = if let previous, !previous.isEmpty {
            """
            # Re-run the statusline command that was configured before Tokenmax,
            # feeding it the same payload so the existing status line still works.
            printf '%s' "$payload" | \(previous)
            """
        } else {
            """
            # No previous status line was configured; print a compact default.
            printf '%s' "$payload" | /usr/bin/jq -r '
              [ (.model.display_name // empty),
                (if .rate_limits.five_hour.used_percentage then
                   "5h " + ((100 - .rate_limits.five_hour.used_percentage) | floor | tostring) + "%"
                 else empty end),
                (if .rate_limits.seven_day.used_percentage then
                   "7d " + ((100 - .rate_limits.seven_day.used_percentage) | floor | tostring) + "%"
                 else empty end)
              ] | map(select(. != null and . != "")) | join("  ·  ")
            ' 2>/dev/null
            """
        }

        return """
        #!/bin/bash
        # Installed by Tokenmax. Captures the Claude Code status line payload so
        # Tokenmax can read quota while a session is running, then delegates to
        # whatever status line was configured before.
        #
        # Safe to delete: removing the "statusLine" key from ~/.claude/settings.json
        # fully uninstalls it.

        set -uo pipefail

        payload="$(cat)"
        out="$HOME/Library/Application Support/Tokenmax/statusline-latest.json"
        tmp="$out.tmp.$$"

        mkdir -p "$(dirname "$out")"
        printf '%s' "$payload" > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null
        rm -f "$tmp" 2>/dev/null

        \(passthrough)
        """
    }

    static var isInstalled: Bool {
        guard let settings = readClaudeSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return false }
        return command.contains("tokenmax-statusline")
    }

    static func install() throws {
        // `?? [:]` here would have been a config-shredder: a settings.json that
        // fails to parse — a truncated write, or the `//` comments people add
        // because other tools accept them — read as "empty", and the write below
        // would then replace the user's permissions, env, hooks and MCP servers
        // with a file containing nothing but `statusLine`. An unparseable file
        // is a reason to stop, not to start from scratch.
        guard var settings = readClaudeSettings() else { throw InstallError.cannotReadSettings }

        // Preserve any existing statusline so we can chain to it.
        var previousCommand: String?
        if let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           !command.contains("tokenmax-statusline")
        {
            previousCommand = command
        }

        let scriptURL = FileLocations.statuslineScript
        do {
            try script(wrapping: previousCommand).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw InstallError.cannotWriteSettings(error.localizedDescription)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": scriptURL.path,
        ]

        try writeClaudeSettings(settings)
        Log.shared.write("statusline shim installed (wrapping: \(previousCommand ?? "none"))")
    }

    static func uninstall() throws {
        // Same reasoning as `install`, plus: returning quietly here would leave
        // the shim wired up with the button that removes it doing nothing.
        guard var settings = readClaudeSettings() else { throw InstallError.cannotReadSettings }
        guard let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              command.contains("tokenmax-statusline")
        else { return }

        settings.removeValue(forKey: "statusLine")
        try writeClaudeSettings(settings)
        try? FileManager.default.removeItem(at: FileLocations.statuslineScript)
        Log.shared.write("statusline shim uninstalled")
    }

    // MARK: - settings.json IO

    /// The user's Claude Code settings, or `nil` when the file exists but does
    /// not parse.
    ///
    /// A *missing* file is an empty dictionary — there is nothing to lose and
    /// creating it is correct. A *malformed* file is `nil`, and callers must
    /// treat that as a stop: the distinction is the whole point, because the two
    /// look identical to a caller that collapses them with `?? [:]`.
    private static func readClaudeSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: FileLocations.claudeSettingsFile) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Keeps the last pre-Tokenmax copy next to the original, so a user whose
    /// settings this mangles has something to restore by hand. Best-effort: a
    /// failed backup is not a reason to refuse an edit the user asked for.
    private static func backupClaudeSettings() {
        let url = FileLocations.claudeSettingsFile
        guard let data = try? Data(contentsOf: url) else { return }
        let backup = url.appendingPathExtension("tokenmax-backup")
        try? data.write(to: backup, options: .atomic)
    }

    private static func writeClaudeSettings(_ settings: [String: Any]) throws {
        backupClaudeSettings()
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            let url = FileLocations.claudeSettingsFile
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.cannotWriteSettings(error.localizedDescription)
        }
    }
}
