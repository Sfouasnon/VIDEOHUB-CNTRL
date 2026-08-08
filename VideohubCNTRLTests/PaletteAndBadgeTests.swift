import AppKit
import Foundation
import Testing
@testable import VideohubCNTRL

@Suite("Palette, pipeline icons, and format badges", .serialized)
@MainActor
struct PaletteAndBadgeTests {
    // MARK: - Icons

    @Test("Every icon resolves to a real SF Symbol on this macOS")
    func everyIconResolves() {
        for icon in VideohubIcon.allCases {
            let image = NSImage(
                systemSymbolName: icon.systemImageName,
                accessibilityDescription: nil
            )
            #expect(image != nil, "\(icon.rawValue) -> \(icon.systemImageName) did not resolve")
        }
    }

    @Test("The pipeline icons requested for virtual production all exist")
    func pipelineIconsArePresent() {
        let expected: Set<VideohubIcon> = [
            .scopes, .motionCapture, .retarget, .simulcam, .engine, .laptop, .converter
        ]
        #expect(expected.isSubset(of: Set(VideohubIcon.allCases)))
    }

    @Test("Every icon has a distinct name and symbol")
    func iconsAreDistinct() {
        let names = VideohubIcon.allCases.map(\.displayName)
        let symbols = VideohubIcon.allCases.map(\.systemImageName)
        #expect(Set(names).count == names.count)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("Every icon lands in exactly one filter chip")
    func everyIconMapsToOneFilter() {
        let chips: [SourceFilter] = [.cameras, .playback, .graphics, .returns, .village, .utility]
        for icon in VideohubIcon.allCases {
            let presentation = PortPresentation(
                displayName: "Source",
                group: nil,
                accentColor: .blue,
                icon: icon
            )
            let matches = chips.filter { $0.matches(presentation) }
            #expect(matches.count == 1, "\(icon.rawValue) matched \(matches.count) chips")
        }
    }

    // MARK: - Colours

    @Test("Every colour round-trips through Codable without key collisions")
    func everyColourPersists() throws {
        let raws = PortAccentColor.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)

        for colour in PortAccentColor.allCases {
            let data = try JSONEncoder().encode(
                PortCustomization(accentColor: colour, icon: .genericVideo)
            )
            let decoded = try JSONDecoder().decode(PortCustomization.self, from: data)
            #expect(decoded.accentColor == colour)
        }
    }

    @Test("The original eight colours keep their persisted names")
    func originalColourKeysAreStable() {
        // Renaming any of these would silently reset saved tiles to the default.
        let original = ["blue", "cyan", "green", "yellow", "orange", "red", "purple", "pink"]
        let raws = Set(PortAccentColor.allCases.map(\.rawValue))
        for key in original {
            #expect(raws.contains(key), "colour key '\(key)' disappeared")
        }
    }

    @Test("Every colour has a display name")
    func everyColourHasAName() {
        for colour in PortAccentColor.allCases {
            #expect(!colour.displayName.isEmpty)
        }
    }

    // MARK: - Format badge

    @Test("A badge persists with the rest of the tile customization")
    func badgePersists() throws {
        let customization = PortCustomization(
            displayNameOverride: "Cam 1",
            accentColor: .red,
            icon: .camera,
            group: "Cameras",
            formatBadge: .uhd
        )
        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(PortCustomization.self, from: data)

        #expect(decoded.formatBadge == .uhd)
    }

    @Test("Customizations saved before badges existed still decode")
    func legacyCustomizationDecodes() throws {
        // A file written by an earlier build has no formatBadge key at all.
        let legacy = """
        {"accentColor":"blue","icon":"camera","group":"Cameras"}
        """
        let decoded = try JSONDecoder().decode(
            PortCustomization.self,
            from: Data(legacy.utf8)
        )

        #expect(decoded.formatBadge == nil)
        #expect(decoded.icon == .camera)
    }

    @Test("A copied style never carries the badge between tiles")
    func badgeIsNotPartOfAStyle() {
        let donor = PortCustomization(
            accentColor: .orange,
            icon: .simulcam,
            group: "Plates",
            formatBadge: .uhd
        )
        let recipient = PortCustomization(
            displayNameOverride: "Cam 2",
            accentColor: .blue,
            icon: .monitor,
            formatBadge: .hd
        )

        let pasted = TileStyle(donor).applied(to: recipient)

        // Colour, icon, and group travel; format describes the individual
        // signal and must stay put.
        #expect(pasted.accentColor == .orange)
        #expect(pasted.icon == .simulcam)
        #expect(pasted.group == "Plates")
        #expect(pasted.formatBadge == .hd)
        #expect(pasted.displayNameOverride == "Cam 2")
    }

    @Test("A bulk paste leaves every recipient's badge untouched")
    func bulkPasteDoesNotRewriteBadges() {
        let store = makeStore()
        let donor = store.inputs[0]
        store.saveCustomization(
            PortCustomization(accentColor: .amber, icon: .engine, formatBadge: .uhd8K),
            for: donor
        )
        store.saveCustomization(
            PortCustomization(accentColor: .blue, icon: .monitor, formatBadge: .hd),
            for: store.inputs[1]
        )

        store.copyStyle(from: donor)
        store.toggleStyleSelection(
            TileStyleTarget(kind: .source, port: store.inputs[1].id)
        )
        store.pasteStyleOntoSelection()

        let presentation = store.presentation(for: store.inputs[1])
        #expect(presentation.accentColor == .amber)
        #expect(presentation.icon == .engine)
        #expect(presentation.formatBadge == .hd)
    }

    @Test("Badge display text stays short enough for a tile corner")
    func badgeTextIsCompact() {
        for badge in SignalFormatBadge.allCases {
            #expect(badge.badgeText.count <= 3)
            #expect(!badge.badgeText.isEmpty)
        }
    }

    // MARK: - Helpers

    private func makeStore() -> RouterStore {
        let suiteName = "PaletteAndBadgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return RouterStore(
            defaults: defaults,
            customizationStore: CustomizationStore(fileURL: tempURL()),
            salvoStore: SalvoStore(fileURL: tempURL()),
            demoPortCount: 8
        )
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAndBadgeTests.\(UUID().uuidString).json")
    }
}
