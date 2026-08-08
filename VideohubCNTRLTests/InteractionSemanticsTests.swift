import AppKit
import Foundation
import Testing
@testable import VideohubCNTRL

@Suite("Operator interaction semantics", .serialized)
@MainActor
struct InteractionSemanticsTests {
    @Test("Source and destination selection never changes the current route")
    func selectionIsIndependentFromRouting() {
        let store = makeDemoStore()
        let source = PortNumber(uiNumber: 7)!
        let destination = PortNumber(uiNumber: 4)!
        let originalRoute = store.route(for: destination)

        store.selectInput(source)
        store.selectOutput(destination)

        #expect(store.selectedInputID == source)
        #expect(store.selectedOutputID == destination)
        #expect(store.route(for: destination) == originalRoute)
        #expect(store.pendingRoute == nil)
    }

    @Test("TAKE enables only for a complete, unlocked, non-pending route")
    func takeGating() {
        let store = makeDemoStore()
        let source = PortNumber(uiNumber: 2)!
        let destination = PortNumber(uiNumber: 3)!

        store.clearSelection()
        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "Select a source")

        store.selectInput(source)
        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "Select a destination")

        store.selectOutput(destination)
        #expect(store.canTake)

        store.locks[destination] = .lockedByOther
        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "Output locked by another controller")

        store.locks[destination] = .unlocked
        store.requestTake()
        #expect(store.pendingRoute?.route == Route(output: destination, input: source))
        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "A route is already pending")
    }

    @Test("Confirmation can cancel or deliberately start a pending route")
    func takeConfirmation() {
        let store = makeDemoStore()
        let source = PortNumber(uiNumber: 2)!
        let destination = PortNumber(uiNumber: 3)!
        store.selectInput(source)
        store.selectOutput(destination)
        store.confirmBeforeTake = true

        store.requestTake()
        #expect(store.isTakeConfirmationPresented)
        #expect(store.pendingRoute == nil)

        store.cancelTakeConfirmation()
        #expect(!store.isTakeConfirmationPresented)
        #expect(store.pendingRoute == nil)

        store.requestTake()
        store.confirmTake()
        #expect(!store.isTakeConfirmationPresented)
        #expect(store.pendingRoute?.route == Route(output: destination, input: source))
    }

    @Test("Confirmation reports when the selected route becomes invalid")
    func invalidatedTakeConfirmation() {
        let store = makeDemoStore()
        let source = PortNumber(uiNumber: 2)!
        let destination = PortNumber(uiNumber: 3)!
        store.selectInput(source)
        store.selectOutput(destination)
        store.confirmBeforeTake = true

        store.requestTake()
        #expect(store.isTakeConfirmationPresented)

        store.locks[destination] = .lockedByOther
        store.confirmTake()

        #expect(!store.isTakeConfirmationPresented)
        #expect(store.pendingRoute == nil)
        #expect(store.notice?.message == "Output locked by another controller")
    }

    @Test("Clear removes both selections and dismisses TAKE confirmation")
    func clearSelection() {
        let store = makeDemoStore()
        store.confirmBeforeTake = true
        store.requestTake()
        #expect(store.isTakeConfirmationPresented)

        store.clearSelection()

        #expect(store.selectedInputID == nil)
        #expect(store.selectedOutputID == nil)
        #expect(!store.isTakeConfirmationPresented)
        #expect(!store.canTake)
    }

    @Test("Local tile presentation remains configurable while live labels stay authoritative defaults")
    func customizationAndLiveNaming() {
        let store = makeDemoStore()
        let input = store.inputs[0]
        let key = store.customizationKey(for: input)

        store.applyProtocolEvent(.inputLabels([input.id.protocolIndex: "Live Camera Label"]))
        let updatedInput = store.inputs[0]
        #expect(store.presentation(for: updatedInput).displayName == "Live Camera Label")

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Local Operator Name",
                accentColor: .pink,
                icon: .camera,
                group: "Configured Group"
            ),
            for: updatedInput
        )
        let customized = store.presentation(for: store.inputs[0])
        #expect(customized.displayName == "Local Operator Name")
        #expect(customized.accentColor == .pink)
        #expect(customized.icon == .camera)
        #expect(customized.group == "Configured Group")

        store.applyProtocolEvent(.inputLabels([input.id.protocolIndex: "Changed Router Label"]))
        #expect(store.presentation(for: store.inputs[0]).displayName == "Local Operator Name")

        #expect(store.customizationStore.resetNameOverride(for: key))
        #expect(store.presentation(for: store.inputs[0]).displayName == "Changed Router Label")
    }

    @Test("Host and routing preferences persist through relaunch")
    func settingsPersistence() {
        let fixture = makeFixture()
        fixture.store.host = "router.local"
        fixture.store.reconnectAutomatically = false
        fixture.store.confirmBeforeTake = true

        let reloaded = RouterStore(
            defaults: fixture.defaults,
            customizationStore: CustomizationStore(fileURL: fixture.customizationURL),
            demoPortCount: 8
        )

        #expect(reloaded.host == "router.local")
        #expect(!reloaded.reconnectAutomatically)
        #expect(reloaded.confirmBeforeTake)
    }

    @Test("Every icon offered by customization resolves to a macOS SF Symbol")
    func iconSymbolsExist() {
        for icon in VideohubIcon.allCases {
            #expect(
                NSImage(systemSymbolName: icon.systemImageName, accessibilityDescription: nil) != nil,
                "Missing SF Symbol for \(icon.displayName): \(icon.systemImageName)"
            )
        }
    }

    private func makeDemoStore() -> RouterStore {
        makeFixture().store
    }

    private func makeFixture() -> (
        store: RouterStore,
        defaults: UserDefaults,
        customizationURL: URL
    ) {
        let fixtureID = UUID().uuidString
        let suiteName = "InteractionSemanticsTests.\(fixtureID)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let customizationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).json")
        let store = RouterStore(
            defaults: defaults,
            customizationStore: CustomizationStore(fileURL: customizationURL),
            demoPortCount: 8
        )
        return (store, defaults, customizationURL)
    }
}
