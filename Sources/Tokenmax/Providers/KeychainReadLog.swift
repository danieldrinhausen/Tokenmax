import Foundation

/// Formats the log line for a keychain read, so `make logs` can answer "when
/// did a read probably wait on consent, and why" without anyone watching the
/// screen.
///
/// macOS gives no signal that it showed the dialog. What it cannot hide is
/// time: an ACL-served read answers in single-digit milliseconds, while a read
/// that raised the dialog blocks until a human answers it. Elapsed time is
/// therefore useful evidence, not proof: keychain contention or system load can
/// also make a read slow, so the log must describe the inference honestly.
///
/// Pure formatting only — the clock, the keychain call and the log file all
/// belong to `ClaudeKeychain`. That is what makes the classification testable.
enum KeychainReadLog {
    /// At or above this, the read blocked on a human. Below it, no dialog can
    /// have been answered — and a dialog nobody answered would still be
    /// blocking, so a returned read under the threshold was served silently.
    static let dialogThreshold: TimeInterval = 0.5

    enum Outcome: Equatable, Sendable {
        case ok
        case notFound
        case denied
        case interactionNotAllowed
        case malformed
        case unexpected(Int32)

        var label: String {
            switch self {
            case .ok: "read ok"
            case .notFound: "item not found"
            case .denied: "read denied"
            case .interactionNotAllowed: "interaction unavailable; no dialog completed"
            case .malformed: "payload malformed"
            case let .unexpected(status): "failed (OSStatus \(status))"
            }
        }
    }

    /// One line per read: what happened, how long it took, whether that
    /// duration suggests a consent dialog, and when Claude Code last modified
    /// the item — the four facts that make a prompt report diagnosable.
    static func line(outcome: Outcome, elapsed: TimeInterval, itemModified: Date?) -> String {
        var text = "keychain: \(outcome.label) in \(String(format: "%.3f", elapsed))s"
        // The locked-keychain status by definition raised nothing, however
        // long macOS took to say so — never claim a dialog for it.
        if elapsed >= dialogThreshold, outcome != .interactionNotAllowed {
            text += " — likely waited on a consent dialog (slow read)"
        } else {
            text += ", silent"
        }
        if let itemModified {
            text += "; item last modified \(itemModified.ISO8601Format())"
        }
        return text
    }
}
