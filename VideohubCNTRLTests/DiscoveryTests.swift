import Foundation
import Testing
@testable import VideohubCNTRL

@Suite("Videohub discovery and host entry", .serialized)
@MainActor
struct DiscoveryTests {
    // MARK: - Host entry

    @Test("A live store starts offline so the host field is never gated shut")
    func liveStoreStartsOffline() {
        let store = makeLiveStore()

        // The regression this guards: the host field used to be disabled
        // whenever the state was not `.offline`, and automatic reconnect kept
        // the store oscillating through `.connecting`, so the field was
        // unusable in practice.
        #expect(store.connectionState == .offline)
        #expect(!store.hasUnappliedHostChange)
    }

    @Test("Typing a new host while offline needs no reconnect prompt")
    func offlineHostEditNeedsNoPrompt() {
        let store = makeLiveStore()
        store.host = "10.0.0.9"

        #expect(!store.hasUnappliedHostChange)
    }

    @Test("Host changes are persisted to defaults immediately")
    func hostChangePersists() {
        let suiteName = "DiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = RouterStore(defaults: defaults, customizationStore: makeCustomizationStore())

        store.host = "172.16.4.20"

        #expect(defaults.string(forKey: "videohub.host") == "172.16.4.20")
    }

    @Test("Blank host is rejected with an operator notice")
    func blankHostIsRejected() {
        let store = makeLiveStore()
        store.host = "   "
        store.connect()

        #expect(store.connectionState == .offline)
        #expect(store.notice?.message == "Enter a Videohub host or IP address")
    }

    // MARK: - Discovery request counting

    @Test("Discovery survives one of two owners going away")
    func discoveryIsReferenceCounted() {
        let store = makeStore()

        store.startDiscovery()
        store.startDiscovery()
        #expect(store.isDiscovering)

        // Closing Settings must not stop the browse the action panel needs.
        store.stopDiscovery()
        #expect(store.isDiscovering)

        store.stopDiscovery()
        #expect(!store.isDiscovering)
    }

    @Test("Unbalanced stop calls do not drive the count negative")
    func unbalancedStopIsSafe() {
        let store = makeStore()

        store.stopDiscovery()
        store.stopDiscovery()
        store.startDiscovery()

        #expect(store.isDiscovering)

        store.stopDiscovery()
        #expect(!store.isDiscovering)
    }

    // MARK: - Selecting a discovered device

    @Test("Choosing a discovered device adopts its address")
    func selectingDiscoveredDeviceSetsHost() {
        let store = makeLiveStore()
        let device = DiscoveredVideohub(
            id: "a",
            serviceName: "Rack A",
            serviceType: "_videohub._tcp",
            host: "192.168.1.42",
            modelName: "Blackmagic Smart Videohub 20 x 20",
            isReachable: true
        )

        store.connect(to: device)

        #expect(store.host == "192.168.1.42")
    }

    @Test("An unresolved device cannot be connected to")
    func unresolvedDeviceIsNotConnectable() {
        let store = makeLiveStore()
        let device = DiscoveredVideohub(
            id: "b",
            serviceName: "Rack B",
            serviceType: "_blackmagic._tcp"
        )
        let originalHost = store.host

        #expect(!device.isConnectable)

        store.connect(to: device)

        #expect(store.host == originalHost)
        #expect(store.notice?.message == "Still resolving Rack B")
    }

    // MARK: - Presentation

    @Test("Model name is appended only when it adds information")
    func displayNameAvoidsRedundancy() {
        var device = DiscoveredVideohub(
            id: "c",
            serviceName: "Smart Videohub",
            serviceType: "_videohub._tcp",
            host: "10.1.1.5"
        )
        #expect(device.displayName == "Smart Videohub")

        device.modelName = "Smart Videohub"
        #expect(device.displayName == "Smart Videohub")

        device.modelName = "Blackmagic Smart Videohub 40 x 40"
        #expect(device.displayName == "Smart Videohub — Blackmagic Smart Videohub 40 x 40")
    }

    @Test("Subtitle hides the default control port but shows an override")
    func subtitleShowsNonDefaultPort() {
        var device = DiscoveredVideohub(
            id: "d",
            serviceName: "Rack D",
            serviceType: "_videohub._tcp"
        )
        #expect(device.subtitle == "Resolving…")

        device.host = "10.1.1.6"
        #expect(device.subtitle == "10.1.1.6")

        device.port = 9991
        #expect(device.subtitle == "10.1.1.6:9991")
    }

    @Test("Both Blackmagic service types are browsed")
    func browsesBothServiceTypes() {
        // Blackmagic's own Videohub Control binary references both, and some
        // firmware only advertises one of them.
        #expect(VideohubDiscovery.serviceTypes.contains("_videohub._tcp"))
        #expect(VideohubDiscovery.serviceTypes.contains("_blackmagic._tcp"))
    }

    // MARK: - Helpers

    private func makeStore() -> RouterStore {
        makeStore(demoPortCount: 8)
    }

    private func makeLiveStore() -> RouterStore {
        makeStore(demoPortCount: nil)
    }

    private func makeStore(demoPortCount: Int?) -> RouterStore {
        let suiteName = "DiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return RouterStore(
            defaults: defaults,
            customizationStore: makeCustomizationStore(),
            demoPortCount: demoPortCount
        )
    }

    private func makeCustomizationStore() -> CustomizationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoveryTests.\(UUID().uuidString).json")
        return CustomizationStore(fileURL: url)
    }
}
