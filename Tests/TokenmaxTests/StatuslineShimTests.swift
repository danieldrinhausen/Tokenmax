import Foundation
import Testing

@testable import Tokenmax

/// These write to `FileLocations.claudeSettingsFile`, which the test scheme
/// points at a scratch directory via `TOKENMAX_CLAUDE_DIR`. If that override is
/// ever lost, these tests would edit the real Claude Code configuration — so the
/// first thing each one does is refuse to run outside the scratch path.
@Suite("Statusline shim", .serialized)
struct StatuslineShimTests {
    private var settingsFile: URL { FileLocations.claudeSettingsFile }

    private func withScratchSettings(_ contents: String?, _ body: () throws -> Void) throws {
        let path = settingsFile.path
        try #require(
            path.contains("tokenmax-tests"),
            "refusing to run against \(path) — TOKENMAX_CLAUDE_DIR is not set"
        )

        try? FileManager.default.createDirectory(
            at: settingsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: settingsFile)
        try? FileManager.default.removeItem(at: settingsFile.appendingPathExtension("tokenmax-backup"))
        if let contents { try contents.write(to: settingsFile, atomically: true, encoding: .utf8) }

        defer { try? FileManager.default.removeItem(at: settingsFile) }
        try body()
    }

    private func readBack() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsFile)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The one that matters. A settings.json that does not parse must stop the
    /// install, because the alternative is rewriting the file from an empty
    /// dictionary and discarding every permission, hook and MCP server the user
    /// had configured.
    ///
    /// Both fixtures are things that really happen to this file: a write that
    /// got cut off, and the `//` comments people add because so many other tools
    /// accept them. (A trailing comma is *not* one of them — `JSONSerialization`
    /// takes those quite happily, which a first version of this test proved.)
    @Test("Refuses to install over a settings file it cannot parse", arguments: [
        #"{"permissions": {"allow": ["Bash"]}"#,
        "{\n  // my settings\n  \"model\": \"opus\"\n}",
    ])
    func refusesToClobberMalformedSettings(malformed: String) throws {
        try withScratchSettings(malformed) {
            #expect(throws: StatuslineShimInstaller.InstallError.self) {
                try StatuslineShimInstaller.install()
            }
            // Untouched, byte for byte.
            let after = try String(contentsOf: settingsFile, encoding: .utf8)
            #expect(after == malformed)
        }
    }

    @Test("Refuses to uninstall from a settings file it cannot parse")
    func refusesToUninstallFromMalformedSettings() throws {
        try withScratchSettings("not json at all") {
            #expect(throws: StatuslineShimInstaller.InstallError.self) {
                try StatuslineShimInstaller.uninstall()
            }
        }
    }

    @Test("Keeps every other key when installing")
    func preservesExistingSettings() throws {
        let existing = #"""
        {"permissions": {"allow": ["Bash"]}, "env": {"FOO": "bar"}, "model": "opus"}
        """#
        try withScratchSettings(existing) {
            try StatuslineShimInstaller.install()

            let after = try readBack()
            #expect((after["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash"])
            #expect((after["env"] as? [String: Any])?["FOO"] as? String == "bar")
            #expect(after["model"] as? String == "opus")
            #expect(after["statusLine"] != nil)
            #expect(StatuslineShimInstaller.isInstalled)
        }
    }

    @Test("A missing settings file is created rather than refused")
    func createsSettingsWhenAbsent() throws {
        try withScratchSettings(nil) {
            try StatuslineShimInstaller.install()
            #expect(try readBack()["statusLine"] != nil)
        }
    }

    /// An existing statusline is chained, not discarded — and uninstalling puts
    /// the file back to something without a Tokenmax command in it.
    @Test("Wraps an existing statusline, and removes only its own on uninstall")
    func wrapsAndUnwraps() throws {
        let existing = #"""
        {"statusLine": {"type": "command", "command": "/usr/local/bin/mystatus"}}
        """#
        try withScratchSettings(existing) {
            try StatuslineShimInstaller.install()
            #expect(StatuslineShimInstaller.isInstalled)

            let script = try String(contentsOf: FileLocations.statuslineScript, encoding: .utf8)
            #expect(script.contains("/usr/local/bin/mystatus"))

            try StatuslineShimInstaller.uninstall()
            #expect(try readBack()["statusLine"] == nil)
            #expect(!StatuslineShimInstaller.isInstalled)
        }
    }

    @Test("The previous contents are backed up before being replaced")
    func backsUpBeforeWriting() throws {
        let existing = #"{"model": "opus"}"#
        try withScratchSettings(existing) {
            try StatuslineShimInstaller.install()

            let backup = settingsFile.appendingPathExtension("tokenmax-backup")
            #expect(try String(contentsOf: backup, encoding: .utf8) == existing)
            try? FileManager.default.removeItem(at: backup)
        }
    }
}
