import Foundation
import Testing
@testable import VideohubOnSet

@Suite("Salvo model, storage, and firing", .serialized)
@MainActor
struct SalvoTests {
    // MARK: - Model

    @Test("A destination can only be driven by one source")
    func duplicateDestinationIsReplaced() {
        var salvo = Salvo(name: "ISO Record")
        salvo.setCrosspoint(output: port(1), input: port(1))
        salvo.setCrosspoint(output: port(1), input: port(5))

        #expect(salvo.crosspoints.count == 1)
        #expect(salvo.input(for: port(1)) == port(5))
    }

    @Test("Crosspoints stay ordered by destination regardless of entry order")
    func crosspointsAreOrdered() {
        var salvo = Salvo()
        for output in [4, 1, 3, 2] {
            salvo.setCrosspoint(output: port(output), input: port(1))
        }

        #expect(salvo.crosspoints.map(\.output) == [port(1), port(2), port(3), port(4)])
    }

    @Test("An empty salvo is never fireable")
    func emptySalvoIsNotFireable() {
        var salvo = Salvo(name: "Empty")
        #expect(!salvo.isFireable)

        salvo.setCrosspoint(output: port(1), input: port(2))
        #expect(salvo.isFireable)

        salvo.removeCrosspoint(output: port(1))
        #expect(!salvo.isFireable)
    }

    @Test("Ports beyond the connected router's topology are dropped")
    func topologyValidationDropsOutOfRangePorts() {
        var salvo = Salvo(name: "Authored on a big router")
        salvo.setCrosspoint(output: port(1), input: port(1))
        salvo.setCrosspoint(output: port(40), input: port(2))
        salvo.setCrosspoint(output: port(3), input: port(38))

        #expect(salvo.hasPortsOutsideTopology(inputCount: 8, outputCount: 8))

        let usable = salvo.validated(inputCount: 8, outputCount: 8)
        #expect(usable.crosspoints.count == 1)
        #expect(usable.input(for: port(1)) == port(1))
    }

    @Test("Names are trimmed and blank names fall back to a placeholder")
    func nameNormalization() {
        var salvo = Salvo(name: "   Wide Shot   ")
        #expect(salvo.name == "Wide Shot")

        salvo.setName("   ")
        #expect(salvo.name.isEmpty)
        #expect(salvo.displayName == "Untitled Salvo")
    }

    // MARK: - Storage

    @Test("Salvos round-trip through disk")
    func salvosPersist() {
        let url = tempURL()
        var salvo = Salvo(name: "ISO Record", accentColor: .orange, icon: .record)
        salvo.setCrosspoint(output: port(1), input: port(1))
        salvo.setCrosspoint(output: port(2), input: port(2))

        let store = SalvoStore(fileURL: url)
        #expect(store.save(salvo, forRouter: "192.168.1.50"))

        let reloaded = SalvoStore(fileURL: url)
        let loaded = reloaded.salvos(forRouter: "192.168.1.50")
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "ISO Record")
        #expect(loaded.first?.accentColor == .orange)
        #expect(loaded.first?.crosspoints.count == 2)
    }

    @Test("Salvos are isolated per router")
    func salvosAreScopedToRouter() {
        let store = SalvoStore(fileURL: tempURL())
        var a = Salvo(name: "Rack A macro")
        a.setCrosspoint(output: port(1), input: port(1))
        var b = Salvo(name: "Rack B macro")
        b.setCrosspoint(output: port(2), input: port(2))

        store.save(a, forRouter: "10.0.0.1")
        store.save(b, forRouter: "10.0.0.2")

        #expect(store.salvos(forRouter: "10.0.0.1").map(\.name) == ["Rack A macro"])
        #expect(store.salvos(forRouter: "10.0.0.2").map(\.name) == ["Rack B macro"])
        // Router identity is matched case-insensitively, as RouterStore lowercases it.
        #expect(store.salvos(forRouter: "10.0.0.1").count == 1)
    }

    @Test("Saving an existing id replaces rather than duplicates")
    func savingSameIdReplaces() {
        let store = SalvoStore(fileURL: tempURL())
        var salvo = Salvo(name: "First")
        salvo.setCrosspoint(output: port(1), input: port(1))
        store.save(salvo, forRouter: "r")

        salvo.setName("Renamed")
        store.save(salvo, forRouter: "r")

        let list = store.salvos(forRouter: "r")
        #expect(list.count == 1)
        #expect(list.first?.name == "Renamed")
    }

    @Test("A damaged salvo file does not prevent launch")
    func corruptFileIsSurvivable() {
        let url = tempURL()
        try? "{ not json at all".write(to: url, atomically: true, encoding: .utf8)

        let store = SalvoStore(fileURL: url)
        #expect(store.salvosByRouter.isEmpty)
        #expect(store.lastError != nil)
    }

    @Test("Deleting removes only the targeted salvo")
    func deleteRemovesOne() {
        let store = SalvoStore(fileURL: tempURL())
        var a = Salvo(name: "A"); a.setCrosspoint(output: port(1), input: port(1))
        var b = Salvo(name: "B"); b.setCrosspoint(output: port(2), input: port(2))
        store.save(a, forRouter: "r")
        store.save(b, forRouter: "r")

        #expect(store.delete(id: a.id, forRouter: "r"))
        #expect(store.salvos(forRouter: "r").map(\.name) == ["B"])
    }

    // MARK: - Firing

    @Test("A locked destination refuses the whole salvo")
    func lockedDestinationFailsClosed() {
        let store = makeStore()
        var salvo = Salvo(name: "Blocked")
        salvo.setCrosspoint(output: port(1), input: port(1))
        salvo.setCrosspoint(output: port(10), input: port(2))

        // Demo data locks output 10 to another controller.
        #expect(store.lockState(for: port(10)) == .lockedByOther)
        #expect(!store.canFire(salvo))
        #expect(store.fireDisabledReason(for: salvo)?.contains("locked") == true)

        store.fireSalvo(salvo)
        #expect(store.pendingSalvo == nil)
    }

    @Test("An unknown lock also refuses the salvo, matching TAKE")
    func unknownLockFailsClosed() {
        let store = makeStore()
        store.locks[port(2)] = nil

        var salvo = Salvo(name: "Unknown lock")
        salvo.setCrosspoint(output: port(2), input: port(1))

        #expect(store.lockState(for: port(2)) == .unknown)
        #expect(!store.canFire(salvo))
    }

    @Test("An empty salvo cannot be fired")
    func emptySalvoRefused() {
        let store = makeStore()
        let salvo = Salvo(name: "Nothing")

        #expect(store.fireDisabledReason(for: salvo) == "Salvo has no crosspoints")
    }

    @Test("A salvo confirms only once every crosspoint is reported")
    func salvoConfirmsOnlyWhenComplete() {
        let store = makeStore()
        var salvo = Salvo(name: "Wide")
        salvo.setCrosspoint(output: port(1), input: port(3))
        salvo.setCrosspoint(output: port(2), input: port(4))

        store.fireSalvo(salvo)
        #expect(store.pendingSalvo != nil)

        // First crosspoint lands: still outstanding, no success yet.
        store.applyProtocolEvent(.videoOutputRouting([0: 2]))
        #expect(store.pendingSalvo != nil)
        #expect(store.notice?.message.contains("confirmed") != true)

        // Second lands: now complete.
        store.applyProtocolEvent(.videoOutputRouting([1: 3]))
        #expect(store.pendingSalvo == nil)
        #expect(store.notice?.message == "Wide confirmed")
        #expect(store.route(for: port(1)) == port(3))
        #expect(store.route(for: port(2)) == port(4))
    }

    @Test("A crosspoint overridden by another controller is reported, not hidden")
    func conflictingCrosspointIsReported() {
        let store = makeStore()
        var salvo = Salvo(name: "Contested")
        salvo.setCrosspoint(output: port(1), input: port(3))

        store.fireSalvo(salvo)
        // Router reports a different source than the salvo asked for.
        store.applyProtocolEvent(.videoOutputRouting([0: 5]))

        #expect(store.pendingSalvo == nil)
        #expect(store.notice?.kind == .error)
        #expect(store.notice?.message.contains("changed by another controller") == true)
    }

    @Test("A NAK during a salvo clears it and names the salvo")
    func nakDuringSalvoIsReported() {
        let store = makeStore()
        var salvo = Salvo(name: "Rejected")
        salvo.setCrosspoint(output: port(1), input: port(3))

        store.fireSalvo(salvo)
        store.applyProtocolEvent(.nak)

        #expect(store.pendingSalvo == nil)
        #expect(store.notice?.message == "Rejected rejected")
    }

    @Test("A second salvo cannot start while one is running")
    func onlyOneSalvoAtATime() {
        let store = makeStore()
        var first = Salvo(name: "First")
        first.setCrosspoint(output: port(1), input: port(3))
        var second = Salvo(name: "Second")
        second.setCrosspoint(output: port(2), input: port(4))

        store.fireSalvo(first)
        #expect(store.pendingSalvo?.name == "First")
        #expect(store.fireDisabledReason(for: second) == "A salvo is already running")
    }

    @Test("Disconnecting abandons a running salvo")
    func disconnectClearsPendingSalvo() {
        let store = makeStore()
        var salvo = Salvo(name: "Interrupted")
        salvo.setCrosspoint(output: port(1), input: port(3))

        store.fireSalvo(salvo)
        #expect(store.pendingSalvo != nil)

        store.applyProtocolEvent(.device(VideohubDeviceInfoUpdate(presence: .absent)))
        #expect(store.pendingSalvo == nil)
    }

    // MARK: - Wire format

    @Test("A salvo is sent as one routing block, not one block per crosspoint")
    func salvoIsASingleRoutingBlock() {
        let command = VideohubClient.routingCommand(
            for: [(output: 0, input: 2), (output: 1, input: 3), (output: 4, input: 4)]
        )

        // A Videohub applies a whole block together; separate blocks would
        // show as a visible cascade of individual takes.
        #expect(command == "VIDEO OUTPUT ROUTING:\n0 2\n1 3\n4 4\n\n")
        #expect(command.components(separatedBy: "VIDEO OUTPUT ROUTING:").count == 2)
    }

    @Test("A single crosspoint still produces the original one-line block")
    func singleRouteFormatIsUnchanged() {
        let command = VideohubClient.routingCommand(for: [(output: 4, input: 2)])
        #expect(command == "VIDEO OUTPUT ROUTING:\n4 2\n\n")
    }

    @Test("A salvo command round-trips through the parser")
    func salvoCommandParsesBackToTheSameCrosspoints() {
        let command = VideohubClient.routingCommand(
            for: [(output: 0, input: 2), (output: 1, input: 3)]
        )
        var parser = VideohubProtocolParser()
        let events = parser.feed(Data(command.utf8))

        #expect(events == [.videoOutputRouting([0: 2, 1: 3])])
    }

    // MARK: - Helpers

    private func port(_ uiNumber: Int) -> PortNumber {
        PortNumber(uiNumber: uiNumber)!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvoTests.\(UUID().uuidString).json")
    }

    private func makeStore() -> RouterStore {
        let suiteName = "SalvoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return RouterStore(
            defaults: defaults,
            customizationStore: CustomizationStore(fileURL: tempURL()),
            salvoStore: SalvoStore(fileURL: tempURL()),
            demoPortCount: 16
        )
    }
}
