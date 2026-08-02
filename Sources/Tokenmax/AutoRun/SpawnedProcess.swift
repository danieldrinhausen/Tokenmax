import Foundation

/// A child process in its own session, so its descendants can be stopped too.
///
/// `Foundation.Process` puts the child in *Tokenmax's* process group, which
/// leaves two bad options: signal only the direct child and let its
/// grandchildren run on, or signal the group and kill Tokenmax along with them.
/// Claude Code runs its tools as child processes, so the first option is not
/// theoretical — a timed-out task leaves whatever it was doing still running,
/// invisible and unstoppable.
///
/// `posix_spawn` with `POSIX_SPAWN_SETSID` makes the child a session leader.
/// Because it then leads its own process group, a negative pid signals the task
/// and everything it started, and cannot reach Tokenmax.
///
/// Deliberately not a general-purpose `Process` replacement: it does exactly
/// what `ClaudeTaskRunner` needs and nothing more. The pipe draining, the
/// timeout, and the resolution logic all stay where they were.
final class SpawnedProcess: @unchecked Sendable {
    let pid: pid_t

    private let lock = NSLock()
    private var exitStatus: Int32?
    private var exitHandler: ((Int32) -> Void)?
    private var source: DispatchSourceProcess?

    enum SpawnError: LocalizedError {
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case let .failed(code):
                String(cString: strerror(code))
            }
        }
    }

    private init(pid: pid_t) {
        self.pid = pid
    }

    // MARK: - Spawning

    /// Starts `executable` in its own session.
    ///
    /// The file handles are the *child's* ends. The caller keeps its own ends
    /// and must close the ones it handed over — see the note on `closeInParent`.
    static func spawn(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        standardOutput: FileHandle,
        standardError: FileHandle,
        standardInput: FileHandle
    ) throws -> SpawnedProcess {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // `addchdir_np` rather than `addchdir`: the un-suffixed spelling does
        // not exist on the macOS 14 deployment target. Changing Tokenmax's own
        // working directory instead would be a process-wide side effect for a
        // per-run setting, which is not a trade worth making.
        posix_spawn_file_actions_addchdir_np(&fileActions, directory.path)
        posix_spawn_file_actions_adddup2(&fileActions, standardInput.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardOutput.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, standardError.fileDescriptor, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // SETSID is the whole point. SETSIGDEF clears any signal dispositions
        // Tokenmax has changed, so the child starts with the defaults — without
        // it a child could inherit an ignored SIGTERM and be unkillable by the
        // graceful path.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF)
        )

        let argv: [String] = [executable.path] + arguments
        let envp: [String] = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envpPointers in
                posix_spawn(&pid, executable.path, &fileActions, &attributes, argvPointers, envpPointers)
            }
        }

        guard result == 0 else { throw SpawnError.failed(result) }
        return SpawnedProcess(pid: pid)
    }

    /// Builds a NULL-terminated `char *[]` that stays valid for the call.
    private static func withCStrings<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return body(&pointers)
    }

    // MARK: - Lifetime

    var isRunning: Bool {
        lock.lock()
        let reaped = exitStatus != nil
        lock.unlock()
        guard !reaped else { return false }
        return kill(pid, 0) == 0
    }

    /// Calls `handler` once, with the same exit code `Process.terminationStatus`
    /// would have reported.
    func onExit(_ handler: @escaping (Int32) -> Void) {
        lock.lock()
        if let exitStatus {
            lock.unlock()
            handler(exitStatus)
            return
        }
        exitHandler = handler

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)
        source.setEventHandler { [weak self] in
            self?.reap()
        }
        self.source = source
        lock.unlock()

        source.resume()
    }

    /// Blocks until the child exits. Only used by tests; the runner is
    /// callback-driven.
    func waitUntilExit() {
        reap(blocking: true)
    }

    /// Collects the exit status exactly once, so the child does not linger as a
    /// zombie and the handler cannot fire twice.
    private func reap(blocking: Bool = false) {
        lock.lock()
        guard exitStatus == nil else { lock.unlock(); return }
        lock.unlock()

        var raw: Int32 = 0
        let result = waitpid(pid, &raw, blocking ? 0 : WNOHANG)
        guard result == pid else { return }

        let code = Self.exitCode(fromWaitStatus: raw)

        lock.lock()
        guard exitStatus == nil else { lock.unlock(); return }
        exitStatus = code
        let handler = exitHandler
        exitHandler = nil
        source?.cancel()
        source = nil
        lock.unlock()

        handler?(code)
    }

    /// Swift has no `WIFEXITED`/`WEXITSTATUS`, so the macros are open-coded.
    ///
    /// Matches `Process.terminationStatus`: a normal exit reports its code, and
    /// a signalled exit reports the signal number.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowSevenBits = status & 0x7F
        // 0 in the low bits means a normal exit; the code is the next byte up.
        if lowSevenBits == 0 { return (status >> 8) & 0xFF }
        return lowSevenBits
    }

    // MARK: - Termination

    /// Whether `pid` may be signalled as a group.
    ///
    /// This is the guard that makes negative-pid signalling safe rather than
    /// catastrophic, and it lives here — not at the call sites — so no future
    /// caller can route around it:
    ///
    /// - the pid must be a real child, never 0 (our whole group), never 1
    ///   (init), never negative (already a group);
    /// - it must actually lead its own group, so `POSIX_SPAWN_SETSID` silently
    ///   failing cannot turn into signalling something else entirely;
    /// - and that group must not be Tokenmax's, so terminating a run can never
    ///   terminate the app running it.
    static func isSafeToSignalGroup(pid: pid_t, ourGroup: pid_t) -> Bool {
        guard pid > 1 else { return false }
        let group = getpgid(pid)
        guard group == pid else { return false }
        guard group != ourGroup else { return false }
        return true
    }

    var leadsItsOwnGroup: Bool {
        Self.isSafeToSignalGroup(pid: pid, ourGroup: getpgid(0))
    }

    /// Asks the whole process group to stop.
    func terminateGroup() {
        signalGroup(SIGTERM)
    }

    /// Ends the whole process group, for anything that ignored SIGTERM.
    func killGroup() {
        signalGroup(SIGKILL)
    }

    /// Falls back to signalling the single process when the group cannot be
    /// verified. Losing the grandchildren is bad; signalling the wrong group
    /// would be far worse, so the unverified case degrades rather than guesses.
    private func signalGroup(_ signal: Int32) {
        guard isRunning else { return }

        if Self.isSafeToSignalGroup(pid: pid, ourGroup: getpgid(0)) {
            kill(-pid, signal)
        } else {
            Log.shared.write("autorun: pid \(pid) does not lead its own group; signalling it alone")
            kill(pid, signal)
        }
    }
}
