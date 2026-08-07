import Combine
import Foundation

/// Owns the Codex model catalog: the disk cache, the refresh cadence, and the
/// fallback when there is nothing to show.
///
/// The same contract as `ModelCatalogStore`: the catalog is a convenience,
/// never a gate. Every failure path leaves the task editor fully usable — the
/// model field still accepts a hand-typed id — because a missing CLI must not
/// stop someone editing a task.
@MainActor
final class CodexModelCatalogStore: ObservableObject {
    @Published private(set) var catalog: CodexModelCatalog
    @Published private(set) var isRefreshing = false
    /// Surfaced in Settings so a persistent failure is visible rather than just
    /// looking like an oddly short list.
    @Published private(set) var lastError: String?

    private let client: CodexAppServerClient
    private let cacheURL: URL
    private let isInstalled: @Sendable () -> Bool

    /// Refetched at most daily, matching the Claude catalog. Each refresh spawns
    /// an App Server process, so the cadence is about not doing that repeatedly
    /// rather than about a network cost.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        cacheURL: URL = FileLocations.codexModelCatalogFile,
        isInstalled: @escaping @Sendable () -> Bool = { CodexCLIClient.isInstalled }
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.isInstalled = isInstalled
        catalog = JSONStore.load(CodexModelCatalog.self, from: cacheURL) ?? CodexModelCatalog()
    }

    /// The ids offered in the picker, with the model Codex would pick itself
    /// first. Codex returns them in its own preferred order, which is kept.
    var models: [CodexCatalogModel] {
        catalog.models
    }

    func reasoningEfforts(for model: String?) -> [String] {
        catalog.reasoningEfforts(for: model)
    }

    /// What an empty selection resolves to, for the editor's "Codex default →
    /// GPT-5.6-Sol" hint. nil when the catalog cannot say.
    var defaultModelName: String? {
        catalog.defaultModel?.displayName
    }

    func displayName(for model: String?) -> String? {
        catalog.displayName(for: model)
    }

    private var isStale: Bool {
        Date().timeIntervalSince(catalog.fetchedAt) > Self.refreshInterval
    }

    /// Called when a screen that shows the model list appears — deliberately
    /// *not* at launch, for the same reason as the Claude catalog: spawning a
    /// process for a list nobody is looking at buys nothing.
    func refreshIfStale() {
        guard isStale, isInstalled() else { return }
        Task { await refresh() }
    }

    /// `force` is the Settings button: it bypasses the staleness check.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        guard isInstalled() else {
            lastError = CodexAppServerClient.ClientError.notInstalled.errorDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await client.readModels()
            // An empty list is a wrong answer, not a new one. Keeping the last
            // good catalog beats emptying the picker on a strange response.
            guard !fetched.isEmpty else {
                lastError = "Codex reported no models."
                Log.shared.write("codex models: empty response, keeping cached catalog")
                return
            }
            catalog = CodexModelCatalog(models: fetched, fetchedAt: Date())
            lastError = nil
            JSONStore.save(catalog, to: cacheURL)
        } catch {
            lastError = error.localizedDescription
            Log.shared.write("codex models: failed: \(error.localizedDescription)")
        }
    }
}
