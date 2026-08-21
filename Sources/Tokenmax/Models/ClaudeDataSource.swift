import Foundation

/// Where the Claude quota numbers come from.
///
/// This choice exists because of the keychain consent dialog. Reading the
/// OAuth token is the accurate source — pollable any time, exact, and the only
/// one that reports the per-model weeklies, the plan name and the extra-usage
/// flag — but the item belongs to another app, so macOS asks, and asks again
/// every time Claude Code rotates the token past an *Allow*-only grant. The
/// status line is the documented source and needs no permission at all; it
/// just goes quiet whenever Claude Code is not answering.
enum ClaudeDataSource: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Read the OAuth token from the login keychain and poll the usage
    /// endpoint. Works in the background; may raise consent dialogs.
    case keychain
    /// Read only the file the statusline shim writes. Tokenmax never touches
    /// the keychain in this mode — that is the mode's entire promise, which is
    /// why nothing may quietly fall back to a credential read from here.
    case statuslineOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keychain: "macOS Keychain"
        case .statuslineOnly: "Status line only"
        }
    }
}

/// The current data-source choice, readable off the main actor.
///
/// `ClaudeCodeProvider.fetchUsage` runs off the main actor and so cannot read
/// `SettingsStore.settings` directly; this is the one word of settings that
/// has to cross that boundary. `SettingsStore` keeps it current on every save,
/// so a change in Settings takes effect on the very next fetch — no restart,
/// and no stale copy captured at construction time.
final class ClaudeDataSourceFlag: @unchecked Sendable {
    static let shared = ClaudeDataSourceFlag()

    private let lock = NSLock()
    private var value: ClaudeDataSource = .keychain

    var current: ClaudeDataSource {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: ClaudeDataSource) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
