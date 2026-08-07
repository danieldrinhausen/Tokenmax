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
            return nil
        }
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
