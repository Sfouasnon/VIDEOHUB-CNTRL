import Foundation
import Observation

enum CustomizationStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidKey
    case loadFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "A customization key requires a router identity and a non-negative protocol port index."
        case let .loadFailed(message):
            "Tile customizations could not be loaded: \(message)"
        case let .saveFailed(message):
            "Tile customizations could not be saved: \(message)"
        }
    }
}

@MainActor
@Observable
final class CustomizationStore {
    private(set) var customizations: [PortCustomizationKey: PortCustomization] = [:]
    private(set) var lastError: CustomizationStoreError?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager

    static let fileName = "TileCustomizations.json"

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        // Only when using the default location: an injected URL is a test or a
        // QA session, and adopting production data into either would be wrong.
        if fileURL == nil {
            LegacyStoreMigration.adoptLegacyFile(named: Self.fileName, fileManager: fileManager)
        }
        loadFromDisk()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        LegacyStoreMigration
            .supportFolder(fileManager: fileManager, named: LegacyStoreMigration.currentFolderName)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    subscript(key: PortCustomizationKey) -> PortCustomization? {
        customizations[key]
    }

    func customization(for key: PortCustomizationKey) -> PortCustomization? {
        customizations[key]
    }

    func displayName(for key: PortCustomizationKey, videohubLabel: String) -> String {
        customizations[key]?.displayName(videohubLabel: videohubLabel) ?? videohubLabel
    }

    /// Saves a complete customization. The file replacement itself is atomic.
    @discardableResult
    func set(_ customization: PortCustomization, for key: PortCustomizationKey) -> Bool {
        guard key.isValid else {
            lastError = .invalidKey
            return false
        }

        return commitMutation {
            customizations[key] = customization.normalized()
        }
    }

    /// Creates a default customization when needed, mutates it, then persists it.
    @discardableResult
    func update(
        for key: PortCustomizationKey,
        default defaultCustomization: @autoclosure () -> PortCustomization = PortCustomization(),
        _ mutation: (inout PortCustomization) -> Void
    ) -> Bool {
        guard key.isValid else {
            lastError = .invalidKey
            return false
        }

        var customization = customizations[key] ?? defaultCustomization()
        mutation(&customization)
        return commitMutation {
            customizations[key] = customization.normalized()
        }
    }

    /// Clears only the local name override; color, icon, and group remain unchanged.
    @discardableResult
    func resetToVideohubLabel(for key: PortCustomizationKey) -> Bool {
        guard var customization = customizations[key] else { return true }
        customization.resetToVideohubLabel()
        return commitMutation {
            customizations[key] = customization
        }
    }

    /// Naming alias for callers that describe this operation in terms of the override itself.
    @discardableResult
    func resetNameOverride(for key: PortCustomizationKey) -> Bool {
        resetToVideohubLabel(for: key)
    }

    @discardableResult
    func removeCustomization(for key: PortCustomizationKey) -> Bool {
        guard customizations[key] != nil else { return true }
        return commitMutation {
            customizations.removeValue(forKey: key)
        }
    }

    func clearError() {
        lastError = nil
    }

    /// Keeps the in-memory presentation authoritative only when its JSON file
    /// was updated successfully. A failed write therefore cannot look saved
    /// until the next launch silently reveals otherwise.
    private func commitMutation(_ mutation: () -> Void) -> Bool {
        let previous = customizations
        mutation()
        guard persist() else {
            customizations = previous
            return false
        }
        return true
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            customizations = [:]
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(FileDocument.self, from: data)
            customizations = document.entries.reduce(into: [:]) { result, entry in
                guard entry.key.isValid else { return }
                result[entry.key] = entry.customization.normalized()
            }
            lastError = nil
        } catch {
            // A damaged preferences file must never prevent the control surface launching.
            customizations = [:]
            lastError = .loadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let parentDirectory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )

            let entries = customizations
                .map { FileDocument.Entry(key: $0.key, customization: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.key.routerIdentity != rhs.key.routerIdentity {
                        return lhs.key.routerIdentity < rhs.key.routerIdentity
                    }
                    if lhs.key.kind != rhs.key.kind {
                        return lhs.key.kind.rawValue < rhs.key.kind.rawValue
                    }
                    return lhs.key.protocolPortIndex < rhs.key.protocolPortIndex
                }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileDocument(entries: entries))
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = .saveFailed(error.localizedDescription)
            return false
        }
    }
}

private struct FileDocument: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let entries: [Entry]

    init(entries: [Entry]) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }

    struct Entry: Codable {
        let key: PortCustomizationKey
        let customization: PortCustomization
    }
}
