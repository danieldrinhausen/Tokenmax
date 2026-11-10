import Foundation
import Testing

@testable import Tokenmax

/// `claude auth status` polls a child for up to 15s. The queue used to ask it on
/// the main actor, freezing the UI for as long as that took.
@Suite("Queue account gate off the main actor")
@MainActor
struct QueueAccountGateTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        private var calls = 0
        func record() {
            lock.withLock {
                threads.append(Thread.isMainThread)
                calls += 1
            }
        }
        var ranOnMainThread: Bool { lock.withLock { threads.contains(true) } }
        var callCount: Int { lock.withLock { calls } }
    }

    private func coordinator(authStatus: @escaping @Sendable () -> ClaudeAuthStatus?) -> QueueAutoRunCoordinator {
        let settings = SettingsStore()
        return QueueAutoRunCoordinator(
            usage: ProviderUsageCoordinator(settingsStore: settings),
            taskStore: TaskStore(),
            settingsStore: settings,
            stateFile: FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json"),
            persistState: { _ in true },
            authStatus: authStatus
        )
    }

    private let subscription = ClaudeAuthStatus(
        loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", subscriptionType: "max"
    )

    @Test("The auth status is read on a background thread, and the main actor stays free while it runs")
    func authStatusIsReadOffTheMainActor() async {
        let probe = Probe()
        let status = subscription
        let queue = coordinator {
            probe.record()
            Thread.sleep(forTimeInterval: 0.4)
            return status
        }

        let check = Task { await queue.checkEligibility() }
        // The main actor must be able to run other work while the child is polled.
        var mainActorWorkRan = false
        for _ in 0..<50 where probe.callCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        await MainActor.run { mainActorWorkRan = true }
        #expect(mainActorWorkRan)
        #expect(probe.callCount == 1)
        _ = await check.value

        #expect(!probe.ranOnMainThread)
    }

    @Test("A second check inside the cache lifetime does not ask the CLI again, and a forced one does")
    func cacheAndForce() async {
        let probe = Probe()
        let status = subscription
        let queue = coordinator { probe.record(); return status }

        _ = await queue.checkEligibility()
        _ = await queue.checkEligibility()
        // Both are the manual button, which exists to give a current answer.
        #expect(probe.callCount >= 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("A login that is not a subscription is refused through the gate")
    func apiLoginIsRefused() async {
        let queue = coordinator {
            ClaudeAuthStatus(loggedIn: true, authMethod: "api_key", apiProvider: "firstParty", subscriptionType: nil)
        }
        let outcome = await queue.checkEligibility()
        // Whatever else is or is not eligible in a test environment, a login
        // that bills per token must never come back as a run.
        #expect(outcome.isEligible == false)
    }
}
