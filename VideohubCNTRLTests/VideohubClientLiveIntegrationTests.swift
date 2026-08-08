#if SWIFT_PACKAGE
import Foundation
import Network
import Testing
@testable import VideohubCNTRL

@Suite("Videohub live TCP integration", .serialized)
struct VideohubClientLiveIntegrationTests {
    @Test("Live labels, routes, locks, ACK, NAK, and reconnect use the streaming TCP path")
    func liveSessionLifecycle() async throws {
        let server = try LiveVideohubServer()
        let port = try await server.start()
        defer { server.stop() }

        let recorder = LiveVideohubRecorder()
        let client = VideohubClient(
            stateHandler: { state, sessionID in
                Task { await recorder.record(state: state, sessionID: sessionID) }
            },
            eventHandler: { event, sessionID in
                Task { await recorder.record(event: event, sessionID: sessionID) }
            },
            errorHandler: { message in
                Task { await recorder.record(error: message) }
            }
        )
        defer { client.disconnect() }

        client.connect(host: "127.0.0.1", port: port, reconnectAutomatically: true)

        try await eventually("initial TCP connection") {
            await recorder.states().contains(where: { $0.state == .connected })
        }
        try await eventually("fragmented input label block") {
            await recorder.events().contains(where: { recorded in
                guard case let .inputLabels(labels) = recorded.event else { return false }
                return labels[0] == "Live Source One" && labels[2] == "Live Source Three"
            })
        }
        try await eventually("fragmented output label block") {
            await recorder.events().contains(where: { recorded in
                guard case let .outputLabels(labels) = recorded.event else { return false }
                return labels[0] == "Live Destination One" && labels[1] == "Live Destination Two"
            })
        }
        try await eventually("initial route and lock blocks") {
            let events = await recorder.events()
            let routed = events.contains(where: { recorded in
                guard case let .videoOutputRouting(routes) = recorded.event else { return false }
                return routes[0] == 0 && routes[1] == 1
            })
            let locked = events.contains(where: { recorded in
                guard case let .videoOutputLocks(locks) = recorded.event else { return false }
                return locks[0] == .unlocked && locks[1] == .lockedByOther
            })
            return routed && locked
        }

        server.push(
            "INPUT LABELS:\n1 Remotely Renamed Source\n\n"
                + "OUTPUT LABELS:\n0 Remotely Renamed Destination\n\n"
                + "VIDEO OUTPUT ROUTING:\n1 2\n\n"
                + "VIDEO OUTPUT LOCKS:\n1 U\n\n"
        )

        try await eventually("incremental live label, route, and lock updates") {
            let events = await recorder.events()
            let inputUpdated = events.contains(where: { recorded in
                guard case let .inputLabels(labels) = recorded.event else { return false }
                return labels[1] == "Remotely Renamed Source"
            })
            let outputUpdated = events.contains(where: { recorded in
                guard case let .outputLabels(labels) = recorded.event else { return false }
                return labels[0] == "Remotely Renamed Destination"
            })
            let routeUpdated = events.contains(where: { recorded in
                guard case let .videoOutputRouting(routes) = recorded.event else { return false }
                return routes[1] == 2
            })
            let lockUpdated = events.contains(where: { recorded in
                guard case let .videoOutputLocks(locks) = recorded.event else { return false }
                return locks[1] == .unlocked
            })
            return inputUpdated && outputUpdated && routeUpdated && lockUpdated
        }

        let acceptedStart = await recorder.events().count
        client.sendRoute(outputIndex: 0, inputIndex: 2)

        try await eventually("ACK followed by authoritative routing status") {
            let events = await recorder.events()
            guard events.count > acceptedStart else { return false }
            let acceptedEvents = events[acceptedStart...]
            let ackIndex = acceptedEvents.firstIndex(where: { $0.event == .ack })
            let routeIndex = acceptedEvents.firstIndex(where: { recorded in
                guard case let .videoOutputRouting(routes) = recorded.event else { return false }
                return routes[0] == 2
            })
            guard let ackIndex, let routeIndex else { return false }
            return ackIndex < routeIndex
        }

        server.rejectNextRoute()
        let rejectedStart = await recorder.events().count
        client.sendRoute(outputIndex: 0, inputIndex: 1)

        try await eventually("NAK for a rejected route") {
            let events = await recorder.events()
            guard events.count > rejectedStart else { return false }
            return events[rejectedStart...].contains(where: { $0.event == .nak })
        }
        try await Task.sleep(for: .milliseconds(200))
        let rejectedEvents = await recorder.events()
        #expect(
            !rejectedEvents[rejectedStart...].contains(where: { recorded in
                guard case let .videoOutputRouting(routes) = recorded.event else { return false }
                return routes[0] == 1
            })
        )

        let statesBeforeDrop = await recorder.states().count
        let eventsBeforeDrop = await recorder.events().count
        server.dropConnection()

        try await eventually("offline state after network loss") {
            let states = await recorder.states()
            guard states.count > statesBeforeDrop else { return false }
            return states[statesBeforeDrop...].contains(where: { $0.state == .offline })
        }
        try await eventually("automatic reconnect", timeout: .seconds(6)) {
            let states = await recorder.states()
            let reconnected = states[statesBeforeDrop...].contains(where: { $0.state == .connected })
            return server.connectionCount() >= 2 && reconnected
        }
        try await eventually("fresh state dump after reconnect", timeout: .seconds(6)) {
            let events = await recorder.events()
            guard events.count > eventsBeforeDrop else { return false }
            return events[eventsBeforeDrop...].contains(where: { recorded in
                guard case let .outputLabels(labels) = recorded.event else { return false }
                return labels[1] == "Live Destination Two"
            })
        }
    }

    private func eventually(
        _ description: String,
        timeout: Duration = .seconds(4),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        throw LiveVideohubTestError.timeout(description)
    }
}

private enum LiveVideohubTestError: Error, CustomStringConvertible {
    case timeout(String)
    case listenerFailed(String)

    var description: String {
        switch self {
        case let .timeout(description):
            return "Timed out waiting for \(description)"
        case let .listenerFailed(description):
            return "Mock listener failed: \(description)"
        }
    }
}

private actor LiveVideohubRecorder {
    struct RecordedState: Sendable {
        let state: VideohubTransportState
        let sessionID: VideohubClient.SessionID?
    }

    struct RecordedEvent: Sendable {
        let event: VideohubProtocolEvent
        let sessionID: VideohubClient.SessionID
    }

    private var recordedStates: [RecordedState] = []
    private var recordedEvents: [RecordedEvent] = []
    private var recordedErrors: [String] = []

    func record(state: VideohubTransportState, sessionID: VideohubClient.SessionID?) {
        recordedStates.append(RecordedState(state: state, sessionID: sessionID))
    }

    func record(event: VideohubProtocolEvent, sessionID: VideohubClient.SessionID) {
        recordedEvents.append(RecordedEvent(event: event, sessionID: sessionID))
    }

    func record(error: String) {
        recordedErrors.append(error)
    }

    func states() -> [RecordedState] {
        recordedStates
    }

    func events() -> [RecordedEvent] {
        recordedEvents
    }
}

private final class LiveVideohubServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.videohubcntrl.tests.live-server")
    private let listener: NWListener
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var activeConnection: NWConnection?
    private var receiveBuffer = Data()
    private var acceptedConnections = 0
    private var shouldRejectNextRoute = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handle(listenerState: state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.sync {
            activeConnection?.stateUpdateHandler = nil
            activeConnection?.cancel()
            activeConnection = nil
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
    }

    func push(_ text: String) {
        queue.async {
            guard let connection = self.activeConnection,
                  let data = text.data(using: .utf8) else { return }
            self.sendFragmented(data, over: connection)
        }
    }

    func rejectNextRoute() {
        queue.sync {
            shouldRejectNextRoute = true
        }
    }

    func dropConnection() {
        queue.async {
            self.activeConnection?.cancel()
        }
    }

    func connectionCount() -> Int {
        queue.sync { acceptedConnections }
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            guard let continuation = startContinuation,
                  let port = listener.port?.rawValue else { return }
            startContinuation = nil
            continuation.resume(returning: port)
        case let .failed(error):
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume(
                throwing: LiveVideohubTestError.listenerFailed(String(describing: error))
            )
        case .setup, .waiting, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        activeConnection = connection
        receiveBuffer.removeAll(keepingCapacity: true)
        acceptedConnections += 1

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.sendFragmented(self.initialStateDump(), over: connection)
                self.receiveNext(on: connection)
            case .failed, .cancelled:
                if self.activeConnection === connection {
                    self.activeConnection = nil
                }
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection,
                  self.activeConnection === connection else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeCompleteBlocks(from: connection)
            }

            if error == nil, !isComplete {
                self.receiveNext(on: connection)
            }
        }
    }

    private func consumeCompleteBlocks(from connection: NWConnection) {
        let delimiter = Data("\n\n".utf8)
        while let range = receiveBuffer.range(of: delimiter) {
            let blockData = receiveBuffer[..<range.lowerBound]
            receiveBuffer.removeSubrange(..<range.upperBound)
            handle(String(decoding: blockData, as: UTF8.self), from: connection)
        }
    }

    private func handle(_ block: String, from connection: NWConnection) {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "VIDEO OUTPUT ROUTING:", lines.count >= 2 else {
            send("NAK\n\n", over: connection)
            return
        }

        let routeFields = lines[1].split(whereSeparator: { $0.isWhitespace })
        guard routeFields.count >= 2,
              let output = Int(routeFields[0]),
              let input = Int(routeFields[1]),
              (0..<2).contains(output),
              (0..<3).contains(input) else {
            send("NAK\n\n", over: connection)
            return
        }

        if shouldRejectNextRoute {
            shouldRejectNextRoute = false
            send("NAK\n\n", over: connection)
            return
        }

        send("ACK\n\n", over: connection)
        queue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self, weak connection] in
            guard let self, let connection,
                  self.activeConnection === connection else { return }
            self.send("VIDEO OUTPUT ROUTING:\n\(output) \(input)\n\n", over: connection)
        }
    }

    private func initialStateDump() -> Data {
        Data(
            (
                "PROTOCOL PREAMBLE:\nVersion: 2.3\nFuture field: ignored\n\n"
                    + "VIDEOHUB DEVICE:\nDevice present: true\nModel name: LIVE-TEST\n"
                    + "Video inputs: 3\nVideo outputs: 2\nFuture field: ignored\n\n"
                    + "INPUT LABELS:\n0 Live Source One\n1 Live Source Two\n2 Live Source Three\n\n"
                    + "OUTPUT LABELS:\n0 Live Destination One\n1 Live Destination Two\n\n"
                    + "VIDEO OUTPUT ROUTING:\n0 0\n1 1\n\n"
                    + "VIDEO OUTPUT LOCKS:\n0 U\n1 L\n\n"
                    + "FUTURE BLOCK:\n0 ignored\n\n"
            ).utf8
        )
    }

    private func sendFragmented(_ data: Data, over connection: NWConnection) {
        let fragmentSizes = [1, 2, 7, 3, 19, 5, 31]
        var fragments: [Data] = []
        var offset = data.startIndex
        var sizeIndex = 0

        while offset < data.endIndex {
            let length = min(fragmentSizes[sizeIndex % fragmentSizes.count], data.endIndex - offset)
            let end = data.index(offset, offsetBy: length)
            fragments.append(Data(data[offset..<end]))
            offset = end
            sizeIndex += 1
        }

        send(fragments, index: 0, over: connection)
    }

    private func send(_ fragments: [Data], index: Int, over connection: NWConnection) {
        guard index < fragments.count else { return }
        connection.send(content: fragments[index], completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.queue.async { [weak self, weak connection] in
                guard let self, let connection,
                      self.activeConnection === connection else { return }
                self.send(fragments, index: index + 1, over: connection)
            }
        })
    }

    private func send(_ text: String, over connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}
#endif
