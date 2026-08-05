import Foundation

enum CodexSandbox: String, Codable, Sendable, CaseIterable, Identifiable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .readOnly: "Read-only"
        case .workspaceWrite: "Workspace write"
        }
    }

    var summary: String {
        switch self {
        case .readOnly: "Codex can inspect the project but cannot modify files."
        case .workspaceWrite: "Codex may modify files inside the working directory."
        }
    }
}

/// Codex intentionally has a distinct policy from Claude.  Its documented
/// execution boundary is a sandbox, not a per-tool allowlist, and the CLI has
/// no Tokenmax-enforceable per-run USD cap.
struct CodexExecutionPolicy: Codable, Sendable, Equatable {
    var maximumRuntimeMinutes: Int = 15
    /// nil means use the model chosen in the user's Codex configuration.
    var model: String?
    var sandbox: CodexSandbox = .workspaceWrite

    /// Applied as `-c model_reasoning_effort=<value>`, the same key Codex reads
    /// from `~/.codex/config.toml`. nil leaves the override off, so the user's
    /// own configured effort stands.
    var reasoningEffort: String?

    static let runtimeOptions = TaskExecutionPolicy.runtimeOptions

    /// Codex's own levels, which are not Claude's — it has `minimal` and no
    /// `xhigh`/`max`. The value is passed through verbatim as a TOML string, so
    /// a level Codex adds later still works without a rebuild.
    static let reasoningEffortOptions = ["minimal", "low", "medium", "high"]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodexExecutionPolicy()
        maximumRuntimeMinutes = try container.decodeIfPresent(Int.self, forKey: .maximumRuntimeMinutes)
            ?? d.maximumRuntimeMinutes
        model = try container.decodeIfPresent(String.self, forKey: .model)
        sandbox = (try? container.decodeIfPresent(CodexSandbox.self, forKey: .sandbox)) ?? d.sandbox
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }

    var modelDisplayName: String { model?.isEmpty == false ? model! : "Codex default" }
}
