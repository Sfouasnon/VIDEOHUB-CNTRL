import Foundation

/// Where the app keeps its JSON stores.
///
/// The app is sandboxed, so `.applicationSupportDirectory` already resolves
/// inside the container — nothing here needs to know that. Falling back to the
/// temporary directory is deliberate: a store that cannot find Application
/// Support should start empty rather than refuse to launch before a show.
enum StoreLocation {
    static let folderName = "Videohub CNTRL"

    /// Returns the folder holding this app's JSON stores, creating nothing.
    static func supportFolder(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The on-disk location of one named store file.
    static func fileURL(named fileName: String, fileManager: FileManager = .default) -> URL {
        supportFolder(fileManager: fileManager)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
