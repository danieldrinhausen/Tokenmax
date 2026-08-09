import Combine
import Foundation

/// Owns the model catalog: the disk cache, the refresh cadence, and the
/// fallback when there is nothing to show.
///
/// The catalog is a convenience, never a gate. Every failure path leaves the
/// task editor fully usable — with the built-in aliases if nothing else — because
/// a network problem must not stop someone editing a task.
@MainActor
final class ModelCatalogStore: ObservableObject {
    @Published private(set) var catalog: ModelCatalog
    @Published private(set) var isRefreshing = false
    /// Surfaced in Settings so a persistent failure is visible rather than just
    /// looking like an oddly short list.
    @Published private(set) var lastError: String?

    private let client: ClaudeModelCatalogClient
    private let cacheURL: URL
    private let loadCredentials: @Sendable () throws -> ClaudeKeychain.Credentials
    private let cliVersion: @Sendable () -> String

    /// Refetched at most daily in normal running. The client enforces its own
    /// six-hour floor underneath this.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    init(
        client: ClaudeModelCatalogClient = ClaudeModelCatalogClient(),
        cacheURL: URL = FileLocations.modelCatalogFile,
        loadCredentials: @escaping @Sendable () throws -> ClaudeKeychain.Credentials = {
            try ClaudeKeychain.readCredentials()
        },
        cliVersion: @escaping @Sendable () -> String = { ClaudeCLIClient.version() }
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.loadCredentials = loadCredentials
        self.cliVersion = cliVersion
        catalog = JSONStore.load(ModelCatalog.self, from: cacheURL) ?? ModelCatalog()
    }

    /// The ids offered in the picker below the aliases, newest first.
    var models: [CatalogModel] {
        catalog.models.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    /// The aliases to offer above the pinned ids.
    ///
    /// Derived from the catalog rather than hardcoded, so a brand-new family
    /// gains its alias automatically — which is the entire point of fetching
    /// this. Falls back to the built-in list when the catalog is empty.
    var aliases: [String] {
        let fromCatalog = catalog.models.compactMap(\.family)
        guard !fromCatalog.isEmpty else { return TaskExecutionPolicy.modelOptions }
        // Ordered cheapest-to-strongest where known, then anything new, so the
        // list does not reshuffle every time Anthropic changes its ordering.
        let known = ["haiku", "sonnet", "opus", "fable"]
        let unique = Set(fromCatalog)
        return known.filter(unique.contains) + unique.subtracting(known).sorted()
    }

    func effortLevels(for model: String) -> [String] {
        catalog.effortLevels(for: model)
    }

    /// What an alias resolves to right now, for the editor's "Opus → Claude
    /// Opus 5" hint. nil when the catalog cannot say.
    func resolvedName(for model: String) -> String? {
        if let exact = catalog.models.first(where: { $0.id == model }) { return exact.displayName }
        return catalog.newest(of: model.lowercased())?.displayName
    }

    private var isStale: Bool {
        Date().timeIntervalSince(catalog.fetchedAt) > Self.refreshInterval
    }

    /// Called when a screen that shows the model list appears — deliberately
    /// *not* at launch.
    ///
    /// Fetching at launch would mean network traffic at the worst moment for a
    /// list that changes a few times a year and is only ever read in the task
    /// editor and Settings. Refreshing where it is used costs nothing on a cold
    /// start and still guarantees the list is current whenever anyone actually
    /// looks at it.
    ///
    /// It used to also mean a *second keychain read* on top of the usage one,
    /// and so a second consent dialog. It no longer does: both readers share
    /// `ClaudeCredentialCache`, and whichever gets there first pays for both.
    ///
    /// Only reaches the network when the cache is older than a day, so opening
    /// the editor repeatedly does not repeatedly fetch.
    func refreshIfStale() {
        guard isStale else { return }
        Task { await refresh() }
    }

    /// `force` is the Settings button: it bypasses both the staleness check here
    /// and the request floor in the client.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let credentials = try loadCredentials()
            let fetched = try await client.fetch(
                accessToken: credentials.accessToken,
                cliVersion: cliVersion(),
                force: force
            )
            // An empty list is a wrong answer, not a new one. Keeping the last
            // good catalog beats emptying the picker on a strange response.
            guard !fetched.isEmpty else {
                lastError = "Anthropic returned no models."
                Log.shared.write("models: empty response, keeping cached catalog")
                return
            }
            catalog = fetched
            lastError = nil
            JSONStore.save(fetched, to: cacheURL)
        } catch UsageClientError.rateLimited where !force {
            // The floor doing its job during an automatic refresh is not
            // something to report.
            Log.shared.write("models: skipped, inside request floor")
        } catch {
            lastError = error.localizedDescription
            Log.shared.write("models: failed: \(error.localizedDescription)")
        }
    }
}
