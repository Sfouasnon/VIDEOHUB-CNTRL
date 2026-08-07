import AppKit
import Foundation
import Testing
@testable import VideohubOnSet

@Suite("Port presentation choices")
struct PortPresentationTests {
    @Test("Every configurable accent survives Codable", arguments: PortAccentColor.allCases)
    func everyAccentRoundTrips(_ accent: PortAccentColor) throws {
        let encoded = try JSONEncoder().encode(accent)
        let decoded = try JSONDecoder().decode(PortAccentColor.self, from: encoded)

        #expect(decoded == accent)
        #expect(!accent.displayName.isEmpty)
    }

    @Test("Every configurable icon survives Codable and resolves to an SF Symbol", arguments: VideohubIcon.allCases)
    func everyIconRoundTripsAndResolves(_ icon: VideohubIcon) throws {
        let encoded = try JSONEncoder().encode(icon)
        let decoded = try JSONDecoder().decode(VideohubIcon.self, from: encoded)

        #expect(decoded == icon)
        #expect(!icon.displayName.isEmpty)
        #expect(
            NSImage(
                systemSymbolName: icon.systemImageName,
                accessibilityDescription: icon.displayName
            ) != nil,
            "Missing SF Symbol for \(icon.displayName): \(icon.systemImageName)"
        )
    }

    @Test("Fallback presentation never infers names, groups, colors, or icons from labels")
    func fallbackIsNeutralAndIdenticalForBothPortKinds() {
        let port = PortNumber(uiNumber: 3)!
        let source = PortPresentationResolver.fallback(
            kind: .source,
            port: port,
            videohubLabel: "Camera Playback Graphics"
        )
        let destination = PortPresentationResolver.fallback(
            kind: .destination,
            port: port,
            videohubLabel: "Monitor Village Return"
        )

        #expect(source == destination)
        #expect(source.displayNameOverride == nil)
        #expect(source.group == nil)
        #expect(source.accentColor == .blue)
        #expect(source.icon == .genericVideo)
    }

    @Test("Display name follows live labels until a local override is configured")
    func displayNameUsesLiveLabelOrOverride() {
        var customization = PortCustomization()

        #expect(customization.displayName(videohubLabel: "Live label A") == "Live label A")
        #expect(customization.displayName(videohubLabel: "Live label B") == "Live label B")

        customization.setDisplayNameOverride("  Local override  ")
        #expect(customization.displayName(videohubLabel: "Live label C") == "Local override")

        customization.resetToVideohubLabel()
        #expect(customization.displayName(videohubLabel: "Live label D") == "Live label D")
    }

    @Test("Group edits normalize whitespace without assigning a semantic default")
    func groupNormalization() {
        var customization = PortCustomization(group: "  Stage Left  ")
        #expect(customization.group == "Stage Left")

        customization.setGroup("   \n  ")
        #expect(customization.group == nil)
    }
}
