import Foundation
import Testing

@testable import Tokenmax

@Suite("Cursor in the app")
struct CursorWiringTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func cursorSnapshot(total: Double = 10, api: Double = 93) -> UsageSnapshot {
        let reset = now.addingTimeInterval(86_400)
        func window(_ id: String, _ used: Double) -> UsageWindow {
            UsageWindow(
                id: id, kind: .billingCycle, label: id, usedPercent: used, resetAt: reset,
                observedAt: now, source: .cursorDashboard, confidence: .authoritative
            )
        }
        return UsageSnapshot(
            providerID: TokenmaxProvider.cursor.rawValue, planName: "Pro",
            windows: [window("cursor.total", total), window("cursor.api", api)],
            fetchedAt: now, fetchDuration: 0.1, errorMessage: nil
        )
    }

    // MARK: - Settings

    @Test("Cursor starts switched off, including for an upgrade")
    func offByDefault() throws {
        #expect(!AppSettings().cursorEnabled)
        let upgraded = try JSONStore.makeDecoder().decode(AppSettings.self, from: Data(#"{ "codexEnabled": true }"#.utf8))
        #expect(!upgraded.cursorEnabled)
        #expect(!upgraded.enabledProviders.contains(.cursor))
    }

    @Test("Watching only Cursor is a valid configuration, not an empty one")
    func cursorOnlySurvives() throws {
        let settings = try JSONStore.makeDecoder().decode(AppSettings.self, from: Data(#"""
        { "claudeCodeEnabled": false, "codexEnabled": false, "cursorEnabled": true }
        """#.utf8))
        #expect(settings.enabledProviders == [.cursor])
        // …and it leaves the queue nothing to run on, which callers must read
        // as "nothing may run".
        #expect(settings.enabledTaskProviders.isEmpty)
    }

    @Test("Cursor is never a task provider, even when it is on")
    func neverATaskProvider() {
        var settings = AppSettings()
        settings.cursorEnabled = true
        #expect(settings.enabledProviders.contains(.cursor))
        #expect(!settings.enabledTaskProviders.contains(.cursor))
        #expect(!TokenmaxProvider.cursor.runsTasks)
        #expect(TokenmaxProvider.claudeCode.runsTasks && TokenmaxProvider.codex.runsTasks)
    }

    @Test("A hand-edited Cursor default task provider falls back to Claude without costing the file")
    func cursorDefaultTaskProviderFallsBack() throws {
        let settings = try JSONStore.makeDecoder().decode(AppSettings.self, from: Data(#"""
        { "defaultTaskProvider": "cursor", "remindersEnabled": true }
        """#.utf8))
        #expect(settings.defaultTaskProvider == .claudeCode)
        #expect(settings.remindersEnabled)
    }

    @Test("A task naming Cursor keeps its provider rather than silently becoming Claude")
    func cursorTaskKeepsItsProvider() {
        var task = TokenmaxTask(title: "t", prompt: "p")
        task.providerID = TokenmaxProvider.cursor.rawValue
        #expect(task.provider == .cursor)
    }

    // MARK: - Windows

    @Test("Each Cursor meter draws its own window, though both share one kind")
    func windowsResolveByID() {
        let snapshot = cursorSnapshot(total: 10, api: 93)
        #expect(snapshot.window(for: .cursorTotal)?.usedPercent == 10)
        #expect(snapshot.window(for: .cursorAPI)?.usedPercent == 93)
    }

    @Test("A Cursor meter with no window of its own draws nothing rather than its sibling")
    func missingCursorWindowIsNotSubstituted() {
        var snapshot = cursorSnapshot()
        snapshot = UsageSnapshot(
            providerID: snapshot.providerID, planName: nil,
            windows: snapshot.windows.filter { $0.id == "cursor.total" },
            fetchedAt: now, fetchDuration: 0, errorMessage: nil
        )
        #expect(snapshot.window(for: .cursorAPI) == nil)
    }

    @Test("Claude and Codex windows still resolve for their sources")
    func existingSourcesStillResolve() {
        let session = UsageWindow(
            id: "codex.session", kind: .session, label: "Session", usedPercent: 40, resetAt: now,
            observedAt: now, source: .codexAppServer, confidence: .authoritative
        )
        let snapshot = UsageSnapshot(
            providerID: "codex", planName: nil, windows: [session], fetchedAt: now, fetchDuration: 0, errorMessage: nil
        )
        #expect(snapshot.window(for: .codexSession)?.usedPercent == 40)
        #expect(snapshot.window(for: .codexWeekly) == nil)
    }

    @Test("A window id names the provider that owns it")
    func windowOwnership() {
        #expect(TokenmaxProvider.owning(windowID: "cursor.api") == .cursor)
        #expect(TokenmaxProvider.owning(windowID: "codex.weekly") == .codex)
        #expect(TokenmaxProvider.owning(windowID: "claude.weekly.opus") == .claudeCode)
        // Only the dotted prefix counts.
        #expect(TokenmaxProvider.owning(windowID: "cursorish.x") == .claudeCode)
    }

    // MARK: - Surfaces

    @Test("Cursor's own menu bar item draws its total over its API usage, counting down to the cycle's end")
    func cursorItemLayout() {
        #expect(MenuBarItemDecision.layout(for: .cursor, style: .bars).sources == [.cursorTotal, .cursorAPI])
        #expect(MenuBarItemDecision.countdownSource(for: .cursor, countdown: .session).provider == .cursor)
        #expect(MenuBarItemDecision.countdownSource(for: .cursor, countdown: .week).provider == .cursor)
    }

    @Test("Three providers get three menu bar items when the icons are separate")
    func threeSeparateItems() {
        #expect(MenuBarItemDecision.items(
            showMenuBarItem: true, layout: .separate, enabledProviders: [.cursor, .codex, .claudeCode]
        ) == [.provider(.claudeCode), .provider(.codex), .provider(.cursor)])
        #expect(MenuBarItemID.provider(.cursor).marker == .cursor)
    }

    @Test("A provider the ring layout has no room for still gets a ring in the side notch")
    func thirdProviderAppearsInNotch() throws {
        let models = SideNotchPresentation.make(
            layout: .default,
            enabledProviders: [.claudeCode, .codex, .cursor],
            snapshot: { $0 == .cursor ? cursorSnapshot() : nil },
            isStale: { _ in false },
            alerting: [],
            ready: [],
            colors: .init(),
            now: now,
            projection: { _ in nil },
            reminderStatus: { _, _ in nil }
        )

        #expect(models.map(\.provider) == [.claudeCode, .codex, .cursor])
        let cursor = try #require(models.last)
        #expect(cursor.outer.source == .cursorTotal)
        #expect(cursor.inner.source == .cursorAPI)
        #expect(cursor.outer.remainingPercent == 90)
        #expect(cursor.inner.remainingPercent == 7)
        #expect(cursor.outer.shortLabel != cursor.inner.shortLabel)
    }

    @Test("A billing cycle never becomes a burn opportunity or a reminder")
    func noSessionSemantics() {
        #expect(MenuBarQuotaSource.cursorTotal.kind == .billingCycle)
        #expect(MenuBarQuotaSource.cursorAPI.kind == .billingCycle)
        #expect(AppSettings().reminderRule(for: .cursor, kind: .billingCycle) == .disabled)
        #expect(QuotaResetEvent(provider: .cursor, kind: .billingCycle) == nil)
    }
}
