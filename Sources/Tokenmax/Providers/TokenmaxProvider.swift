import Foundation

/// The agent installations Tokenmax can monitor and run.  Raw identifiers are
/// persisted so adding a provider never changes existing queue records.
enum TokenmaxProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var commandName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    static func from(identifier: String) -> TokenmaxProvider? {
        TokenmaxProvider(rawValue: identifier)
    }
}

