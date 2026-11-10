import Darwin
import Foundation

/// Names one specific process, not just a pid.
///
/// A pid alone is not an identity: pids are recycled, so a number recorded
/// yesterday may now belong to something the user cares about. The process's
/// start time does not repeat, so pid and start time together say "this
/// process" and nothing else.
///
/// Persisted on a run record so that a relaunch can find a child the previous
/// Tokenmax left behind — the child is in its own session and does not die with
/// its parent.
struct ProcessIdentity: Codable, Sendable, Equatable {
    var pid: Int32
    var startSeconds: Int64
    var startMicroseconds: Int32

    init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Tolerant like every other persisted type here: a record that lost a
    /// field reads as "no identity", which is the safe direction — an
    /// unverifiable process is never signalled.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        startSeconds = try container.decodeIfPresent(Int64.self, forKey: .startSeconds) ?? 0
        startMicroseconds = try container.decodeIfPresent(Int32.self, forKey: .startMicroseconds) ?? 0
    }

    var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }

    /// The identity of a live process, or nil if there is none (or it cannot be
    /// read — which callers treat the same way).
    static func read(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(
            pid: pid,
            startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int32(info.pbi_start_tvusec)
        )
    }

    static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}

/// Whether a recorded child may be stopped. Pure: everything observable about
/// the machine arrives as a parameter.
enum OrphanedProcess {
    enum Verdict: Equatable, Sendable {
        /// Nothing by that name is running any more.
        case gone
        /// Verifiably the process Tokenmax started: safe to stop its group.
        case ours
        /// The pid is in use but cannot be shown to be ours. Never signalled.
        case notOurs
    }

    /// - `live`: the identity of whatever holds `recorded.pid` now, if anything.
    /// - `groupExists`: whether a process group with that id has members.
    ///
    /// The leader may be gone while its group lives on (a grandchild outliving
    /// it), and the kernel keeps a pid reserved while its group has members. So
    /// a missing leader with a live group is still our group — *unless* the
    /// machine has rebooted since, when the same number can have been reused
    /// for something unrelated and there is no start time left to compare.
    static func verdict(
        recorded: ProcessIdentity,
        live: ProcessIdentity?,
        groupExists: Bool,
        bootTime: Date?,
        ownPID: Int32,
        ownGroup: Int32
    ) -> Verdict {
        // Never 0, 1 or negative, and never Tokenmax itself or its own group.
        guard recorded.pid > 1, recorded.pid != ownPID, recorded.pid != ownGroup else { return .notOurs }

        if let live {
            return live == recorded ? .ours : .notOurs
        }
        guard groupExists else { return .gone }
        // Without a boot time there is no way to rule a reboot out.
        guard let bootTime, recorded.startedAt >= bootTime else { return .notOurs }
        return .ours
    }

    /// Stops the recorded child's process group if, and only if, it is
    /// verifiably ours: SIGTERM, then SIGKILL after `grace`. Blocks for at most
    /// `grace`, so it belongs at launch or quit and nowhere hot.
    ///
    /// Re-verified before the SIGKILL so a group that exited during the grace
    /// and whose pid was then recycled is not hit by the escalation.
    @discardableResult
    static func stop(_ recorded: ProcessIdentity, grace: TimeInterval) -> Verdict {
        func current() -> Verdict {
            verdict(
                recorded: recorded,
                live: ProcessIdentity.read(pid: recorded.pid),
                groupExists: kill(-recorded.pid, 0) == 0,
                bootTime: ProcessIdentity.bootTime(),
                ownPID: getpid(),
                ownGroup: getpgid(0)
            )
        }

        let first = current()
        guard first == .ours else { return first }

        Log.shared.write("autorun: stopping process group \(recorded.pid) left by an earlier run")
        kill(-recorded.pid, SIGTERM)

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if current() != .ours { return first }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if current() == .ours {
            Log.shared.write("autorun: group \(recorded.pid) ignored SIGTERM; SIGKILL")
            kill(-recorded.pid, SIGKILL)
        }
        return first
    }
}
