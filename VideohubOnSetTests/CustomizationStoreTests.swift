import Foundation
import Testing
@testable import VideohubOnSet

@MainActor
@Suite("Customization store")
struct CustomizationStoreTests {
    @Test
    func roundTripSeparatesRouterKindAndZeroBasedPort() throws {
        let location = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let routerASourceZero = PortCustomizationKey(
            routerIdentity: "192.168.1.50",
            kind: .source,
            protocolPortIndex: 0
        )
        let routerADestinationZero = PortCustomizationKey(
            routerIdentity: "192.168.1.50",
            kind: .destination,
            protocolPortIndex: 0
        )
        let routerBSourceZero = PortCustomizationKey(
            routerIdentity: "studio-router.local",
            kind: .source,
            protocolPortIndex: 0
        )

        let store = CustomizationStore(fileURL: location)
        #expect(store.set(
            PortCustomization(
                displayNameOverride: "Steadicam",
                accentColor: .cyan,
                icon: .camera,
                group: "Studio A"
            ),
            for: routerASourceZero
        ))
        #expect(store.set(
            PortCustomization(
                displayNameOverride: "Output override",
                accentColor: .purple,
                icon: .monitor,
                group: "Village"
            ),
            for: routerADestinationZero
        ))
        #expect(store.set(
            PortCustomization(displayNameOverride: "Playback A", accentColor: .orange, icon: .playback),
            for: routerBSourceZero
        ))

        let reloaded = CustomizationStore(fileURL: location)
        #expect(reloaded.customization(for: routerASourceZero)?.displayNameOverride == "Steadicam")
        #expect(reloaded.customization(for: routerADestinationZero)?.displayNameOverride == "Output override")
        #expect(reloaded.customization(for: routerADestinationZero)?.icon == .monitor)
        #expect(reloaded.customization(for: routerBSourceZero)?.accentColor == .orange)
        #expect(reloaded.lastError == nil)
    }

    @Test
    func resetNameOverrideFallsBackToLiveLabelAndPreservesOtherFields() throws {
        let location = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let key = PortCustomizationKey(
            routerIdentity: "SDIRTR-01",
            kind: .source,
            protocolPortIndex: 2
        )
        let store = CustomizationStore(fileURL: location)
        store.set(
            PortCustomization(
                displayNameOverride: "Local name",
                accentColor: .green,
                icon: .camera,
                group: "Cameras"
            ),
            for: key
        )

        #expect(store.resetNameOverride(for: key))
        #expect(store.displayName(for: key, videohubLabel: "Videohub name") == "Videohub name")
        #expect(store.customization(for: key)?.accentColor == .green)
        #expect(store.customization(for: key)?.icon == .camera)
        #expect(store.customization(for: key)?.group == "Cameras")

        let reloaded = CustomizationStore(fileURL: location)
        #expect(reloaded.customization(for: key)?.displayNameOverride == nil)
        #expect(reloaded.displayName(for: key, videohubLabel: "New remote name") == "New remote name")
    }

    @Test
    func missingAndCorruptFilesDoNotPreventStoreCreation() throws {
        let location = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let missingFileStore = CustomizationStore(fileURL: location)
        #expect(missingFileStore.customizations.isEmpty)
        #expect(missingFileStore.lastError == nil)

        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: location)

        let corruptFileStore = CustomizationStore(fileURL: location)
        #expect(corruptFileStore.customizations.isEmpty)
        let hasLoadFailure: Bool
        if case .loadFailed = corruptFileStore.lastError {
            hasLoadFailure = true
        } else {
            hasLoadFailure = false
        }
        #expect(hasLoadFailure, "Expected a non-fatal load error for corrupt JSON")

        let validKey = PortCustomizationKey(
            routerIdentity: "192.168.1.50",
            kind: .destination,
            protocolPortIndex: 7
        )
        #expect(corruptFileStore.set(PortCustomization(accentColor: .red), for: validKey))

        let repairedStore = CustomizationStore(fileURL: location)
        #expect(repairedStore.customization(for: validKey)?.accentColor == .red)
        #expect(repairedStore.lastError == nil)
    }

    @Test
    func whitespaceIsNormalizedAndInvalidKeyIsRejected() throws {
        let location = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let validKey = PortCustomizationKey(
            routerIdentity: " 192.168.1.50 ",
            kind: .source,
            protocolPortIndex: 3
        )
        let store = CustomizationStore(fileURL: location)
        #expect(store.set(
            PortCustomization(
                displayNameOverride: "  Camera Four  ",
                accentColor: .pink,
                icon: .camera,
                group: "   "
            ),
            for: validKey
        ))
        #expect(store.customization(for: validKey)?.displayNameOverride == "Camera Four")
        #expect(store.customization(for: validKey)?.group == nil)

        let invalidKey = PortCustomizationKey(
            routerIdentity: "192.168.1.50",
            kind: .source,
            protocolPortIndex: -1
        )
        #expect(!store.set(PortCustomization(), for: invalidKey))
        #expect(store.lastError == .invalidKey)
    }

    @Test
    func failedSaveRollsBackInMemoryCustomization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideohubOnSet-UnwritableStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockingFile)
        let location = blockingFile.appendingPathComponent("TileCustomizations.json")

        let key = PortCustomizationKey(
            routerIdentity: "router.local",
            kind: .source,
            protocolPortIndex: 0
        )
        let store = CustomizationStore(fileURL: location)

        #expect(!store.set(PortCustomization(displayNameOverride: "Unsaved"), for: key))
        #expect(store.customization(for: key) == nil)
        if case .saveFailed = store.lastError {
            // Expected: the parent path is a file, not a directory.
        } else {
            Issue.record("Expected a non-fatal save error")
        }
    }

    @Test("Every color and icon option persists without key collisions")
    func everyChoicePersists() throws {
        let location = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }

        let store = CustomizationStore(fileURL: location)
        for (index, accent) in PortAccentColor.allCases.enumerated() {
            let key = PortCustomizationKey(
                routerIdentity: "palette-router.local",
                kind: .source,
                protocolPortIndex: index
            )
            #expect(store.set(PortCustomization(accentColor: accent), for: key))
        }
        for (index, icon) in VideohubIcon.allCases.enumerated() {
            let key = PortCustomizationKey(
                routerIdentity: "icon-router.local",
                kind: .destination,
                protocolPortIndex: index
            )
            #expect(store.set(PortCustomization(icon: icon), for: key))
        }

        let reloaded = CustomizationStore(fileURL: location)
        for (index, accent) in PortAccentColor.allCases.enumerated() {
            let key = PortCustomizationKey(
                routerIdentity: "palette-router.local",
                kind: .source,
                protocolPortIndex: index
            )
            #expect(reloaded.customization(for: key)?.accentColor == accent)
        }
        for (index, icon) in VideohubIcon.allCases.enumerated() {
            let key = PortCustomizationKey(
                routerIdentity: "icon-router.local",
                kind: .destination,
                protocolPortIndex: index
            )
            #expect(reloaded.customization(for: key)?.icon == icon)
        }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VideohubOnSet-CustomizationTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("TileCustomizations.json", isDirectory: false)
    }
}
