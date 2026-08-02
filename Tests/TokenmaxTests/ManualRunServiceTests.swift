import AppKit
import Foundation
import Testing

@testable import Tokenmax

/// Terminal launching, and specifically the failure it used to miss.
///
/// `Process.run()` only throws when `/usr/bin/open` itself cannot be started,
/// which essentially never happens. Naming a terminal that is not installed is
/// reported by `open` as a non-zero *exit code*, so the previous implementation
/// — which caught only the throw — reported success for every misconfigured
/// terminal, and the caller marked the task running against a session that had
/// never opened.
@Suite("Manual run service")
@MainActor
struct ManualRunServiceTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-manualrun-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func task(directory: String?) -> TokenmaxTask {
        TokenmaxTask(title: "Test", prompt: "Do it.", workingDirectory: directory)
    }

    // MARK: - The bug this suite exists for

    @Test("An application that is not installed is reported as a failure", .timeLimit(.minutes(1)))
    func missingApplicationIsRefused() async {
        let result = await ManualRunService.launch(
            application: "Tokenmax No Such Terminal \(UUID().uuidString)",
            path: scratch().path
        )
        // The old code saw `open` start successfully and called that success.
        #expect(result == .refused)
    }

    @Test("Opening a task in a missing terminal throws", .timeLimit(.minutes(1)))
    func runThrowsForMissingTerminal() async {
        let directory = scratch()
        let application = "Tokenmax No Such Terminal \(UUID().uuidString)"

        await #expect(throws: ManualRunService.RunError.self) {
            try await ManualRunService.run(
                task(directory: directory.path),
                terminalApplication: application
            )
        }
    }

    @Test("The failure names the application so the message is actionable", .timeLimit(.minutes(1)))
    func failureNamesTheApplication() async {
        let application = "Tokenmax No Such Terminal"
        let error = ManualRunService.RunError.terminalUnavailable(application)

        #expect(error.errorDescription?.contains(application) == true)
        // Points at the setting that is wrong, not just at the symptom.
        #expect(error.errorDescription?.contains("Settings") == true)
    }

    // MARK: - Validation still happens first

    @Test("A task with no working directory is refused before anything launches")
    func missingWorkingDirectoryIsRefused() async {
        await #expect(throws: ManualRunService.RunError.self) {
            try await ManualRunService.run(task(directory: nil), terminalApplication: "Terminal")
        }
    }

    @Test("A working directory that does not exist is refused")
    func absentWorkingDirectoryIsRefused() async {
        let missing = scratch().appendingPathComponent("gone").path

        await #expect(throws: ManualRunService.RunError.self) {
            try await ManualRunService.run(task(directory: missing), terminalApplication: "Terminal")
        }
    }

    @Test("The error names the directory that could not be found")
    func directoryErrorNamesThePath() {
        let error = ManualRunService.RunError.directoryNotFound("/nowhere/at/all")
        #expect(error.errorDescription?.contains("/nowhere/at/all") == true)
    }

    // MARK: - The prompt

    @Test("The prompt reaches the clipboard")
    func copyPromptWritesToTheClipboard() {
        let subject = TokenmaxTask(title: "T", prompt: "The prompt \(UUID().uuidString)")
        #expect(ManualRunService.copyPrompt(subject))

        let pasteboard = NSPasteboard.general.string(forType: .string)
        #expect(pasteboard == subject.prompt)
    }
}
