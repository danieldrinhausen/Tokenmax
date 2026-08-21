import Foundation
import Testing

@testable import Tokenmax

/// The rule these guard: the log must say whether the consent dialog appeared,
/// and the only evidence is elapsed time — so the classification has to be
/// right at the boundary, and must never claim a dialog for a status that
/// cannot raise one.
@Suite("Keychain read log")
struct KeychainReadLogTests {
    @Test("A millisecond read is reported as silent — no dialog can have been answered")
    func fastReadIsSilent() {
        let line = KeychainReadLog.line(outcome: .ok, elapsed: 0.004, itemModified: nil)
        #expect(line.contains("silent"))
        #expect(!line.contains("consent dialog"))
    }

    @Test("A read that blocked for seconds is reported as a shown dialog")
    func slowReadMeansDialog() {
        let line = KeychainReadLog.line(outcome: .ok, elapsed: 8.2, itemModified: nil)
        #expect(line.contains("consent dialog was shown"))
    }

    @Test("A slow denial is a dialog the user answered with Deny")
    func slowDenialMeansDialog() {
        let line = KeychainReadLog.line(outcome: .denied, elapsed: 3.1, itemModified: nil)
        #expect(line.contains("read denied"))
        #expect(line.contains("consent dialog was shown"))
    }

    /// A locked keychain by definition raised nothing, however long macOS took
    /// to say so — claiming a dialog for it would send anyone reading the log
    /// hunting for a prompt that never existed.
    @Test("The locked-keychain status never claims a dialog, whatever the elapsed time")
    func lockedKeychainNeverClaimsDialog() {
        let line = KeychainReadLog.line(
            outcome: .interactionNotAllowed, elapsed: 5.0, itemModified: nil
        )
        #expect(!line.contains("consent dialog was shown"))
        #expect(line.contains("keychain locked"))
    }

    @Test("The rotation timestamp is carried when known and absent when not")
    func rotationTimestamp() {
        let rotated = Date(timeIntervalSince1970: 1_774_000_000)
        let with = KeychainReadLog.line(outcome: .ok, elapsed: 0.01, itemModified: rotated)
        let without = KeychainReadLog.line(outcome: .ok, elapsed: 0.01, itemModified: nil)
        #expect(with.contains("item last rotated"))
        #expect(!without.contains("item last rotated"))
    }

    @Test("Every outcome names itself in the line")
    func outcomesAreNamed() {
        #expect(KeychainReadLog.line(outcome: .notFound, elapsed: 0.01, itemModified: nil)
            .contains("item not found"))
        #expect(KeychainReadLog.line(outcome: .malformed, elapsed: 0.01, itemModified: nil)
            .contains("payload malformed"))
        #expect(KeychainReadLog.line(outcome: .unexpected(-25293), elapsed: 0.01, itemModified: nil)
            .contains("-25293"))
    }
}
