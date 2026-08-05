import Foundation

/// Locates Codex without assuming a menu-bar application inherited a useful
/// shell PATH.  Kept separate from the App Server client so installation and
/// authentication failures are cheap to diagnose.
enum CodexCLIClient {
    static func locate() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static var isInstalled: Bool { locate() != nil }
}

