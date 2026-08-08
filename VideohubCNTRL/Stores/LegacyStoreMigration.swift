import Foundation

/// Moves store files left behind by the app's former name, "Videohub On-Set".
///
/// The rename changed the Application Support folder, so without this an
/// operator's tile names and salvos would still be on disk but invisible —
/// the worst failure mode, because it looks like data loss without being it.
///
/// Only ever moves a file when the new location is empty, so a migration can
/// never overwrite work done under the new name. That also makes it safe to
/// run on every launch, which is what the stores do.
///
/// Note this covers the folder rename only. Changing the bundle identifier
/// also moved the app's sandbox container, and one sandboxed app cannot read
/// another's container — that hop needs `script/migrate_from_videohub_onset.sh`,
/// which runs outside the sandbox.
enum LegacyStoreMigration {
    static let legacyFolderName = "Videohub On-Set"
    static let currentFolderName = "Videohub CNTRL"

    /// Returns the folder holding this app's JSON stores, creating nothing.
    static func supportFolder(fileManager: FileManager, named name: String) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    /// Adopts `fileName` from the legacy folder if the current one lacks it.
    static func adoptLegacyFile(named fileName: String, fileManager: FileManager) {
        adopt(
            legacy: supportFolder(fileManager: fileManager, named: legacyFolderName)
                .appendingPathComponent(fileName, isDirectory: false),
            current: supportFolder(fileManager: fileManager, named: currentFolderName)
                .appendingPathComponent(fileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    /// The migration itself, taking explicit URLs so it can be exercised
    /// against a temporary directory instead of the real Application Support.
    ///
    /// Returns whether a file was copied, which the tests assert on.
    ///
    /// Failures are deliberately swallowed. A migration that cannot complete
    /// should leave the operator with an app that starts empty, not one that
    /// refuses to launch before a show.
    @discardableResult
    static func adopt(legacy: URL, current: URL, fileManager: FileManager) -> Bool {
        // Never overwrite: work done under the new name always wins, which is
        // what makes running this on every launch safe.
        guard !fileManager.fileExists(atPath: current.path) else { return false }
        guard fileManager.fileExists(atPath: legacy.path) else { return false }

        do {
            try fileManager.createDirectory(
                at: current.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Copy rather than move: leaving the old file in place means an
            // older build of the app still works if the operator rolls back
            // mid-show.
            try fileManager.copyItem(at: legacy, to: current)
            return true
        } catch {
            return false
        }
    }
}
