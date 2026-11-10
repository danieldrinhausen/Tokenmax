import Foundation
import Testing

@testable import Tokenmax

@Suite("JSON saves are single-write atomic swaps")
struct JSONStoreSaveTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A save round-trips and leaves no temp file behind")
    func savesCleanly() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")

        var settings = AppSettings()
        settings.playSound = true
        #expect(JSONStore.save(settings, to: url))
        #expect(JSONStore.load(AppSettings.self, from: url)?.playSound == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
    }

    @Test("Saving over an existing file replaces it, and the non-durable path does too")
    func replacesExisting() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")

        var first = AppSettings()
        first.playSound = true
        #expect(JSONStore.save(first, to: url))
        var second = AppSettings()
        second.showBadge = false
        #expect(JSONStore.save(second, to: url, durable: false))

        let loaded = JSONStore.load(AppSettings.self, from: url)
        #expect(loaded?.showBadge == false)
        #expect(loaded?.playSound == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
    }

    @Test("A failed save leaves the existing file untouched and reports failure")
    func failedSaveKeepsOldFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        #expect(JSONStore.save(AppSettings(), to: url))
        let before = try Data(contentsOf: url)

        // A directory squatting on the destination makes the final rename fail.
        let blocked = directory.appendingPathComponent("blocked.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: blocked.appendingPathComponent("keep"))
        #expect(!JSONStore.save(AppSettings(), to: blocked))

        #expect(try Data(contentsOf: url) == before)
        // The failed attempt cleaned up its temp file.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.sorted() == ["blocked.json", "settings.json"])
    }

    @Test("A new file gets the same permissions a plain write would")
    func permissionsMatchPlainWrite() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let reference = directory.appendingPathComponent("reference")

        #expect(JSONStore.save(AppSettings(), to: url))
        try Data("x".utf8).write(to: reference, options: .atomic)

        func mode(_ file: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(url) == mode(reference))
    }
}
