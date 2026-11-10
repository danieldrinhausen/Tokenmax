import Foundation
import Testing

@testable import Tokenmax

@Suite("Version ordering")
struct AppVersionTests {
    @Test("Components are compared as numbers, not as text")
    func numericOrdering() {
        // The whole reason this type exists: alphabetically "0.1.10" sorts
        // *before* "0.1.9", so a string comparison would stop noticing updates
        // exactly once there had been ten of them.
        #expect(AppVersion("0.1.9")! < AppVersion("0.1.10")!)
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
    }

    @Test("A missing component reads as zero")
    func paddedComparison() {
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.0")! < AppVersion("1.0.1")!)
        #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
    }

    @Test("Release tags are accepted in the shapes GitHub produces")
    func tagShapes() {
        #expect(AppVersion("v0.1.2")! == AppVersion("0.1.2")!)
        #expect(AppVersion("  v0.1.2 ")! == AppVersion("0.1.2")!)
        #expect(AppVersion("0.1.2-beta.1")! == AppVersion("0.1.2")!)
        #expect(AppVersion("0.1.2+ci")! == AppVersion("0.1.2")!)
    }

    @Test("Something that is not a version is rejected, not guessed at")
    func rejectsNonsense() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1.x.3") == nil)
        #expect(AppVersion("-1.0") == nil)
    }

    /// The About pane shows this, so it has to be the version the build claims
    /// rather than a normalised form of it.
    @Test("Description round-trips what was parsed")
    func description() {
        #expect(AppVersion("0.1.0")!.description == "0.1.0")
        #expect(AppVersion("v2.10")!.description == "2.10")
    }
}

@Suite("Update check rules")
struct UpdateCheckDecisionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A first check runs immediately")
    func firstCheck() {
        #expect(UpdateCheck.decide(enabled: true, lastCheckedAt: nil, now: now) == .check)
    }

    @Test("Checks are held to once a day")
    func interval() {
        let recent = now.addingTimeInterval(-3600)
        #expect(UpdateCheck.decide(enabled: true, lastCheckedAt: recent, now: now) == .skip(.checkedRecently))

        let yesterday = now.addingTimeInterval(-UpdateCheck.interval - 1)
        #expect(UpdateCheck.decide(enabled: true, lastCheckedAt: yesterday, now: now) == .check)
    }

    @Test("Switched off means no request at all")
    func switchedOff() {
        #expect(UpdateCheck.decide(enabled: false, lastCheckedAt: nil, now: now) == .skip(.switchedOff))
    }

    /// Pressing the button in Settings is a direct instruction. Refusing it
    /// because the background check is off, or because one ran an hour ago,
    /// would read as a broken button.
    @Test("Check Now overrides both the interval and the switch")
    func forceOverrides() {
        let recent = now.addingTimeInterval(-60)
        #expect(UpdateCheck.decide(enabled: false, lastCheckedAt: recent, now: now, force: true) == .check)
    }

    @Test("A newer release is offered")
    func newerIsOffered() {
        #expect(UpdateCheck.offer(currentVersion: "0.1.2", latestTag: "v0.1.3") == .available(AppVersion("0.1.3")!))
    }

    /// Anyone running a build from source sits ahead of the latest tag. Telling
    /// them to "update" to an older version would be worse than saying nothing.
    @Test("A same or older release is never offered")
    func olderIsNotOffered() {
        #expect(UpdateCheck.offer(currentVersion: "0.1.2", latestTag: "v0.1.2") == .none(.notNewer))
        #expect(UpdateCheck.offer(currentVersion: "0.2.0", latestTag: "v0.1.9") == .none(.notNewer))
    }

    /// An unreadable tag must not be mistaken for "no update available" — the
    /// two look identical from the outside, so the reason is named.
    @Test("An unreadable version names itself rather than passing as up to date")
    func unreadable() {
        #expect(UpdateCheck.offer(currentVersion: "0.1.2", latestTag: "nightly") == .none(.unreadableTag))
        #expect(UpdateCheck.offer(currentVersion: "?", latestTag: "v0.1.3") == .none(.unreadableOwnVersion))
    }

    @Test("Every suppression has copy to show")
    func suppressionsHaveCopy() {
        for suppression in [
            UpdateCheckSuppression.switchedOff, .checkedRecently, .unreadableTag,
            .unreadableOwnVersion, .notNewer,
        ] {
            #expect(!suppression.summary.isEmpty)
        }
    }
}

@Suite("Update check keeps what it found")
struct UpdateCheckPersistenceTests {
    private let page = URL(string: "https://github.com/x/y/releases/tag/v0.2.0")!

    @Test("A failed check never replaces an offer already found")
    func failureKeepsAvailable() {
        let offered = UpdateCheckState.available(AppVersion("0.2.0")!, page: page)
        #expect(UpdateCheck.stateAfterFailure(previous: offered, message: "offline") == offered)
    }

    @Test("A failed check with nothing found still says it could not complete, never up to date")
    func failureWithoutOfferIsUnavailable() {
        for previous in [UpdateCheckState.idle, .upToDate, .unavailable("old")] {
            #expect(UpdateCheck.stateAfterFailure(previous: previous, message: "offline") == .unavailable("offline"))
        }
    }

    @Test("A remembered newer release is offered again after a relaunch")
    func restoresOffer() {
        let record = UpdateCheckRecord(
            lastCheckedAt: Date(), latestTag: "v0.2.0", releasePage: page.absoluteString
        )
        #expect(UpdateCheck.restoredState(from: record, currentVersion: "0.1.9")
            == .available(AppVersion("0.2.0")!, page: page))
    }

    @Test("A remembered offer is dropped once the running build has caught up")
    func restoredOfferDoesNotOutliveTheUpdate() {
        let record = UpdateCheckRecord(
            lastCheckedAt: Date(), latestTag: "v0.2.0", releasePage: page.absoluteString
        )
        #expect(UpdateCheck.restoredState(from: record, currentVersion: "0.2.0") == .upToDate)
        #expect(UpdateCheck.restoredState(from: record, currentVersion: "0.3.0") == .upToDate)
    }

    @Test("Nothing remembered, or an offer without a page, restores to idle rather than guessing")
    func restoresIdleWhenIncomplete() {
        #expect(UpdateCheck.restoredState(from: UpdateCheckRecord(), currentVersion: "0.1.0") == .idle)
        let noPage = UpdateCheckRecord(lastCheckedAt: Date(), latestTag: "v9.0.0", releasePage: nil)
        #expect(UpdateCheck.restoredState(from: noPage, currentVersion: "0.1.0") == .idle)
    }

    @Test("A check that ran recently is held off after a relaunch because the time was saved")
    func persistedTimeHoldsTheCadence() throws {
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONStore.makeEncoder().encode(UpdateCheckRecord(lastCheckedAt: checked, latestTag: "v0.1.0"))
        let record = try JSONStore.makeDecoder().decode(UpdateCheckRecord.self, from: data)
        #expect(record.lastCheckedAt == checked)
        #expect(UpdateCheck.decide(
            enabled: true, lastCheckedAt: record.lastCheckedAt, now: checked.addingTimeInterval(3600)
        ) == .skip(.checkedRecently))
    }

    @Test("A record with missing or mistyped fields still loads as never checked")
    func tolerantRecord() throws {
        let empty = try JSONStore.makeDecoder().decode(UpdateCheckRecord.self, from: Data("{}".utf8))
        #expect(empty == UpdateCheckRecord())
        let bad = try JSONStore.makeDecoder().decode(
            UpdateCheckRecord.self,
            from: Data(#"{ "lastCheckedAt": "yesterday", "latestTag": 4, "releasePage": [] }"#.utf8)
        )
        #expect(bad == UpdateCheckRecord())
    }
}
