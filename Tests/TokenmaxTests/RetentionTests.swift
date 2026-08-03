import Foundation
import Testing

@testable import Tokenmax

/// Everything Tokenmax leaves on disk that nothing else bounds.
///
/// Both of these hold user content — run transcripts carry prompt text and CLI
/// output, the app log carries task text and working directory paths — so
/// "it only grows slowly" is not good enough on its own.
@Suite("On-disk retention", .serialized)
struct RetentionTests {
    private func requireScratch() throws {
        try #require(
            FileLocations.supportDirectory.path.contains("tokenmax-tests"),
            "refusing to run against \(FileLocations.supportDirectory.path)"
        )
    }

    // MARK: - Run logs

    @discardableResult
    private func writeRunLog(_ id: UUID) throws -> URL {
        let url = FileLocations.runLogFile(runID: id)
        try "transcript for \(id)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func clearRunLogs() {
        let directory = FileLocations.runLogsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    @Test("Keeps the transcripts still referenced and deletes the rest")
    func prunesOrphanedRunLogs() throws {
        try requireScratch()
        clearRunLogs()
        defer { clearRunLogs() }

        let live = UUID(), alsoLive = UUID(), dropped = UUID()
        try writeRunLog(live)
        try writeRunLog(alsoLive)
        try writeRunLog(dropped)

        let removed = FileLocations.pruneRunLogs(keeping: [live, alsoLive])

        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: FileLocations.runLogFile(runID: live).path))
        #expect(FileManager.default.fileExists(atPath: FileLocations.runLogFile(runID: alsoLive).path))
        #expect(!FileManager.default.fileExists(atPath: FileLocations.runLogFile(runID: dropped).path))
    }

    /// The directory is inside the app's own support folder, but deleting
    /// whatever happens to be sitting there is still not this function's job.
    @Test("Leaves files that are not named after a run alone")
    func ignoresForeignFiles() throws {
        try requireScratch()
        clearRunLogs()
        defer { clearRunLogs() }

        let foreign = FileLocations.runLogsDirectory.appendingPathComponent("notes.log")
        let notALog = FileLocations.runLogsDirectory.appendingPathComponent("README.txt")
        try "keep me".write(to: foreign, atomically: true, encoding: .utf8)
        try "keep me".write(to: notALog, atomically: true, encoding: .utf8)

        #expect(FileLocations.pruneRunLogs(keeping: []) == 0)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: notALog.path))
    }

    @Test("An empty run list clears every transcript")
    func prunesEverythingWhenNothingIsLive() throws {
        try requireScratch()
        clearRunLogs()
        defer { clearRunLogs() }

        for _ in 0 ..< 3 { try writeRunLog(UUID()) }
        #expect(FileLocations.pruneRunLogs(keeping: []) == 3)
    }

    // MARK: - The app log

    @Test("The log rotates once it passes its ceiling, keeping one generation")
    func rotatesTheAppLog() throws {
        try requireScratch()

        let url = FileLocations.logFile
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previous)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previous)
        }

        // Just over the ceiling, with a marker to prove the old contents were
        // carried aside rather than discarded.
        let oversized = "MARKER\n" + String(repeating: "x", count: Log.maximumBytes)
        try oversized.write(to: url, atomically: true, encoding: .utf8)

        Log.shared.write("after rotation")
        // The write is queued; drain it.
        confirmEventually { FileManager.default.fileExists(atPath: previous.path) }

        #expect(try String(contentsOf: previous, encoding: .utf8).hasPrefix("MARKER"))

        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("after rotation"))
        #expect(!current.contains("MARKER"))
        #expect(current.utf8.count < Log.maximumBytes)
    }

    @Test("A log under the ceiling is appended to, not rotated")
    func leavesASmallLogAlone() throws {
        try requireScratch()

        let url = FileLocations.logFile
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previous)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previous)
        }

        try "small\n".write(to: url, atomically: true, encoding: .utf8)
        Log.shared.write("appended")
        confirmEventually {
            (try? String(contentsOf: url, encoding: .utf8))?.contains("appended") == true
        }

        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("small"))
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    /// `Log.write` hands off to a serial queue, so the file changes shortly
    /// after the call rather than during it.
    private func confirmEventually(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(20_000)
        }
        #expect(condition(), "condition never became true within \(timeout)s")
    }
}
