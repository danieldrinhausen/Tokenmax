import Foundation
import Testing

@testable import Tokenmax

private final class CLICounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var present = true
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    func hit() { lock.lock(); count += 1; lock.unlock() }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    var installed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return present }
        set { lock.lock(); present = newValue; lock.unlock() }
    }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return clock }
        set { lock.lock(); clock = newValue; lock.unlock() }
    }
}

@Suite("CLI location and version are memoised")
struct ClaudeCLICacheTests {
    private let path = URL(fileURLWithPath: "/tmp/claude-test-cli")

    private func makeCache(
        _ probe: CLICounter,
        searches: CLICounter,
        version: @escaping @Sendable () -> String? = { "2.1.0" }
    ) -> ClaudeCLICache {
        let path = path
        return ClaudeCLICache(
            resolveLocation: { searches.hit(); return probe.installed ? path : nil },
            resolveVersion: { _ in probe.hit(); return version() },
            isExecutable: { _ in probe.installed },
            now: { probe.now }
        )
    }

    @Test("A found CLI is searched for once, not on every call")
    func locatesOnce() {
        let probe = CLICounter(), searches = CLICounter()
        let cache = makeCache(probe, searches: searches)
        for _ in 0 ..< 5 { #expect(cache.locate() == path) }
        #expect(searches.hits == 1)
    }

    @Test("A cached path that stopped being executable is searched for again")
    func invalidatesWhenBinaryDisappears() {
        let probe = CLICounter(), searches = CLICounter()
        let cache = makeCache(probe, searches: searches)
        #expect(cache.locate() == path)
        probe.installed = false
        #expect(cache.locate() == nil)
        #expect(searches.hits == 2)
    }

    @Test("A miss is remembered briefly, then searched for again so a fresh install is noticed")
    func missExpires() {
        let probe = CLICounter(), searches = CLICounter()
        probe.installed = false
        let cache = makeCache(probe, searches: searches)
        #expect(cache.locate() == nil)
        #expect(cache.locate() == nil)
        #expect(searches.hits == 1)

        probe.installed = true
        probe.now = probe.now.addingTimeInterval(ClaudeCLICache.missLifetime + 1)
        #expect(cache.locate() == path)
        #expect(searches.hits == 2)
    }

    @Test("The version is read once per lifetime and a failed read is never cached")
    func versionMemoised() {
        let probe = CLICounter(), searches = CLICounter()
        let cache = makeCache(probe, searches: searches)
        #expect(cache.version() == "2.1.0")
        #expect(cache.version() == "2.1.0")
        #expect(probe.hits == 1)

        probe.now = probe.now.addingTimeInterval(ClaudeCLICache.versionLifetime + 1)
        #expect(cache.version() == "2.1.0")
        #expect(probe.hits == 2)

        let failing = CLICounter()
        let failingCache = makeCache(failing, searches: CLICounter(), version: { nil })
        #expect(failingCache.version() == nil)
        #expect(failingCache.version() == nil)
        #expect(failing.hits == 2)
    }

    @Test("Invalidating forgets both the location and the version")
    func invalidateForgets() {
        let probe = CLICounter(), searches = CLICounter()
        let cache = makeCache(probe, searches: searches)
        _ = cache.version()
        cache.invalidate()
        _ = cache.version()
        #expect(searches.hits == 2)
        #expect(probe.hits == 2)
    }

    @Test("Without a CLI there is no version to report")
    func noCLINoVersion() {
        let probe = CLICounter(), searches = CLICounter()
        probe.installed = false
        let cache = makeCache(probe, searches: searches)
        #expect(cache.version() == nil)
        #expect(probe.hits == 0)
    }
}
