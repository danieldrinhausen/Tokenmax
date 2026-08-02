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

    static func save(_ value: some Encodable, to url: URL) {
        do {
            let data = try makeEncoder().encode(value)
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: temp, options: .atomic)

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            Log.shared.write("JSONStore save failed for \(url.lastPathComponent): \(error)")
        }
    }
}

/// Minimal append-only file log. Used for the things that are impossible to
/// debug after the fact otherwise: outbound request timing and scheduling decisions.
final class Log: @unchecked Sendable {
    static let shared = Log()

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
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
