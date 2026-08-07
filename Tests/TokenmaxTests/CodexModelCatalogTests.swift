import Foundation
import Testing

@testable import Tokenmax

@Suite("Codex model catalog")
struct CodexModelCatalogTests {
    /// The shape Codex 0.146 actually sends, captured from a live `model/list`.
    private var liveResponse: [String: Any] {
        [
            "data": [
                [
                    "id": "gpt-5.6-sol",
                    "model": "gpt-5.6-sol",
                    "displayName": "GPT-5.6-Sol",
                    "description": "Best for most work",
                    "hidden": false,
                    "isDefault": true,
                    "defaultReasoningEffort": "high",
                    "supportedReasoningEfforts": [
                        ["reasoningEffort": "low", "description": "Fast responses"],
                        ["reasoningEffort": "medium", "description": "Balanced"],
                        ["reasoningEffort": "high", "description": "Deeper"],
                        ["reasoningEffort": "xhigh", "description": "Deeper still"],
                    ],
                ],
                [
                    "id": "gpt-5.4-mini",
                    "model": "gpt-5.4-mini",
                    "displayName": "GPT-5.4-Mini",
                    "hidden": false,
                    "isDefault": false,
                    "defaultReasoningEffort": "medium",
                    "supportedReasoningEfforts": [["reasoningEffort": "low"]],
                ],
            ]
        ]
    }

    @Test("Decodes the models Codex reports")
    func decodesLiveShape() {
        let models = CodexAppServerClient.decodeModels(liveResponse)
        #expect(models.count == 2)
        #expect(models.first?.id == "gpt-5.6-sol")
        #expect(models.first?.displayName == "GPT-5.6-Sol")
        #expect(models.first?.summary == "Best for most work")
        #expect(models.first?.isDefault == true)
        #expect(models.first?.reasoningEfforts == ["low", "medium", "high", "xhigh"])
    }

    /// Earlier App Server versions sent bare strings. An upgrade in either
    /// direction must not empty the picker.
    @Test("Accepts reasoning efforts sent as bare strings")
    func decodesLegacyEffortShape() {
        let models = CodexAppServerClient.decodeModels([
            "data": [[
                "id": "gpt-5.5",
                "displayName": "GPT-5.5",
                "supportedReasoningEfforts": ["low", "high"],
            ]]
        ])
        #expect(models.first?.reasoningEfforts == ["low", "high"])
    }

    /// Codex marks these as kept out of its own picker. Tokenmax has no better
    /// claim to show them.
    @Test("Drops models Codex hides from its own picker")
    func dropsHiddenModels() {
        let models = CodexAppServerClient.decodeModels([
            "data": [
                ["id": "visible", "displayName": "Visible", "hidden": false],
                ["id": "internal-only", "displayName": "Internal", "hidden": true],
            ]
        ])
        #expect(models.map(\.id) == ["visible"])
    }

    @Test("A response with no models decodes to no models rather than failing")
    func toleratesAnEmptyOrOddResponse() {
        #expect(CodexAppServerClient.decodeModels([:]).isEmpty)
        #expect(CodexAppServerClient.decodeModels(["data": [["displayName": "No id"]]]).isEmpty)
    }

    /// An empty selection means "whatever Codex would pick", so the efforts
    /// offered have to be that model's.
    @Test("An empty selection asks the default model for its efforts")
    func emptySelectionUsesTheDefaultModel() {
        let catalog = CodexModelCatalog(models: CodexAppServerClient.decodeModels(liveResponse))
        #expect(catalog.reasoningEfforts(for: nil) == ["low", "medium", "high", "xhigh"])
        #expect(catalog.reasoningEfforts(for: "") == ["low", "medium", "high", "xhigh"])
        #expect(catalog.defaultModel?.id == "gpt-5.6-sol")
    }

    @Test("A known model reports its own efforts")
    func knownModelReportsItsOwnEfforts() {
        let catalog = CodexModelCatalog(models: CodexAppServerClient.decodeModels(liveResponse))
        #expect(catalog.reasoningEfforts(for: "gpt-5.4-mini") == ["low"])
    }

    /// A stale catalog must not narrow the picker to nothing: offering a level
    /// the model rejects loudly beats hiding one it supports.
    @Test("An unknown model falls back to the built-in levels")
    func unknownModelFallsBackToTheBuiltInLevels() {
        let catalog = CodexModelCatalog(models: CodexAppServerClient.decodeModels(liveResponse))
        #expect(
            catalog.reasoningEfforts(for: "gpt-6-not-yet-released")
                == CodexExecutionPolicy.reasoningEffortOptions
        )
        #expect(CodexModelCatalog().reasoningEfforts(for: nil) == CodexExecutionPolicy.reasoningEffortOptions)
    }

    /// The cache is written by one version and read by the next.
    @Test("A cached catalog survives a round trip, and a truncated one decodes")
    func cacheRoundTripsAndToleratesMissingFields() throws {
        let original = CodexModelCatalog(
            models: CodexAppServerClient.decodeModels(liveResponse),
            fetchedAt: Date(timeIntervalSince1970: 1_785_500_000)
        )
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CodexModelCatalog.self, from: encoded) == original)

        let sparse = Data(#"{"models":[{"id":"gpt-5.5"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexModelCatalog.self, from: sparse)
        #expect(decoded.models.first?.displayName == "gpt-5.5")
        #expect(decoded.models.first?.reasoningEfforts.isEmpty == true)
        #expect(decoded.fetchedAt == .distantPast)
    }
}
