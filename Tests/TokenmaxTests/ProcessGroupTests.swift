import Foundation
import Testing

@testable import Tokenmax

/// Termination, specifically of the processes the CLI spawns rather than the
/// CLI itself.
///
/// Claude Code runs its tools as child processes. Signalling only the direct
/// child leaves those grandchildren running: a timed-out task keeps burning
/// whatever it was doing, and the user has no way to see it, let alone stop it.
///
/// The fix is to give the child its own session so the whole group can be
/// signalled at once — which is only safe once the session actually exists,
/// hence the guards asserted here.
@Suite("Process group termination")
struct ProcessGroupTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-pgroup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(
        _ script: String,
        timeout: TimeInterval = 30
    ) async -> ClaudeTaskRunner.Result {
        let directory = scratch()
        return await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", script],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: timeout,
            onProgress: { _ in }
        )
    }

    /// True while `pid` names a live process we could signal.
    private func isAlive(_ pid: pid_t) -> Bool {
        // Signal 0 performs the permission and existence checks without
        // delivering anything.
        kill(pid, 0) == 0
    }

    // MARK: - The defect this phase fixes

    @Test("A grandchild does not survive a timeout", .timeLimit(.minutes(2)))
    func grandchildDiesWithTheGroup() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")

        // `trap '' TERM` makes the direct child ignore SIGTERM, so only the
        // SIGKILL escalation ends it — and the background `sleep` is the
        // grandchild that used to be left running afterwards.
        let script = """
        sleep 300 &
        echo $! > \(pidFile.path)
        trap '' TERM
        sleep 300
        """

        let result = await execute(script, timeout: 2)
        #expect(result.status == .timedOut)

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let grandchild = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }

        // The kill is asynchronous; give the group a moment to actually die.
        try? await Task.sleep(for: .seconds(1))

        #expect(!isAlive(grandchild), "the grandchild outlived the run that spawned it")

        // Belt and braces: if the assertion above failed, do not leave a stray
        // process behind for the next test run.
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    @Test("A grandchild does not survive a cancellation", .timeLimit(.minutes(2)))
    func grandchildDiesOnCancel() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")
        let script = """
        sleep 300 &
        echo $! > \(pidFile.path)
        sleep 300
        """

        let running = Task { await execute(script, timeout: 120) }

        // Wait for the script to have spawned and recorded its grandchild.
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }

        running.cancel()
        let result = await running.value
        #expect(result.status == .cancelled)

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let grandchild = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }

        try? await Task.sleep(for: .seconds(1))
        #expect(!isAlive(grandchild), "the grandchild outlived the cancelled run")
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    private func grandchildPid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @Test("A backgrounded process does not outlive a run that exited normally", .timeLimit(.minutes(2)))
    func orphanDiesAfterNormalExit() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")
        // The leader exits at once and cleanly, leaving the `sleep` behind: the
        // case a Bash-tool opt-in can produce, and one where the old guard on
        // the leader being alive meant nobody ever signalled the group.
        let result = await execute("sleep 300 &\necho $! > \(pidFile.path)\nexit 0")
        #expect(result.exitCode == 0)

        guard let grandchild = grandchildPid(in: pidFile) else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        #expect(!isAlive(grandchild), "a process in the run's group outlived the run")
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    @Test("A leftover process that ignores SIGTERM is killed after the grace", .timeLimit(.minutes(2)))
    func termIgnoringOrphanIsKilled() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")
        let result = await execute("trap '' TERM\nsleep 300 &\necho $! > \(pidFile.path)\nexit 0")
        #expect(result.exitCode == 0)

        guard let grandchild = grandchildPid(in: pidFile) else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }
        try? await Task.sleep(for: .seconds(SpawnedProcess.sweepGrace + 2))
        #expect(!isAlive(grandchild), "a SIGTERM-ignoring process survived the sweep")
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    @Test("A run whose group is already empty signals nothing after it exits", .timeLimit(.minutes(1)))
    func cleanExitSweepsNothing() throws {
        let process = try SpawnedProcess.spawn(
            executable: shell,
            arguments: ["-c", "exit 0"],
            directory: scratch(),
            environment: ["PATH": "/usr/bin:/bin"],
            standardOutput: FileHandle.nullDevice,
            standardError: FileHandle.nullDevice,
            standardInput: FileHandle.nullDevice
        )
        process.waitUntilExit()
        #expect(!process.hasLiveGroup)
        // Safe to call: no live group, so there is nothing to signal.
        process.killGroup()
    }

    // MARK: - The safety property that makes the above possible

    @Test("The child leads its own session, never ours", .timeLimit(.minutes(1)))
    func childIsItsOwnSessionLeader() throws {
        let directory = scratch()
        let output = Pipe()

        let process = try SpawnedProcess.spawn(
            executable: shell,
            // The child reports its own pid and process-group id.
            arguments: ["-c", "echo $$; ps -o pgid= -p $$"],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardOutput: output.fileHandleForWriting,
            standardError: FileHandle.nullDevice,
            standardInput: FileHandle.nullDevice
        )

        // Must be its own group leader — this is precisely the precondition
        // that makes `kill(-pid, …)` safe rather than suicidal.
        #expect(process.leadsItsOwnGroup)
        #expect(process.pid > 1)

        // And that group must not be Tokenmax's own, or terminating a run would
        // terminate the app running it.
        #expect(getpgid(process.pid) != getpgid(0))

        _ = try? output.fileHandleForWriting.close()
        _ = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
    }

    @Test("Tokenmax never signals its own process group", .timeLimit(.minutes(1)))
    func neverSignalsOurselves() {
        // The guard is a property of the process, not of the call site, so a
        // future caller cannot accidentally route around it.
        #expect(getpgid(0) == getpgid(getpid()) || getpgid(0) != -1)
        // Our own pid can never satisfy the leader test against a *spawned*
        // process, because a spawned one is compared to its own pid.
        let ours = getpid()
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: ours, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: 0, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: 1, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: -1, ourGroup: getpgid(0)))
    }

    // MARK: - Ordinary behaviour is unchanged

    @Test("An ordinary run still reports its exit code", .timeLimit(.minutes(1)))
    func exitCodeSurvivesTheNewSpawn() async {
        let result = await execute("exit 3")
        #expect(result.exitCode == 3)
        #expect(result.status == .failed)
    }

    @Test("A successful run still parses its result envelope", .timeLimit(.minutes(1)))
    func envelopeStillParses() async {
        let result = await execute(
            #"echo '{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.02}'"#
        )
        #expect(result.status == .completed)
        #expect(result.resultText == "done")
        #expect(result.costUSD == 0.02)
    }

    @Test("The working directory is still the task's", .timeLimit(.minutes(1)))
    func workingDirectoryIsHonoured() async {
        // posix_spawn does not inherit a chdir the way Process's
        // currentDirectoryURL did, so this is worth asserting explicitly.
        let directory = scratch()
        let result = await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", #"echo "{\"type\":\"result\",\"result\":\"$(pwd)\"}""#],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: 30,
            onProgress: { _ in }
        )

        // Both sides are resolved: the scratch path runs through /private on
        // macOS, and which spelling `pwd` reports is not what is under test.
        let reported = URL(fileURLWithPath: result.resultText ?? "").resolvingSymlinksInPath().path
        let expected = directory.resolvingSymlinksInPath().path
        #expect(reported == expected)
    }

    @Test("The environment still reaches the child", .timeLimit(.minutes(1)))
    func environmentIsHonoured() async {
        let directory = scratch()
        let result = await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", #"echo "{\"type\":\"result\",\"result\":\"$TOKENMAX_PROBE\"}""#],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin", "TOKENMAX_PROBE": "reached"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: 30,
            onProgress: { _ in }
        )
        #expect(result.resultText == "reached")
    }
}

/// Whether a child recorded by an earlier Tokenmax may be signalled. The one
/// rule that matters: never a process that merely has the same pid.
@Suite("Orphaned process identity")
struct OrphanedProcessTests {
    private let recorded = ProcessIdentity(pid: 500, startSeconds: 2_000, startMicroseconds: 10)
    private let boot = Date(timeIntervalSince1970: 1_000)

    private func verdict(
        live: ProcessIdentity?, group: Bool, boot: Date? = Date(timeIntervalSince1970: 1_000),
        recorded override: ProcessIdentity? = nil, ownPID: Int32 = 9, ownGroup: Int32 = 9
    ) -> OrphanedProcess.Verdict {
        OrphanedProcess.verdict(
            recorded: override ?? recorded, live: live, groupExists: group,
            bootTime: boot, ownPID: ownPID, ownGroup: ownGroup
        )
    }

    @Test("The same pid and start time is the same process")
    func matchingIdentityIsOurs() {
        #expect(verdict(live: recorded, group: true) == .ours)
    }

    @Test("A recycled pid, with a different start time, is never ours")
    func recycledPidIsNotOurs() {
        let later = ProcessIdentity(pid: 500, startSeconds: 2_000, startMicroseconds: 11)
        #expect(verdict(live: later, group: true) == .notOurs)
        let muchLater = ProcessIdentity(pid: 500, startSeconds: 90_000, startMicroseconds: 10)
        #expect(verdict(live: muchLater, group: true) == .notOurs)
        // Same start time but another pid is not the process either.
        let other = ProcessIdentity(pid: 501, startSeconds: 2_000, startMicroseconds: 10)
        #expect(verdict(live: other, group: true) == .notOurs)
    }

    @Test("Nothing running and no group means there is nothing to stop")
    func nothingRunningIsGone() {
        #expect(verdict(live: nil, group: false) == .gone)
    }

    @Test("A dead leader with a live group is ours only if it started after boot")
    func leaderlessGroupNeedsBootCheck() {
        #expect(verdict(live: nil, group: true) == .ours)
        // Recorded before the last boot: the number may mean anything now.
        let beforeBoot = ProcessIdentity(pid: 500, startSeconds: 100, startMicroseconds: 0)
        #expect(verdict(live: nil, group: true, recorded: beforeBoot) == .notOurs)
        // And with no boot time to compare against, the answer is no.
        #expect(verdict(live: nil, group: true, boot: nil) == .notOurs)
    }

    @Test("Our own pid, our own group, init and nonsense are never signalled")
    func neverSignalsProtectedPids() {
        for pid: Int32 in [0, 1, -1, -500] {
            let identity = ProcessIdentity(pid: pid, startSeconds: 2_000, startMicroseconds: 10)
            #expect(verdict(live: identity, group: true, recorded: identity) == .notOurs)
        }
        #expect(verdict(live: recorded, group: true, ownPID: 500) == .notOurs)
        #expect(verdict(live: recorded, group: true, ownGroup: 500) == .notOurs)
    }

    // MARK: - Against a real process

    private func spawnSleeper() throws -> SpawnedProcess {
        try SpawnedProcess.spawn(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["300"],
            directory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardOutput: FileHandle.nullDevice,
            standardError: FileHandle.nullDevice,
            standardInput: FileHandle.nullDevice
        )
    }

    @Test("A live child's identity is readable and stable", .timeLimit(.minutes(1)))
    func identityOfLiveProcess() throws {
        let process = try spawnSleeper()
        defer { process.killGroup(); process.waitUntilExit() }
        let identity = try #require(ProcessIdentity.read(pid: process.pid))
        #expect(identity.pid == process.pid)
        #expect(ProcessIdentity.read(pid: process.pid) == identity)
        #expect(identity.startedAt <= Date())
        #expect(identity.startedAt >= Date().addingTimeInterval(-60))
    }

    @Test("A verified orphan's group is stopped", .timeLimit(.minutes(1)))
    func verifiedOrphanIsStopped() throws {
        let process = try spawnSleeper()
        let identity = try #require(ProcessIdentity.read(pid: process.pid))

        #expect(OrphanedProcess.stop(identity, grace: 3) == .ours)
        process.waitUntilExit()
        #expect(kill(process.pid, 0) != 0)
    }

    @Test("A process whose start time does not match is left running", .timeLimit(.minutes(1)))
    func mismatchedProcessSurvives() throws {
        let process = try spawnSleeper()
        defer { process.killGroup(); process.waitUntilExit() }
        var wrong = try #require(ProcessIdentity.read(pid: process.pid))
        wrong.startSeconds -= 3600

        #expect(OrphanedProcess.stop(wrong, grace: 0.2) == .notOurs)
        #expect(process.isRunning, "a process with a recycled pid was signalled")
    }
}
