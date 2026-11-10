import Foundation

/// Atomic Codable persistence. Writes go to a sibling temp file and are swapped
/// in with `replaceItem`, so a crash mid-write can never leave a half-written
/// JSON file behind.
enum JSONStore {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            Log.shared.write("JSONStore decode failed for \(url.lastPathComponent): \(error)")
            // The caller falls back to defaults and the next save writes over
            // this path. For settings, tasks and the spend records that would
            // turn one unreadable value into the permanent loss of the file, so
            // it is moved aside first. An empty file has nothing to preserve.
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                quarantine(url)
            }
            return nil
        }
    }

    /// How many `<name>.corrupt-<stamp>.json` copies to keep per file. A file
    /// that keeps failing must not fill the disk, and the oldest copy is the
    /// least likely to be the one anyone wants.
    static let corruptCopiesKept = 3

    /// Renames an undecodable file to `<name>.corrupt-<UTC stamp>.json` beside
    /// it and prunes older copies. Returns where it went, nil if the move failed.
    @discardableResult
    static func quarantine(_ url: URL, now: Date = Date()) -> URL? {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: now)

        var target = directory.appendingPathComponent("\(base).corrupt-\(stamp).json")
        var suffix = 1
        while manager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }

        do {
            try manager.moveItem(at: url, to: target)
            Log.shared.write("JSONStore: moved unreadable \(url.lastPathComponent) to \(target.lastPathComponent)")
        } catch {
            Log.shared.write("JSONStore: could not set aside \(url.lastPathComponent): \(error)")
            return nil
        }

        // The stamp sorts chronologically, so name order is age order.
        let siblings = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("\(base).corrupt-") && $0.hasSuffix(".json") }
            .sorted()
        for stale in siblings.dropLast(corruptCopiesKept) {
            try? manager.removeItem(at: directory.appendingPathComponent(stale))
        }
        return target
    }

    @discardableResult
    static func save(_ value: some Encodable, to url: URL) -> Bool {
        var temp: URL?
        do {
            let data = try makeEncoder().encode(value)
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            temp = destination
            try data.write(to: destination, options: .atomic)

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: destination)
            } else {
                try FileManager.default.moveItem(at: destination, to: url)
            }
            return true
        } catch {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            Log.shared.write("JSONStore save failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }
}

/// Minimal append-only file log. Used for the things that are impossible to
/// debug after the fact otherwise: outbound request timing and scheduling decisions.
final class Log: @unchecked Sendable {
    static let shared = Log()

    /// Rotate past this, keeping one previous file. The log is append-only and
    /// the app runs all day, so without a ceiling it grows for as long as
    /// Tokenmax is installed — and it records queue task text and working
    /// directory paths, which is not something to accumulate indefinitely.
    /// Two files at this size still cover weeks of ordinary use.
    static let maximumBytes = 1_000_000

    private let queue = DispatchQueue(label: "com.tokenmax.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            let url = FileLocations.logFile
            self.rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Moves the current log aside once it is too big, keeping exactly one
    /// previous generation. Called on the same serial queue as the write, so it
    /// cannot interleave with one.
    ///
    /// Renaming beats truncating: a reader holding the old file keeps a
    /// consistent view, and the most recent history survives the rotation
    /// instead of being thrown away at the moment it is usually wanted.
    private func rotateIfNeeded(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size > Self.maximumBytes else { return }

        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
