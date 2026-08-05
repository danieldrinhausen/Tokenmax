import Foundation
import Testing

@testable import Tokenmax

/// The catalog exists so a newly released model reaches the task editor without
/// a new build of Tokenmax. These pin the two things that would quietly defeat
/// that: a decode that drops unknown fields, and a fallback that empties the
/// picker instead of degrading to the built-in aliases.
@Suite("Model catalog")
struct ModelCatalogTests {
    /// Trimmed from a real `GET /v1/models` response. Keeps one model with the
    /// full effort ladder, one with a shortened one, and one with none — all
    /// three shapes the live endpoint actually returns.
    private static let payload = """
    {
      "data": [
        {
          "type": "model", "id": "claude-opus-5", "display_name": "Claude Opus 5",
          "created_at": "2026-07-24T00:00:00Z",
          "capabilities": {
            "batch": {"supported": true},
            "effort": {
              "supported": true,
              "low": {"supported": true}, "medium": {"supported": true},
              "high": {"supported": true}, "xhigh": {"supported": true},
              "max": {"supported": true}
            }
          }
        },
        {
          "type": "model", "id": "claude-opus-4-5-20251101", "display_name": "Claude Opus 4.5",
          "created_at": "2025-11-24T00:00:00Z",
          "capabilities": {
            "effort": {
              "supported": true,
              "low": {"supported": true}, "medium": {"supported": true}, "high": {"supported": true}
            }
          }
        },
        {
          "type": "model", "id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5",
          "created_at": "2025-10-15T00:00:00Z",
          "capabilities": {"effort": {"supported": false}}
        }
      ],
      "has_more": false, "first_id": "claude-opus-5", "last_id": "claude-haiku-4-5-20251001"
    }
    """

    private func decoded() throws -> [CatalogModel] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let data = try #require(Self.payload.data(using: .utf8))
        return try decoder.decode(ModelsResponse.self, from: data).data.map {
            CatalogModel(
                id: $0.id,
                displayName: $0.displayName ?? $0.id,
                createdAt: $0.createdAt,
                effortLevels: $0.capabilities?.effort?.supportedLevels ?? []
            )
        }
    }

    @Test("The live response shape decodes, ignoring capabilities we do not model")
    func decodesLiveShape() throws {
        let models = try decoded()

        #expect(models.count == 3)
        #expect(models[0].id == "claude-opus-5")
        #expect(models[0].displayName == "Claude Opus 5")
        #expect(models[0].effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(models[1].effortLevels == ["low", "medium", "high"])
        // `supported: false` and no levels means no effort control at all —
        // distinct from "we could not tell".
        #expect(models[2].effortLevels.isEmpty)
    }

    @Test("Effort levels are ordered low to max, not by JSON key order")
    func effortLevelsAreOrdered() throws {
        let levels = try decoded()[0].effortLevels
        #expect(levels == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test("A model maps to its alias family")
    func familyMapping() throws {
        let models = try decoded()
        #expect(models[0].family == "opus")
        #expect(models[2].family == "haiku")
        #expect(CatalogModel(id: "some-future-model", displayName: "X").family == nil)
    }

    /// An alias resolves to the *newest* model of its family, which is what the
    /// CLI does with `--model opus`.
    @Test("An alias resolves to the newest model of its family")
    func aliasResolvesToNewest() throws {
        let catalog = ModelCatalog(models: try decoded(), fetchedAt: Date())
        #expect(catalog.newest(of: "opus")?.id == "claude-opus-5")
        #expect(catalog.newest(of: "haiku")?.id == "claude-haiku-4-5-20251001")
        #expect(catalog.newest(of: "sonnet") == nil)
    }

    @Test("Effort levels resolve for an alias, a pinned id, and an unknown model")
    func effortLevelResolution() throws {
        let catalog = ModelCatalog(models: try decoded(), fetchedAt: Date())

        // Alias → newest of that family.
        #expect(catalog.effortLevels(for: "opus") == ["low", "medium", "high", "xhigh", "max"])
        // Pinned id → that exact model, not its family's newest.
        #expect(catalog.effortLevels(for: "claude-opus-4-5-20251101") == ["low", "medium", "high"])
        // A model with no effort control offers none.
        #expect(catalog.effortLevels(for: "claude-haiku-4-5-20251001").isEmpty)
        // Unknown → the built-in list, because a stale catalog is a worse reason
        // to withhold a grade than the CLI rejecting one.
        #expect(catalog.effortLevels(for: "totally-unknown") == TaskExecutionPolicy.effortOptions)
    }

    /// The catalog is a convenience, never a gate: with nothing fetched the
    /// editor must still offer the built-in aliases.
    @Test("An empty catalog falls back to the built-in aliases")
    func emptyCatalogFallsBack() {
        let empty = ModelCatalog()
        #expect(empty.isEmpty)
        #expect(empty.effortLevels(for: "opus") == TaskExecutionPolicy.effortOptions)
    }

    @Test("A cached catalog survives a round trip")
    func catalogRoundTrips() throws {
        let catalog = ModelCatalog(models: try decoded(), fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONStore.makeEncoder().encode(catalog)
        let restored = try JSONStore.makeDecoder().decode(ModelCatalog.self, from: data)

        #expect(restored == catalog)
        #expect(restored.models.count == 3)
    }

    /// A corrupt or half-written cache must cost the catalog, not the launch.
    @Test("A malformed cached catalog degrades to empty rather than throwing")
    func malformedCacheDegrades() throws {
        let data = try #require("{\"models\": \"not-an-array\"}".data(using: .utf8))
        let restored = try JSONStore.makeDecoder().decode(ModelCatalog.self, from: data)
        #expect(restored.isEmpty)
    }

    /// A level Anthropic adds after this build ships has to survive the decode,
    /// otherwise fetching the list buys nothing for effort.
    @Test("An unrecognised effort level is kept, after the known ones")
    func unknownEffortLevelSurvives() throws {
        let json = """
        {"data": [{"id": "claude-future-1", "display_name": "Future",
          "capabilities": {"effort": {"supported": true,
            "low": {"supported": true}, "ultra": {"supported": true},
            "off": {"supported": false}}}}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let data = try #require(json.data(using: .utf8))
        let levels = try decoder.decode(ModelsResponse.self, from: data).data[0]
            .capabilities?.effort?.supportedLevels

        #expect(levels == ["low", "ultra"])
    }
}
