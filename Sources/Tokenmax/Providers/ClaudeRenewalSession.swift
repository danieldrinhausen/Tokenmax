import Darwin
import Foundation

/// Runs `claude` in a hidden terminal until Claude Code rewrites its keychain
/// item, then stops it. The rules live in `ClaudeTokenRenewal`; this is only
/// the terminal.
///
/// A pseudo-terminal rather than pipes because Claude Code's interactive mode
/// refuses to start without a TTY, and the interactive mode is the one that
/// accepts `/status`. Spawned through `SpawnedProcess` so the CLI and anything
/// it starts share one process group that can be stopped as a whole.
///
/// Blocking by design — the coordinator calls it off the main actor.
enum ClaudeRenewalSession {
    /// Where the CLI runs. Empty and owned by Tokenmax, so the folder-trust
    /// answer trusts nothing of the user's.
    static var directory: URL {
        FileLocations.supportDirectory.appendingPathComponent("renewal", isDirectory: true)
    }

    static func run(
        cli: URL,
        itemModified: () -> Date?,
        log: (String) -> Void
    ) -> ClaudeTokenRenewal.RunResult {
        // Suppressed under test for the same reason the keychain read is: the
        // suite must never start the user's real CLI.
        guard !RuntimeEnvironment.isTesting else { return .failedToStart("suppressed under test") }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var primary: Int32 = 0
        var secondary: Int32 = 0
        // Wide enough that the startup screen does not wrap the trust question
        // across lines in a way the matcher would miss.
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
            return .failedToStart("openpty failed (\(String(cString: strerror(errno))))")
        }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)

        let baseline = itemModified()
        let process: SpawnedProcess
        do {
            process = try SpawnedProcess.spawn(
                executable: cli,
                arguments: ClaudeTokenRenewal.arguments,
                directory: directory,
                environment: ClaudeTokenRenewal.environment(from: ProcessInfo.processInfo.environment),
                standardOutput: secondaryHandle,
                standardError: secondaryHandle,
                standardInput: secondaryHandle
            )
        } catch {
            return .failedToStart(error.localizedDescription)
        }
        // The child holds its own copy. Keeping ours open would stop the
        // primary side from ever seeing EOF when the CLI exits.
        try? secondaryHandle.close()
        // Registering a handler is what reaps the child when it exits. Without
        // it `isRunning` asks `kill(pid, 0)`, which a zombie still answers, and
        // a CLI that quit early would hold the loop until the timeout.
        process.onExit { _ in }
        log("renewal: started claude (pid \(process.pid))")

        func send(_ keystroke: ClaudeTokenRenewal.Keystroke) {
            let bytes = Array(keystroke.bytes.utf8)
            _ = bytes.withUnsafeBufferPointer { write(primary, $0.baseAddress, $0.count) }
        }

        let started = Date()
        let deadline = started.addingTimeInterval(ClaudeTokenRenewal.timeout)
        var lastOutputAt = started
        var nextItemCheck = started
        var screen = ""
        var trustAnswered = false
        var statusSent = false
        var changed = false
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline, process.isRunning {
            let count = buffer.withUnsafeMutableBufferPointer { read(primary, $0.baseAddress, $0.count) }
            if count > 0 {
                lastOutputAt = Date()
                screen += String(decoding: buffer[0 ..< count], as: UTF8.self)
                // Only the recent screen matters, and an unbounded buffer on a
                // CLI that redraws a spinner would grow for the whole timeout.
                if screen.count > 16_000 { screen = String(screen.suffix(8000)) }
            }

            if !trustAnswered, ClaudeTokenRenewal.showsTrustPrompt(screen) {
                send(.acceptTrust)
                trustAnswered = true
                screen = ""
                lastOutputAt = Date()
                log("renewal: answered the folder-trust question for \(directory.path)")
            }

            if !statusSent, Date().timeIntervalSince(lastOutputAt) >= ClaudeTokenRenewal.statusDelay {
                send(.status)
                statusSent = true
            }

            if Date() >= nextItemCheck {
                nextItemCheck = Date().addingTimeInterval(0.5)
                if ClaudeTokenRenewal.itemChanged(baseline: baseline, current: itemModified()) {
                    changed = true
                    break
                }
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        let timedOut = !changed && process.isRunning
        stop(process, send: send)
        _ = primaryHandle

        // A last look: the write can land in the moment between the final poll
        // and the CLI exiting.
        if !changed, ClaudeTokenRenewal.itemChanged(baseline: baseline, current: itemModified()) {
            changed = true
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        if changed {
            log("renewal: item changed after \(elapsed)s")
            return .renewed
        }
        log("renewal: item unchanged after \(elapsed)s\(timedOut ? " (timed out)" : "")")
        return .unchanged
    }

    /// Escape first, so a CLI that is still drawing can close cleanly, then the
    /// group, then the hard stop for anything that ignored it.
    private static func stop(_ process: SpawnedProcess, send: (ClaudeTokenRenewal.Keystroke) -> Void) {
        if process.isRunning {
            send(.escape)
            Thread.sleep(forTimeInterval: 0.3)
            process.terminateGroup()
            let killAt = Date().addingTimeInterval(ClaudeTokenRenewal.killGrace)
            while process.isRunning, Date() < killAt {
                Thread.sleep(forTimeInterval: 0.1)
            }
            process.killGroup()
        }
        process.waitUntilExit()
    }
}
