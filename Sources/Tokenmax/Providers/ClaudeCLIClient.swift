import Foundation

/// Decoded shape of `claude auth status`, which prints JSON and costs nothing.
///
/// This is how the session opener confirms it would run against a *subscription*
/// rather than pay-as-you-go API billing. It reports the stored login only —
/// verified experimentally that it is unaffected by `ANTHROPIC_API_KEY` in the
/// environment — so it has to be paired with the settings-file check in
/// `SessionOpener.settingsGate` to actually be conclusive.
/// Every field is optional so a shape change upstream degrades to "unknown"
/// rather than throwing. `SessionOpener.authGate` reads unknown as unsafe, so
/// losing a field can only ever suppress the opener, never permit one.
struct ClaudeAuthStatus: Decodable, Sendable, Equatable {
    var loggedIn: Bool?
    var authMethod: String?
    var apiProvider: String?
    var subscriptionType: String?
}

/// Locates the Claude Code CLI and reads its version.
///
/// The version matters: it goes into the `User-Agent` header the usage endpoint
/// requires. It is *not* used to fetch usage — the CLI has no `usage`
/// subcommand (verified against 2.1.220).
enum ClaudeCLIClient {
    /// Used when the CLI cannot be found or does not answer. Any plausible
    /// `claude-code/<version>` keeps us out of the throttled bucket.
    static let fallbackVersion = "2.1.220"

    private static let searchPaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = searchPaths.map { URL(fileURLWithPath: $0) } + [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        // Fall back to asking a login shell, which picks up PATH additions from
        // the user's profile that we cannot guess.
        if let resolved = runLoginShell("command -v claude"), !resolved.isEmpty {
            let url = URL(fileURLWithPath: resolved)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        return nil
    }

    static var isInstalled: Bool { locate() != nil }

    static func version() -> String {
        guard let cli = locate() else { return fallbackVersion }
        guard let output = run(cli, arguments: ["--version"]) else { return fallbackVersion }
        // "2.1.220 (Claude Code)" -> "2.1.220"
        let token = output.split(separator: " ").first.map(String.init) ?? ""
        return token.isEmpty ? fallbackVersion : token
    }

    /// Local only — no API call, no quota. Safe to poll, though the session
    /// opener still caches it rather than spawning a process every tick.
    static func authStatus() -> ClaudeAuthStatus? {
        guard let cli = locate() else { return nil }
        guard let output = run(cli, arguments: ["auth", "status"]) else { return nil }
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data)
    }

    private static func run(_ executable: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain both pipes concurrently. Reading stdout to EOF before stderr
        // can deadlock a CLI that fills its stderr buffer, and waiting without
        // a deadline would make a broken auth helper stall Tokenmax forever.
        let group = DispatchGroup()
        let outputBox = ClaudeCLIOutputBox()
        let errorBox = ClaudeCLIOutputBox()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else { return nil }
        let result = outputBox.value
        _ = errorBox.value // Drained deliberately; diagnostics are not credentials.
        return String(data: result, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return run(URL(fileURLWithPath: shell), arguments: ["-lc", command])
    }
}


/// Synchronizes the result of a pipe-draining worker without capturing a mutable
/// local variable in concurrently executing code.
private final class ClaudeCLIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var value: Data {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock(); stored = newValue; lock.unlock()
        }
    }
}
