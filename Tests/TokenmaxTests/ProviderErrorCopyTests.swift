import Foundation
import Testing

@testable import Tokenmax

/// `ProviderError` is shared by both providers, so any case that names one in
/// its copy is a case that will eventually name the wrong one. These pin the
/// two that carried "Claude Code" regardless of who raised them.
@Suite("Provider error copy")
struct ProviderErrorCopyTests {
    @Test("A missing CLI names the provider that is missing, not Claude")
    func notInstalledNamesItsProvider() {
        #expect(ProviderError.notInstalled("Codex").errorDescription == "Codex is not installed.")
        #expect(
            ProviderError.notInstalled("Claude Code").errorDescription
                == "Claude Code is not installed."
        )
    }

    @Test("An unauthenticated provider names itself")
    func notAuthenticatedNamesItsProvider() {
        #expect(
            ProviderError.notAuthenticated("Codex").errorDescription
                == "Codex is installed but not authenticated."
        )
    }

    /// The specific regression: `codex` absent produced a log line blaming a
    /// Claude CLI that was installed and working, which is a long way to walk
    /// before finding out nothing was wrong with it.
    @Test("A missing Codex CLI never mentions Claude")
    func missingCodexNeverMentionsClaude() async {
        let provider = CodexProvider()
        guard !CodexCLIClient.isInstalled else { return }

        await #expect(throws: ProviderError.notInstalled(provider.displayName)) {
            _ = try await provider.fetchUsage()
        }

        let copy = ProviderError.notInstalled(provider.displayName).errorDescription ?? ""
        #expect(!copy.contains("Claude"))
    }
}
