import Foundation
import Testing
@testable import VideohubCNTRL

/// Covers the rename from "Videohub On-Set" to "Videohub CNTRL".
///
/// The risk being guarded is not a crash: it is an operator opening the app
/// before a shoot and finding their port names gone, when the file is in fact
/// still on disk under the old folder.
@Suite("Legacy store migration")
struct LegacyStoreMigrationTests {
    private final class Sandbox {
        let root: URL
        let legacy: URL
        let current: URL
        let fileManager = FileManager.default

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
            legacy = root
                .appendingPathComponent(LegacyStoreMigration.legacyFolderName, isDirectory: true)
                .appendingPathComponent("TileCustomizations.json", isDirectory: false)
            current = root
                .appendingPathComponent(LegacyStoreMigration.currentFolderName, isDirectory: true)
                .appendingPathComponent("TileCustomizations.json", isDirectory: false)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ contents: String, to url: URL) throws {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        func read(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        func cleanUp() {
            try? fileManager.removeItem(at: root)
        }
    }

    @Test
    func adoptsTheLegacyFileWhenNoneExistsUnderTheNewName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write(#"{"schemaVersion":1,"entries":[]}"#, to: sandbox.legacy)

        let migrated = LegacyStoreMigration.adopt(
            legacy: sandbox.legacy,
            current: sandbox.current,
            fileManager: sandbox.fileManager
        )

        #expect(migrated)
        #expect(sandbox.read(sandbox.current) == #"{"schemaVersion":1,"entries":[]}"#)
    }

    /// The old file is left behind so rolling back to an older build mid-show
    /// still finds its data.
    @Test
    func leavesTheLegacyFileInPlace() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("legacy", to: sandbox.legacy)

        LegacyStoreMigration.adopt(
            legacy: sandbox.legacy,
            current: sandbox.current,
            fileManager: sandbox.fileManager
        )

        #expect(sandbox.fileManager.fileExists(atPath: sandbox.legacy.path))
    }

    /// Running on every launch is only safe if a second run cannot clobber
    /// edits made since the first.
    @Test
    func neverOverwritesWorkDoneUnderTheNewName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("legacy", to: sandbox.legacy)
        try sandbox.write("current", to: sandbox.current)

        let migrated = LegacyStoreMigration.adopt(
            legacy: sandbox.legacy,
            current: sandbox.current,
            fileManager: sandbox.fileManager
        )

        #expect(!migrated)
        #expect(sandbox.read(sandbox.current) == "current")
    }

    @Test
    func doesNothingWhenThereIsNoLegacyFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }

        let migrated = LegacyStoreMigration.adopt(
            legacy: sandbox.legacy,
            current: sandbox.current,
            fileManager: sandbox.fileManager
        )

        #expect(!migrated)
        #expect(!sandbox.fileManager.fileExists(atPath: sandbox.current.path))
    }

    @Test
    func isIdempotent() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.write("legacy", to: sandbox.legacy)

        let first = LegacyStoreMigration.adopt(
            legacy: sandbox.legacy, current: sandbox.current, fileManager: sandbox.fileManager
        )
        let second = LegacyStoreMigration.adopt(
            legacy: sandbox.legacy, current: sandbox.current, fileManager: sandbox.fileManager
        )

        #expect(first)
        #expect(!second)
        #expect(sandbox.read(sandbox.current) == "legacy")
    }
}
