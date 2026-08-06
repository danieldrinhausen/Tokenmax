import Combine
import Foundation

/// What the popover header and the About pane render.
enum UpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppVersion, page: URL)
    /// Never `.upToDate`. A check that could not complete says so — being
    /// unable to confirm is not the same as having confirmed.
    case unavailable(String)
}

/// Asks GitHub, once a day, whether there is a newer release than this build.
///
/// Notify only, on purpose: nothing here downloads, installs or replaces
/// anything. Tokenmax is signed but not notarized, so a self-replacing bundle
/// would be the most security-sensitive code in an app whose whole other risk
/// surface is reading quota — and it would have to be written from scratch,
/// since the alternative is the project's first third-party dependency.
///
/// Side effects only. Every rule lives in `UpdateCheck`.
@MainActor
final class UpdateCheckCoordinator: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle
    @Published private(set) var lastCheckedAt: Date?

    /// The reason the most recent *decision* declined, when it did. Separate
    /// from `state` because "checked recently" is not something to show beside
    /// the version — it is only an answer to "why has it not just checked?".
    @Published private(set) var lastSuppression: UpdateCheckSuppression?

    private let client: GitHubReleaseClient
    private let settingsStore: SettingsStore
    private let now: () -> Date

    private var hasStarted = false
    private var timer: Timer?
    private var inFlight = false

    init(
        settingsStore: SettingsStore,
        client: GitHubReleaseClient = GitHubReleaseClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.settingsStore = settingsStore
        self.client = client
        self.now = now
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        Task { await check() }

        // Hourly, but `UpdateCheck.decide` still holds it to once a day. The
        // tick is short so that a Mac woken from sleep after a week does not
        // wait another hour before its first check, and the interval is where
        // the actual frequency lives.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasStarted = false
    }

    /// `force` is the "Check Now" button and nothing else.
    func check(force: Bool = false) async {
        guard !inFlight else { return }

        let decision = UpdateCheck.decide(
            enabled: settingsStore.settings.checkForUpdates,
            lastCheckedAt: lastCheckedAt,
            now: now(),
            force: force
        )

        if case let .skip(reason) = decision {
            lastSuppression = reason
            // The last known answer is left standing. A skipped check has
            // learned nothing, and blanking a pending offer because today's
            // check was not due would hide the very thing it found yesterday.
            return
        }

        lastSuppression = nil
        inFlight = true
        state = .checking
        defer { inFlight = false }

        do {
            let release = try await client.latestRelease()
            lastCheckedAt = now()

            switch UpdateCheck.offer(currentVersion: AppInfo.version, latestTag: release.tag) {
            case let .available(version):
                state = .available(version, page: release.page)
                Log.shared.write("update: \(version) available (running \(AppInfo.version))")
            case let .none(reason):
                state = .upToDate
                lastSuppression = reason
                // Logged even though nothing came of it: "it never offers me
                // updates" and "it never checks" are the same thing from the
                // outside, and only the log can tell them apart.
                Log.shared.write("update: latest is \(release.tag) — \(reason.rawValue)")
            }
        } catch let error as UpdateCheckError {
            // No `lastCheckedAt` on failure, so the next tick retries in an
            // hour rather than a day. Stale data postpones; it never cancels.
            state = .unavailable(error.summary)
            Log.shared.write("update: check failed — \(error.summary)")
        } catch {
            state = .unavailable(error.localizedDescription)
            Log.shared.write("update: check failed — \(error.localizedDescription)")
        }
    }

    /// The offered version, when there is one. Lets a view ask the one question
    /// it has without unwrapping the whole state.
    var availableVersion: AppVersion? {
        if case let .available(version, _) = state { return version }
        return nil
    }

    var releasePage: URL? {
        if case let .available(_, page) = state { return page }
        return nil
    }
}
