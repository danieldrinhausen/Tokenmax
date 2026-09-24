import Foundation

/// The agent installations Tokenmax can monitor and run.  Raw identifiers are
/// persisted so adding a provider never changes existing queue records.
enum TokenmaxProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var commandName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        }
    }

    /// Whether Tokenmax can run queued tasks on it. Cursor is watched, never
    /// driven: its usage can be read, but nothing here knows how to start or
    /// bound a Cursor run. Everything on the spending path filters on this
    /// rather than listing providers, so the next usage-only one cannot be
    /// missed at one of a dozen call sites.
    var runsTasks: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .cursor: false
        }
    }

    /// The provider a window belongs to, from its id prefix (`codex.weekly`).
    static func owning(windowID: String) -> TokenmaxProvider {
        allCases.first { $0 != .claudeCode && windowID.hasPrefix("\($0.windowPrefix).") } ?? .claudeCode
    }

    private var windowPrefix: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        }
    }

    static func from(identifier: String) -> TokenmaxProvider? {
        TokenmaxProvider(rawValue: identifier)
    }
}

