import Foundation
import Testing

@testable import Tokenmax

/// The rule these guard: elapsed time is evidence that a consent dialog
/// appeared, not proof, and the log must not turn that inference into a fact.
@Suite("Keychain read log")
struct KeychainReadLogTests {
    @Test("A millisecond read is reported as silent — no dialog can have been answered")
    func fastReadIsSilent() {
        let line = KeychainReadLog.line(outcome: .ok, elapsed: 0.004, itemModified: nil)
        #expect(line.contains("silent"))
        #expect(!line.contains("consent dialog"))
    }

    @Test("A read that blocked for seconds is reported as likely waiting on a dialog")
    func slowReadMeansDialog() {
        let line = KeychainReadLog.line(outcome: .ok, elapsed: 8.2, itemModified: nil)
        #expect(line.contains("likely waited on a consent dialog"))
    }

    @Test("A slow denial names the outcome without claiming the inference as fact")
    func slowDenialMeansDialog() {
        let line = KeychainReadLog.line(outcome: .denied, elapsed: 3.1, itemModified: nil)
        #expect(line.contains("read denied"))
        #expect(line.contains("likely waited on a consent dialog"))
    }

    /// A locked keychain by definition raised nothing, however long macOS took
    /// to say so — claiming a dialog for it would send anyone reading the log
    /// hunting for a prompt that never existed.
    @Test("The locked-keychain status never claims a dialog, whatever the elapsed time")
    func lockedKeychainNeverClaimsDialog() {
        let line = KeychainReadLog.line(
            outcome: .interactionNotAllowed, elapsed: 5.0, itemModified: nil
        )
        #expect(!line.contains("likely waited on a consent dialog"))
        #expect(line.contains("interaction unavailable"))
    }

    @Test("The item modification timestamp is carried when known and absent when not")
    func rotationTimestamp() {
        let rotated = Date(timeIntervalSince1970: 1_774_000_000)
        let with = KeychainReadLog.line(outcome: .ok, elapsed: 0.01, itemModified: rotated)
        let without = KeychainReadLog.line(outcome: .ok, elapsed: 0.01, itemModified: nil)
        #expect(with.contains("item last modified"))
        #expect(!without.contains("item last modified"))
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
