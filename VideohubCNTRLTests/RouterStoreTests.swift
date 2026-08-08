import Foundation
import Testing
@testable import VideohubCNTRL

@Suite("Router store state semantics", .serialized)
@MainActor
struct RouterStoreTests {
    @Test("ACK never changes the authoritative route")
    func ackDoesNotConfirmRoute() {
        let store = makeStore()
        let source = PortNumber(uiNumber: 3)!
        let destination = PortNumber(uiNumber: 5)!
        let originalRoute = store.route(for: destination)

        store.selectInput(source)
        store.selectOutput(destination)
        store.requestTake()
        #expect(store.pendingRoute != nil)

        store.applyProtocolEvent(.ack)
        #expect(store.route(for: destination) == originalRoute)
        #expect(store.pendingRoute != nil)

        store.applyProtocolEvent(.videoOutputRouting([4: 2]))
        #expect(store.route(for: destination) == source)
        #expect(store.pendingRoute == nil)
        #expect(store.notice?.message == "Route confirmed")
    }

    @Test("NAK clears pending without changing route")
    func nakRejectsPendingRoute() {
        let store = makeStore()
        let source = PortNumber(uiNumber: 3)!
        let destination = PortNumber(uiNumber: 5)!
        let originalRoute = store.route(for: destination)

        store.selectInput(source)
        store.selectOutput(destination)
        store.requestTake()
        store.applyProtocolEvent(.nak)

        #expect(store.pendingRoute == nil)
        #expect(store.route(for: destination) == originalRoute)
        #expect(store.notice?.message == "Route rejected")
    }

    @Test("Incremental labels, routes, and locks update live")
    func appliesIncrementalUpdates() {
        let store = makeStore()
        let source = PortNumber(uiNumber: 3)!
        let destination = PortNumber(uiNumber: 1)!

        store.applyProtocolEvent(.inputLabels([2: "Updated Input 3"]))
        store.applyProtocolEvent(.outputLabels([0: "Updated Output 1"]))
        store.applyProtocolEvent(.videoOutputRouting([0: 2]))
        store.applyProtocolEvent(.videoOutputLocks([0: .lockedByOther]))

        #expect(store.inputs.first(where: { $0.id == source })?.videohubLabel == "Updated Input 3")
        #expect(store.outputs.first(where: { $0.id == destination })?.videohubLabel == "Updated Output 1")
        #expect(store.route(for: destination) == source)
        #expect(store.lockState(for: destination) == .lockedByOther)

        store.selectInput(source)
        store.selectOutput(destination)
        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "Output locked by another controller")
    }

    @Test("Device topology is dynamic rather than fixed-size")
    func rebuildsDynamicTopology() {
        let store = makeStore()

        store.applyProtocolEvent(
            .device(
                VideohubDeviceInfoUpdate(
                    presence: .present,
                    modelName: "Router",
                    videoInputCount: 40,
                    videoOutputCount: 24
                )
            )
        )

        #expect(store.inputs.count == 40)
        #expect(store.outputs.count == 24)
        #expect(store.inputs.last?.id.uiNumber == 40)
        #expect(store.outputs.last?.id.uiNumber == 24)
    }

    @Test("A replacement device dump gates TAKE until fully synchronized")
    func replacementDeviceStartsNewSnapshot() {
        let store = makeLiveStore()
        store.connectionState = .connected
        store.device = VideohubDevice(
            presence: .present,
            modelName: "Previous Router",
            videoInputCount: 2,
            videoOutputCount: 2,
            protocolVersion: "2.3"
        )

        store.applyProtocolEvent(
            .device(
                VideohubDeviceInfoUpdate(
                    presence: .present,
                    modelName: "Replacement Router",
                    videoInputCount: 2,
                    videoOutputCount: 2
                )
            )
        )
        #expect(store.connectionState == .connecting)
        #expect(store.device.protocolVersion == "2.3")

        store.applyProtocolEvent(.inputLabels([0: "Input 1", 1: "Input 2"]))
        store.applyProtocolEvent(.outputLabels([0: "Output 1", 1: "Output 2"]))
        store.applyProtocolEvent(.videoOutputRouting([0: 0, 1: 1]))
        #expect(store.connectionState == .connecting)

        store.applyProtocolEvent(.videoOutputLocks([0: .unlocked, 1: .unlocked]))
        #expect(store.connectionState == .connected)
        #expect(store.device.modelName == "Replacement Router")
    }

    @Test("Initial sync fails closed until every output lock is recognized")
    func initialSyncRequiresKnownLockCoverage() {
        let store = makeLiveStore()
        let secondOutput = PortNumber(protocolIndex: 1)!
        store.connectionState = .connecting

        store.applyProtocolEvent(
            .device(
                VideohubDeviceInfoUpdate(
                    presence: .present,
                    modelName: "Router",
                    videoInputCount: 2,
                    videoOutputCount: 2
                )
            )
        )
        store.applyProtocolEvent(.inputLabels([0: "Input 1", 1: "Input 2"]))
        store.applyProtocolEvent(.outputLabels([0: "Output 1", 1: "Output 2"]))
        store.applyProtocolEvent(.videoOutputRouting([0: 0, 1: 1]))
        store.applyProtocolEvent(.videoOutputLocks([0: .unlocked]))

        #expect(store.connectionState == .connecting)
        #expect(store.lockState(for: secondOutput) == .unknown)
        #expect(store.lockState(for: secondOutput).preventsRouting)

        store.applyProtocolEvent(.videoOutputLocks([1: .unknown("future")]))
        #expect(store.connectionState == .connecting)
        #expect(store.lockState(for: secondOutput) == .unknown)

        store.applyProtocolEvent(.videoOutputLocks([1: .owned]))
        #expect(store.connectionState == .connected)
        #expect(store.lockState(for: secondOutput) == .ownedByThisClient)
    }

    @Test("Missing runtime lock state disables TAKE")
    func missingRuntimeLockFailsClosed() {
        let store = makeStore()
        let source = PortNumber(protocolIndex: 0)!
        let destination = PortNumber(protocolIndex: 0)!
        store.locks[destination] = nil

        store.selectInput(source)
        store.selectOutput(destination)

        #expect(!store.canTake)
        #expect(store.takeDisabledReason == "Output lock status unavailable")
    }

    @Test("Remote label changes respect local overrides and reset back to the live label")
    func namingOverrideAndResetTrackRemoteLabels() {
        let store = makeStore()
        let sourceID = PortNumber(protocolIndex: 2)!
        let source = store.inputs.first(where: { $0.id == sourceID })!

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Local Source Name",
                accentColor: .purple,
                icon: .record,
                group: "Stage Left"
            ),
            for: source
        )
        store.applyProtocolEvent(.inputLabels([2: "Remote Label One"]))

        var presentation = store.presentation(for: sourceWithID(sourceID, in: store))
        #expect(presentation.displayName == "Local Source Name")
        #expect(presentation.accentColor == .purple)
        #expect(presentation.icon == .record)
        #expect(presentation.group == "Stage Left")

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: nil,
                accentColor: .purple,
                icon: .record,
                group: "Stage Left"
            ),
            for: sourceWithID(sourceID, in: store)
        )
        presentation = store.presentation(for: sourceWithID(sourceID, in: store))
        #expect(presentation.displayName == "Remote Label One")

        store.applyProtocolEvent(.inputLabels([2: "Remote Label Two"]))
        presentation = store.presentation(for: sourceWithID(sourceID, in: store))
        #expect(presentation.displayName == "Remote Label Two")
        #expect(presentation.accentColor == .purple)
        #expect(presentation.icon == .record)
        #expect(presentation.group == "Stage Left")
    }

    @Test("Output names independently follow live labels, local overrides, and reset")
    func outputNamingOverrideAndResetTrackRemoteLabels() {
        let store = makeStore()
        let outputID = PortNumber(protocolIndex: 1)!

        store.applyProtocolEvent(.outputLabels([1: "Remote Output One"]))
        var output = store.outputs.first(where: { $0.id == outputID })!
        #expect(store.presentation(for: output).displayName == "Remote Output One")

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Local Output Name",
                accentColor: .cyan,
                icon: .multiview,
                group: "Review"
            ),
            for: output
        )
        store.applyProtocolEvent(.outputLabels([1: "Remote Output Two"]))
        output = store.outputs.first(where: { $0.id == outputID })!

        var presentation = store.presentation(for: output)
        #expect(presentation.displayName == "Local Output Name")
        #expect(presentation.accentColor == .cyan)
        #expect(presentation.icon == .multiview)
        #expect(presentation.group == "Review")

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: nil,
                accentColor: .cyan,
                icon: .multiview,
                group: "Review"
            ),
            for: output
        )
        presentation = store.presentation(for: output)
        #expect(presentation.displayName == "Remote Output Two")
        #expect(presentation.accentColor == .cyan)
        #expect(presentation.icon == .multiview)
        #expect(presentation.group == "Review")
    }

    @Test("A destination route badge resolves the routed source presentation")
    func routedSourcePresentationKeepsSourceAccentAndName() {
        let store = makeStore()
        let sourceID = PortNumber(protocolIndex: 2)!
        let outputID = PortNumber(protocolIndex: 0)!
        let source = sourceWithID(sourceID, in: store)
        let output = store.outputs.first(where: { $0.id == outputID })!

        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Routed Source",
                accentColor: .pink,
                icon: .graphics,
                group: "Custom Group"
            ),
            for: source
        )
        store.saveCustomization(
            PortCustomization(
                displayNameOverride: "Destination",
                accentColor: .green,
                icon: .monitor
            ),
            for: output
        )
        store.applyProtocolEvent(.videoOutputRouting([0: 2]))

        let routedSource = store.routedInput(for: outputID)
        #expect(routedSource?.id == sourceID)
        let routedPresentation = routedSource.map { store.presentation(for: $0) }
        #expect(routedPresentation?.displayName == "Routed Source")
        #expect(routedPresentation?.accentColor == .pink)
        #expect(store.presentation(for: output).accentColor == .green)
    }

    @Test("Customization keys remain isolated by router, direction, and physical port")
    func customizationKeysAreProperlyScoped() {
        let store = makeLiveStore()
        store.host = "  ROUTER-A.LOCAL  "
        store.applyProtocolEvent(
            .device(
                VideohubDeviceInfoUpdate(
                    presence: .present,
                    videoInputCount: 2,
                    videoOutputCount: 2
                )
            )
        )

        let sourceOne = store.inputs[0]
        let sourceTwo = store.inputs[1]
        let destinationOne = store.outputs[0]
        let sourceOneKey = store.customizationKey(for: sourceOne)
        let sourceTwoKey = store.customizationKey(for: sourceTwo)
        let destinationOneKey = store.customizationKey(for: destinationOne)

        #expect(sourceOneKey.routerIdentity == "router-a.local")
        #expect(sourceOneKey.protocolPortIndex == 0)
        #expect(sourceTwoKey.protocolPortIndex == 1)
        #expect(sourceOneKey != sourceTwoKey)
        #expect(sourceOneKey != destinationOneKey)

        store.host = "router-b.local"
        let routerBSourceOneKey = store.customizationKey(for: sourceOne)
        #expect(routerBSourceOneKey.routerIdentity == "router-b.local")
        #expect(routerBSourceOneKey != sourceOneKey)
    }

    private func makeStore() -> RouterStore {
        makeStore(demoPortCount: 8)
    }

    private func makeLiveStore() -> RouterStore {
        makeStore(demoPortCount: nil)
    }

    private func makeStore(demoPortCount: Int?) -> RouterStore {
        let suiteName = "RouterStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let customizationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName).json")
        return RouterStore(
            defaults: defaults,
            customizationStore: CustomizationStore(fileURL: customizationURL),
            demoPortCount: demoPortCount
        )
    }

    private func sourceWithID(_ id: PortNumber, in store: RouterStore) -> VideoInput {
        store.inputs.first(where: { $0.id == id })!
    }
}
