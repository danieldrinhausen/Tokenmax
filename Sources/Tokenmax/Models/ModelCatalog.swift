import Foundation

/// One model as Anthropic reports it, reduced to what the task editor needs.
struct CatalogModel: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// The full id passed to `--model`, e.g. `claude-opus-5`.
    var id: String
    /// Anthropic's own label, e.g. "Claude Opus 5". Shown rather than a
    /// locally-derived name so a new family reads correctly without a rebuild.
    var displayName: String
    var createdAt: Date?
    /// The `--effort` levels this model accepts, in Anthropic's order. Empty
    /// means the model has no effort control at all — several 4.5-era models
    /// report exactly that, and offering them a thinking grade would be a lie.
    var effortLevels: [String] = []

    /// The alias family this model belongs to (`opus`, `sonnet`, …), or nil.
    /// Used to answer "what does `--model opus` actually resolve to" so the
    /// effort picker can offer that model's levels.
    var family: String? {
        let lowered = id.lowercased()
        return ["opus", "sonnet", "haiku", "fable"].first { lowered.contains($0) }
    }
}

/// The fetched model list plus when it was fetched, as cached on disk.
///
/// Persisted so the picker is populated instantly at launch and keeps working
/// offline — the same last-known-good approach `UsageSnapshot` takes.
struct ModelCatalog: Codable, Sendable, Equatable {
    var models: [CatalogModel] = []
    var fetchedAt: Date = .distantPast

    init(models: [CatalogModel] = [], fetchedAt: Date = .distantPast) {
        self.models = models
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? container.decodeIfPresent([CatalogModel].self, forKey: .models)) ?? []
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }

    var isEmpty: Bool { models.isEmpty }

    /// The newest model of a family, which is what its alias resolves to.
    ///
    /// Anthropic returns the list newest-first, but that is not promised, so
    /// this sorts rather than taking the first match.
    func newest(of family: String) -> CatalogModel? {
        models
            .filter { $0.family == family }
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// The effort levels available for whatever the editor currently holds —
    /// an alias, a catalogued id, or something typed by hand.
    ///
    /// An unknown model returns the full built-in list rather than none: the
    /// catalog may simply be stale, and refusing to offer a grade the model
    /// does support is worse than offering one it will reject loudly.
    func effortLevels(for model: String) -> [String] {
        if let exact = models.first(where: { $0.id == model }) {
            return exact.effortLevels
        }
        if let viaAlias = newest(of: model.lowercased()) {
            return viaAlias.effortLevels
        }
        if let family = CatalogModel(id: model, displayName: model).family,
           let newest = newest(of: family) {
            return newest.effortLevels
        }
        return TaskExecutionPolicy.effortOptions
    }
}

/// The `GET /v1/models` payload. Only the fields Tokenmax uses are decoded;
/// everything else in the response is ignored rather than modelled, so a new
/// capability appearing cannot break the decode.
struct ModelsResponse: Decodable, Sendable {
    struct Model: Decodable, Sendable {
        var id: String
        var displayName: String?
        var createdAt: Date?
        var capabilities: Capabilities?

        struct Capabilities: Decodable, Sendable {
            var effort: Effort?
        }

        /// `effort` is an object whose keys are level names, each `{supported: bool}`,
        /// alongside its own `supported` flag. Decoded dynamically so a level
        /// Anthropic adds later is picked up without a rebuild — which is the
        /// whole point of fetching this at all.
        struct Effort: Decodable, Sendable {
            var supportedLevels: [String] = []

            private struct Key: CodingKey {
                var stringValue: String
                var intValue: Int?
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
            }

            private struct Flag: Decodable { var supported: Bool? }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                // Ordered by the known grades first so the picker reads
                // low → max rather than in whatever order JSON arrived.
                var found: [String] = []
                for key in container.allKeys where key.stringValue != "supported" {
                    if let flag = try? container.decode(Flag.self, forKey: key), flag.supported == true {
                        found.append(key.stringValue)
                    }
                }
                let known = ["low", "medium", "high", "xhigh", "max"]
                supportedLevels = known.filter(found.contains) + found.filter { !known.contains($0) }
            }
        }
    }

    var data: [Model]
    var hasMore: Bool?
}
