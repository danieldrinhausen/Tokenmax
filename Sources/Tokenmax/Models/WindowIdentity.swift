import Foundation

/// The identity of a usage window, derived from its reset time.
///
/// Reset timestamps jitter by a second or so between fetches, so the time is
/// rounded to a 300s bucket before it becomes part of an id. Rounding alone has
/// an edge, though: two readings of the same instant that straddle a bucket
/// boundary round to *adjacent* buckets and get different ids. For the opener
/// and the queue that is a second spend on a window already used, so `isSame`
/// treats ids no more than one bucket apart as the same window. No two real
/// windows reset that close together, so this only ever suppresses.
enum WindowIdentity {
    /// Built once: this runs on a one-second tick, and an
    /// `ISO8601DateFormatter` is expensive to create. The formatter is
    /// documented as thread-safe and never mutated after this initializer.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Length of `2026-08-31T12:00:00Z`.
    private static let timestampLength = 20

    static func bucketed(_ date: Date) -> Date {
        let bucket = NotificationScheduler.identifierBucket
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucket).rounded() * bucket)
    }

    static func timestamp(_ date: Date) -> String {
        formatter.string(from: bucketed(date))
    }

    /// Ids are `<prefix><timestamp>`; the prefix says which feature and
    /// provider, and the timestamp is always the last 20 characters.
    static func isSame(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count > timestampLength, b.count > timestampLength,
              a.dropLast(timestampLength) == b.dropLast(timestampLength),
              let first = formatter.date(from: String(a.suffix(timestampLength))),
              let second = formatter.date(from: String(b.suffix(timestampLength)))
        else { return false }
        return abs(first.timeIntervalSince(second)) <= NotificationScheduler.identifierBucket
    }
}
