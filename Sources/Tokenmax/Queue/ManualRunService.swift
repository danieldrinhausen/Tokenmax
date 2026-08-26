import AppKit
import Foundation

/// The "Open in Terminal" action. Deliberately does **not** execute `claude -p`.
///
/// Per the spec's safety default, this path never runs anything itself: we
/// validate the directory, put the prompt on the clipboard, open a terminal
/// there, and hand control to the user.
@MainActor
enum ManualRunService {
    enum RunError: LocalizedError {
        case missingWorkingDirectory
        case directoryNotFound(String)
        case terminalUnavailable(String)
        case terminalLaunchFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .missingWorkingDirectory:
                "This task has no working directory set."
            case let .directoryNotFound(path):
                "Working directory not found: \(path)"
            case let .terminalUnavailable(application):
                "Could not open \(application). Check the terminal application in Settings."
            case let .terminalLaunchFailed(application, detail):
                "Could not open \(application): \(detail)"
            }
        }
    }

    /// How long to wait for `open` to report back.
    ///
    /// `open` asks Launch Services to start the app and exits; it does not wait
    /// for the app to finish launching. A few seconds is generous, and the cap
    /// exists so a wedged Launch Services cannot hang the button forever.
    ///
    /// `nonisolated` because the wait itself happens off the main actor.
    nonisolated static let launchTimeout: TimeInterval = 5

    @discardableResult
    static func copyPrompt(_ task: TokenmaxTask) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(task.prompt, forType: .string)
    }

    /// Validate → copy prompt → open terminal.
    ///
    /// Throws rather than silently reporting success. The caller marks the task
    /// `.running` on the strength of this returning, so a terminal that never
    /// opened must not look like one that did.
    static func run(_ task: TokenmaxTask, terminalApplication: String) async throws {
        guard let directory = task.expandedWorkingDirectory else {
            throw RunError.missingWorkingDirectory
        }
        guard task.workingDirectoryExists else {
            throw RunError.directoryNotFound(directory.path)
        }

        copyPrompt(task)
        try await openTerminal(at: directory, application: terminalApplication)
        Log.shared.write("manual run: \(task.title) in \(directory.path) via \(terminalApplication)")
    }

    /// Opens `application` at `directory`, and throws if it did not open.
    ///
    /// The subtlety this exists for: `Process.run()` only throws when
    /// `/usr/bin/open` itself cannot be started, which essentially never
    /// happens. Naming an application that is not installed is reported by
    /// `open` as a **non-zero exit code**, so a version of this that only
    /// catches the throw reports success for every misconfigured terminal.
    static func openTerminal(at directory: URL, application: String) async throws {
        let result = await launch(application: application, path: directory.path)

        switch result {
        case .success:
            return
        case let .failedToStart(message):
            throw RunError.terminalLaunchFailed(application, message)
        case .timedOut:
            throw RunError.terminalLaunchFailed(application, "it did not respond")
        case .refused:
            throw RunError.terminalUnavailable(application)
        }
    }

    /// Opens the configured terminal at the user's home directory, optionally
    /// leaving an explicit recovery command on the pasteboard.
    ///
    /// The recovery action behind "Claude Code is not installed" and friends:
    /// all of those are fixed by running `claude` somewhere, and somewhere is
    /// home. Failures are logged rather than raised — this is offered as a
    /// convenience beside an error message, and a second error on top of the
    /// first would not help anyone.
    static func openTerminalForRecovery(application: String, commandToPaste: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let commandToPaste {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(commandToPaste, forType: .string)
        }
        Task {
            do {
                try await openTerminal(at: home, application: application)
            } catch {
                Log.shared.write("openTerminal(recovery): \(error.localizedDescription)")
            }
        }
    }

    static func revealInFinder(_ task: TokenmaxTask) {
        guard let directory = task.expandedWorkingDirectory, task.workingDirectoryExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Launching

    enum LaunchResult: Equatable {
        case success
        /// `open` ran and refused — almost always a terminal that is not installed.
        case refused
        case failedToStart(String)
        case timedOut
    }

    /// Runs `/usr/bin/open -a <application> <path>` and reports what happened.
    ///
    /// Waits off the main actor: `open` is quick, but "quick" is not "instant",
    /// and blocking the main thread on a subprocess is how a click turns into a
    /// beachball.
    static func launch(application: String, path: String) async -> LaunchResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", application, path]
                // Otherwise `open`'s complaint lands in Tokenmax's own stderr.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failedToStart(error.localizedDescription))
                    return
                }

                // Resolved exactly once: either the wait finishes or the
                // deadline does. `Process.waitUntilExit` has no timeout of its
                // own, so the deadline is enforced here.
                let deadline = Date().addingTimeInterval(launchTimeout)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }

                guard !process.isRunning else {
                    process.terminate()
                    continuation.resume(returning: .timedOut)
                    return
                }

                continuation.resume(returning: process.terminationStatus == 0 ? .success : .refused)
            }
        }
    }
}
