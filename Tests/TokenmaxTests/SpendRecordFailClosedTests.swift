import Foundation
import Testing

@testable import Tokenmax

/// The opener's and the queue's records of what has been spent are the only
/// thing standing between a relaunch and a repeat spend. An unreadable file
/// used to start both as if nothing had ever happened; it now starts them
/// marked, and the marked state refuses whatever it can no longer rule out.
@Suite("Unreadable spend records fail closed")
struct SpendRecordFailClosedTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func corruptCopies(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".corrupt-") }
    }

    // MARK: - Loading

    @Test("A missing file is a fresh install: empty, not marked, and nothing written")
    func absentIsFresh() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opener = dir.appendingPathComponent("opener.json")
        let queue = dir.appendingPathComponent("queue.json")

        #expect(SessionOpenerState.loadFailingClosed(from: opener, now: now).recordLostAt == nil)
        #expect(QueueAutoRunState.loadFailingClosed(from: queue, now: now).recordLostAt == nil)
        #expect(!FileManager.default.fileExists(atPath: opener.path))
        #expect(!FileManager.default.fileExists(atPath: queue.path))
    }

    @Test("A readable file loads as it was, unmarked")
    func readableIsUntouched() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opener.json")
        var saved = SessionOpenerState()
        saved.lastKnownSessionResetAt = now
        JSONStore.save(saved, to: url)

        let loaded = SessionOpenerState.loadFailingClosed(from: url, now: now.addingTimeInterval(99))
        #expect(loaded.lastKnownSessionResetAt == JSONStore.load(SessionOpenerState.self, from: url)?.lastKnownSessionResetAt)
        #expect(loaded.recordLostAt == nil)
    }

    @Test("An unreadable opener file is set aside, starts marked, and stays marked after a relaunch")
    func unreadableOpenerFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opener.json")
        try Data("{ truncated".utf8).write(to: url)

        let state = SessionOpenerState.loadFailingClosed(from: url, now: now)
        #expect(state.recordLostAt == now)
        #expect(state.attempts.isEmpty)
        #expect(corruptCopies(in: dir).count == 1)

        // The next launch finds a valid file, and must still know.
        let relaunched = SessionOpenerState.loadFailingClosed(from: url, now: now.addingTimeInterval(3600))
        #expect(relaunched.recordLostAt == now)
    }

    @Test("An unreadable queue file is set aside, starts marked, and stays marked after a relaunch")
    func unreadableQueueFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        try Data("[1, 2".utf8).write(to: url)

        let state = QueueAutoRunState.loadFailingClosed(from: url, now: now)
        #expect(state.recordLostAt == now)
        #expect(corruptCopies(in: dir).count == 1)
        #expect(QueueAutoRunState.loadFailingClosed(from: url, now: now.addingTimeInterval(60)).recordLostAt == now)
    }

    @Test("A zero-length file where the record was counts as lost, not as a first run")
    func emptyFileIsLost() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        try Data().write(to: url)

        #expect(QueueAutoRunState.loadFailingClosed(from: url, now: now).recordLostAt == now)
    }

    // MARK: - The opener refuses

    private func idleSession() -> UsageWindow {
        UsageWindow(
            id: "claude.session", kind: .session, label: "Session", usedPercent: 0, resetAt: nil,
            observedAt: now, source: .claudeOAuth, confidence: .authoritative
        )
    }

    private func weekly() -> UsageWindow {
        UsageWindow(
            id: "claude.weekly", kind: .weekly, label: "Weekly", usedPercent: 20,
            resetAt: now.addingTimeInterval(86400), observedAt: now,
            source: .claudeOAuth, confidence: .authoritative
        )
    }

    private func openerDecision(lostAt: Date?) -> SessionOpenerDecision {
        var state = SessionOpenerState()
        state.lastKnownSessionResetAt = now.addingTimeInterval(-3600)
        state.recordLostAt = lostAt
        var settings = SessionOpenerSettings()
        settings.enabled = true
        return SessionOpener.decide(SessionOpener.Input(
            settings: settings, sessionWindow: idleSession(), weeklyWindow: weekly(),
            extraUsageEnabled: false, state: state, now: now
        ))
    }

    @Test("With a lost record the opener refuses a cycle that ended before the loss was noticed")
    func openerRefusesTheCurrentCycle() {
        #expect(openerDecision(lostAt: now.addingTimeInterval(-60)).skipReason == .spendRecordUnreadable)
        // Boundary: noticed at the very moment the window ended.
        #expect(openerDecision(lostAt: now.addingTimeInterval(-3600)).skipReason == .spendRecordUnreadable)
    }

    @Test("Without a lost record, the same situation opens")
    func openerOpensNormally() {
        #expect(openerDecision(lostAt: nil).cycleID != nil)
    }

    @Test("A cycle that ended after the loss was noticed is unaffected")
    func openerResumesWithTheNextWindow() {
        #expect(openerDecision(lostAt: now.addingTimeInterval(-7200)).cycleID != nil)
    }

    // MARK: - The queue refuses

    private func queueDecision(lostAt: Date?, resetInMinutes: Double = 30) -> QueueAutoRunDecision {
        var state = QueueAutoRunState()
        state.recordLostAt = lostAt
        var settings = QueueAutoRunSettings()
        settings.enabled = true
        settings.mode = .automatic
        var task = TokenmaxTask(
            title: "t", prompt: "p", workingDirectory: NSTemporaryDirectory(), status: .ready,
            executionMode: .automatic, sortIndex: 0
        )
        task.estimatedMinutes = 10
        let session = UsageWindow(
            id: "claude.session", kind: .session, label: "Session", usedPercent: 40,
            resetAt: now.addingTimeInterval(resetInMinutes * 60), observedAt: now,
            source: .claudeOAuth, confidence: .authoritative
        )
        return QueueAutoRun.decide(QueueAutoRun.Input(
            settings: settings, sessionWindow: session, weeklyWindow: weekly(),
            extraUsageEnabled: false, tasks: [task], state: state, now: now
        ))
    }

    @Test("With a lost record the queue treats a window that began before the loss as at its allowance")
    func queueRefusesTheCurrentWindow() {
        // The window opened 4.5h ago; the loss was noticed 10 minutes ago.
        #expect(queueDecision(lostAt: now.addingTimeInterval(-600)).skipReason == .spendRecordUnreadable)
    }

    @Test("Without a lost record, the same window runs")
    func queueRunsNormally() {
        guard case .run = queueDecision(lostAt: nil) else {
            Issue.record("expected a run, got \(queueDecision(lostAt: nil))")
            return
        }
    }

    @Test("A window that began after the loss was noticed is unaffected")
    func queueResumesWithTheNextWindow() {
        // Lost 6h ago, so a window that opened 4.5h ago is a later one.
        guard case .run = queueDecision(lostAt: now.addingTimeInterval(-6 * 3600)) else {
            Issue.record("expected a run")
            return
        }
    }

    @Test("A lost record gives the refusal a name and copy a person can act on")
    func refusalsAreNamed() {
        #expect(!SessionOpenerDecision.SkipReason.spendRecordUnreadable.explanation.isEmpty)
        #expect(SessionOpenerDecision.SkipReason.spendRecordUnreadable.isNoteworthy)
        #expect(!QueueAutoRunDecision.SkipReason.spendRecordUnreadable.explanation.isEmpty)
        #expect(QueueAutoRunDecision.SkipReason.spendRecordUnreadable.isNoteworthy)
    }
}
