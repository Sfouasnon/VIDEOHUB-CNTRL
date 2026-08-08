import Foundation
import Observation

enum SalvoStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidRouterIdentity
    case loadFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRouterIdentity:
            "A salvo requires a router identity."
        case let .loadFailed(message):
            "Salvos could not be loaded: \(message)"
        case let .saveFailed(message):
            "Salvos could not be saved: \(message)"
        }
    }
}

/// Persists operator-authored salvos, keyed by router identity.
///
/// This mirrors ``CustomizationStore``: mutations are committed to disk before
/// the in-memory copy is treated as authoritative, so a failed write can never
/// look saved until a later launch quietly reveals otherwise.
@MainActor
@Observable
final class SalvoStore {
    private(set) var salvosByRouter: [String: [Salvo]] = [:]
    private(set) var lastError: SalvoStoreError?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager

    static let fileName = "Salvos.json"

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
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

    func salvos(forRouter routerIdentity: String) -> [Salvo] {
        salvosByRouter[normalized(routerIdentity)] ?? []
    }

    func salvo(id: UUID, forRouter routerIdentity: String) -> Salvo? {
        salvos(forRouter: routerIdentity).first(where: { $0.id == id })
    }

    /// Inserts a new salvo or replaces the existing one with the same id.
    @discardableResult
    func save(_ salvo: Salvo, forRouter routerIdentity: String) -> Bool {
        let key = normalized(routerIdentity)
        guard !key.isEmpty else {
            lastError = .invalidRouterIdentity
            return false
        }

        return commitMutation {
            var list = salvosByRouter[key] ?? []
            if let index = list.firstIndex(where: { $0.id == salvo.id }) {
                list[index] = salvo
            } else {
                list.append(salvo)
            }
            salvosByRouter[key] = list
        }
    }

    @discardableResult
    func delete(id: UUID, forRouter routerIdentity: String) -> Bool {
        let key = normalized(routerIdentity)
        guard var list = salvosByRouter[key],
              list.contains(where: { $0.id == id }) else { return true }

        return commitMutation {
            list.removeAll { $0.id == id }
            if list.isEmpty {
                salvosByRouter.removeValue(forKey: key)
            } else {
                salvosByRouter[key] = list
            }
        }
    }

    func clearError() {
        lastError = nil
    }

    private func normalized(_ routerIdentity: String) -> String {
        routerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func commitMutation(_ mutation: () -> Void) -> Bool {
        let previous = salvosByRouter
        mutation()
        guard persist() else {
            salvosByRouter = previous
            return false
        }
        return true
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            salvosByRouter = [:]
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(FileDocument.self, from: data)
            salvosByRouter = document.entries.reduce(into: [:]) { result, entry in
                let key = entry.routerIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                result[key.lowercased()] = entry.salvos
            }
            lastError = nil
        } catch {
            // A damaged macro file must never prevent the control surface launching.
            salvosByRouter = [:]
            lastError = .loadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let entries = salvosByRouter
                .map { FileDocument.Entry(routerIdentity: $0.key, salvos: $0.value) }
                .sorted { $0.routerIdentity < $1.routerIdentity }

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
        let routerIdentity: String
        let salvos: [Salvo]
    }
}
