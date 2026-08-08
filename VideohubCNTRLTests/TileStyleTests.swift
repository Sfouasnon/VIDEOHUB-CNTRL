import Foundation
import Testing
@testable import VideohubCNTRL

@Suite("Tile style copy and paste", .serialized)
@MainActor
struct TileStyleTests {
    // MARK: - What a style carries

    @Test("A style carries colour, icon, and group but never the name")
    func styleExcludesDisplayName() {
        let source = PortCustomization(
            displayNameOverride: "Cam 1 Wide",
            accentColor: .red,
            icon: .camera,
            group: "Cameras"
        )
        let style = TileStyle(source)

        #expect(style.accentColor == .red)
        #expect(style.icon == .camera)
        #expect(style.group == "Cameras")

        let target = PortCustomization(
            displayNameOverride: "Cam 2 Tight",
            accentColor: .blue,
            icon: .monitor,
            group: "Monitors"
        )
        let pasted = style.applied(to: target)

        // The whole point: the target keeps its own name.
        #expect(pasted.displayNameOverride == "Cam 2 Tight")
        #expect(pasted.accentColor == .red)
        #expect(pasted.icon == .camera)
        #expect(pasted.group == "Cameras")
    }

    @Test("Pasting onto a tile with no name override leaves it without one")
    func pasteDoesNotInventAName() {
        let style = TileStyle(accentColor: .green, icon: .record, group: "Rec")
        let target = PortCustomization(accentColor: .blue, icon: .monitor)
        let pasted = style.applied(to: target)

        #expect(pasted.displayNameOverride == nil)
        #expect(pasted.accentColor == .green)
    }

    @Test("A blank group is normalized away rather than stored as empty text")
    func blankGroupIsNormalized() {
        #expect(TileStyle(accentColor: .blue, icon: .camera, group: "   ").group == nil)
        #expect(TileStyle(accentColor: .blue, icon: .camera, group: " Cameras ").group == "Cameras")
    }

    @Test("Sources and destinations with the same port number are distinct targets")
    func targetsAreScopedByKind() {
        let port = PortNumber(uiNumber: 3)!
        let source = TileStyleTarget(kind: .source, port: port)
        let destination = TileStyleTarget(kind: .destination, port: port)

        #expect(source != destination)
        #expect(Set([source, destination]).count == 2)
    }

    // MARK: - Copying

    @Test("Copying captures the tile's resolved look")
    func copyCapturesResolvedStyle() {
        let store = makeStore()
        let input = store.inputs[2]
        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Cam 3",
                accentColor: .purple,
                icon: .camera,
                group: "Cameras"
            ),
            for: input
        )

        store.copyStyle(from: input)

        #expect(store.copiedStyle?.accentColor == .purple)
        #expect(store.copiedStyle?.icon == .camera)
        #expect(store.copiedStyle?.group == "Cameras")
    }

    @Test("Pasting with nothing copied is refused with a notice")
    func pasteWithoutCopyIsRefused() {
        let store = makeStore()
        let before = store.presentation(for: store.inputs[0])

        store.pasteStyle(onto: store.inputs[0])

        #expect(store.notice?.message == "No style copied yet")
        #expect(store.presentation(for: store.inputs[0]).accentColor == before.accentColor)
    }

    // MARK: - Pasting onto one tile

    @Test("Pasting onto one tile restyles it without touching its name")
    func pasteOntoSingleTile() {
        let store = makeStore()
        let donor = store.inputs[0]
        let recipient = store.inputs[1]

        store.saveCustomization(
            PortCustomization(accentColor: .orange, icon: .playback, group: "VT"),
            for: donor
        )
        store.saveCustomization(
            PortCustomization(displayNameOverride: "Keep Me", accentColor: .blue, icon: .monitor),
            for: recipient
        )

        store.copyStyle(from: donor)
        store.pasteStyle(onto: recipient)

        let presentation = store.presentation(for: store.inputs[1])
        #expect(presentation.accentColor == .orange)
        #expect(presentation.icon == .playback)
        #expect(presentation.group == "VT")
        #expect(presentation.displayName == "Keep Me")
    }

    // MARK: - Selection

    @Test("Selection toggles and is independent of the routing selection")
    func selectionIsIndependentOfRouting() {
        let store = makeStore()
        let target = TileStyleTarget(kind: .source, port: store.inputs[0].id)

        store.selectInput(store.inputs[3].id)
        store.toggleStyleSelection(target)

        #expect(store.isStyleSelected(target))
        #expect(store.styleSelectionCount == 1)
        // Marking a tile for styling must never change what a TAKE would route.
        #expect(store.selectedInputID == store.inputs[3].id)

        store.toggleStyleSelection(target)
        #expect(!store.isStyleSelected(target))
        #expect(store.styleSelectionCount == 0)
    }

    @Test("Bulk paste applies to every selected tile and then clears the selection")
    func bulkPasteAppliesToAllSelected() {
        let store = makeStore()
        let donor = store.inputs[0]
        store.saveCustomization(
            PortCustomization(accentColor: .red, icon: .camera, group: "Cameras"),
            for: donor
        )
        store.copyStyle(from: donor)

        for index in 1...3 {
            store.toggleStyleSelection(
                TileStyleTarget(kind: .source, port: store.inputs[index].id)
            )
        }
        store.toggleStyleSelection(
            TileStyleTarget(kind: .destination, port: store.outputs[5].id)
        )

        store.pasteStyleOntoSelection()

        for index in 1...3 {
            let presentation = store.presentation(for: store.inputs[index])
            #expect(presentation.accentColor == .red)
            #expect(presentation.icon == .camera)
            #expect(presentation.group == "Cameras")
        }
        // Destinations in the same selection are styled too.
        #expect(store.presentation(for: store.outputs[5]).accentColor == .red)

        // Selection is consumed so a second paste cannot silently restyle again.
        #expect(store.styleSelectionCount == 0)
        #expect(store.notice?.message == "Pasted style to 4 tiles")
    }

    @Test("Bulk paste with an empty selection is refused")
    func bulkPasteWithEmptySelectionIsRefused() {
        let store = makeStore()
        store.copyStyle(from: store.inputs[0])

        store.pasteStyleOntoSelection()

        #expect(store.notice?.message == "No tiles selected")
    }

    @Test("A smaller replacement chassis drops selections for ports that vanished")
    func selectionIsPrunedOnTopologyChange() {
        let store = makeStore()
        store.toggleStyleSelection(
            TileStyleTarget(kind: .source, port: store.inputs[10].id)
        )
        store.toggleStyleSelection(
            TileStyleTarget(kind: .source, port: store.inputs[0].id)
        )
        #expect(store.styleSelectionCount == 2)

        store.applyProtocolEvent(.device(VideohubDeviceInfoUpdate(
            presence: .present,
            modelName: "Smaller",
            videoInputCount: 4,
            videoOutputCount: 4
        )))

        #expect(store.styleSelectionCount == 1)
        #expect(store.isStyleSelected(
            TileStyleTarget(kind: .source, port: PortNumber(protocolIndex: 0)!)
        ))
    }

    // MARK: - Helpers

    private func makeStore() -> RouterStore {
        let suiteName = "TileStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return RouterStore(
            defaults: defaults,
            customizationStore: CustomizationStore(fileURL: tempURL()),
            salvoStore: SalvoStore(fileURL: tempURL()),
            demoPortCount: 16
        )
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TileStyleTests.\(UUID().uuidString).json")
    }
}
