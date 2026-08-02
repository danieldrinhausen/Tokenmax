import AppKit
import Foundation

/// The 0.1 "Run" action. Deliberately does **not** execute `claude -p`.
///
/// Per the spec's safety default, automated execution is disabled in 0.1: we
/// validate the directory, put the prompt on the clipboard, open a terminal
/// there, and hand control to the user.
@MainActor
enum ManualRunService {
    enum RunError: LocalizedError {
        case missingWorkingDirectory
        case directoryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .missingWorkingDirectory:
                "This task has no working directory set."
            case let .directoryNotFound(path):
                "Working directory not found: \(path)"
            }
        }
    }

    @discardableResult
    static func copyPrompt(_ task: TokenmaxTask) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(task.prompt, forType: .string)
    }

    /// Validate → copy prompt → open terminal. Throws rather than silently
    /// marking a task running against a directory that does not exist.
    static func run(_ task: TokenmaxTask, terminalApplication: String) throws {
        guard let directory = task.expandedWorkingDirectory else {
            throw RunError.missingWorkingDirectory
        }
        guard task.workingDirectoryExists else {
            throw RunError.directoryNotFound(directory.path)
        }

        copyPrompt(task)
        openTerminal(at: directory, application: terminalApplication)
        Log.shared.write("manual run: \(task.title) in \(directory.path) via \(terminalApplication)")
    }

    static func openTerminal(at directory: URL, application: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", application, directory.path]

        do {
            try process.run()
        } catch {
            // Fall back to the user's default handler for the folder rather
            // than failing outright if the configured terminal is missing.
            Log.shared.write("openTerminal: \(application) failed (\(error.localizedDescription)), falling back to Finder")
            NSWorkspace.shared.open(directory)
        }
    }

    static func revealInFinder(_ task: TokenmaxTask) {
        guard let directory = task.expandedWorkingDirectory, task.workingDirectoryExists else { return }
        NSWorkspace.shared.open(directory)
    }
}
