import Foundation

/// One model as Codex reports it over `model/list`, reduced to what the task
/// editor needs.
struct CodexCatalogModel: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// The id passed as `model` on `thread/start`, e.g. `gpt-5.6-sol`.
    var id: String
    /// Codex's own label. Shown rather than a locally-derived name so a model
    /// released later reads correctly without a rebuild.
    var displayName: String
    /// Codex's one-line description of the model, shown under the picker.
    var summary: String?
    /// True for the model Codex would use on its own. The editor labels it, so
    /// "Codex default" is not a mystery.
    var isDefault: Bool = false
    /// The reasoning efforts this model accepts, in Codex's order.
    ///
    /// Per-model rather than global: the levels genuinely differ between them,
    /// and offering a grade a model rejects turns a run into a failed run.
    var reasoningEfforts: [String] = []

    init(
        id: String,
        displayName: String,
        summary: String? = nil,
        isDefault: Bool = false,
        reasoningEfforts: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.isDefault = isDefault
        self.reasoningEfforts = reasoningEfforts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        reasoningEfforts = (try? container.decodeIfPresent([String].self, forKey: .reasoningEfforts)) ?? []
    }
}

/// The fetched Codex model list plus when it was fetched, as cached on disk.
///
/// Persisted for the same reason the Claude catalog is: the picker is populated
/// instantly at launch and keeps working when the CLI is missing or slow.
struct CodexModelCatalog: Codable, Sendable, Equatable {
    var models: [CodexCatalogModel] = []
    var fetchedAt: Date = .distantPast

    init(models: [CodexCatalogModel] = [], fetchedAt: Date = .distantPast) {
        self.models = models
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? container.decodeIfPresent([CodexCatalogModel].self, forKey: .models)) ?? []
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }

    var isEmpty: Bool { models.isEmpty }

    /// The model Codex would pick on its own, which is what an empty selection
    /// in the editor means.
    var defaultModel: CodexCatalogModel? {
        models.first(where: \.isDefault) ?? models.first
    }

    /// The reasoning efforts available for whatever the editor currently holds.
    ///
    /// An empty selection asks about the default model, since that is what will
    /// actually run. An unknown id returns the built-in list rather than none:
    /// the catalog may simply be stale, and refusing to offer a level the model
    /// does support is worse than offering one it will reject loudly.
    func reasoningEfforts(for model: String?) -> [String] {
        guard let model, !model.isEmpty else {
            return defaultModel?.reasoningEfforts ?? CodexExecutionPolicy.reasoningEffortOptions
        }
        if let exact = models.first(where: { $0.id == model }), !exact.reasoningEfforts.isEmpty {
            return exact.reasoningEfforts
        }
        return CodexExecutionPolicy.reasoningEffortOptions
    }

    func displayName(for model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        return models.first(where: { $0.id == model })?.displayName
    }
}
