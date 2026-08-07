import Foundation
import Network

enum VideohubTransportState: Equatable, Sendable {
    case offline
    case connecting
    case connected
}

/// Stateful reconnect delay policy. A TCP socket reaching `ready` does not
/// prove that a Videohub session is usable, so callers reset this only for a
/// manual connection attempt or after the state dump has synchronized.
struct VideohubReconnectBackoff: Equatable, Sendable {
    private static let delays: [TimeInterval] = [1, 2, 4, 8, 12]

    private(set) var attempt = 0

    mutating func nextDelay() -> TimeInterval {
        let delay = Self.delays[min(attempt, Self.delays.count - 1)]
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}

/// Owns the one long-lived TCP connection to a Videohub. All Network.framework
/// and parser state is confined to `queue`; callbacks are handed to the store,
/// which moves observable mutations onto the main actor.
final class VideohubClient: @unchecked Sendable {
    typealias SessionID = UUID
    typealias StateHandler = @Sendable (VideohubTransportState, SessionID?) -> Void
    typealias EventHandler = @Sendable (VideohubProtocolEvent, SessionID) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "com.videohubonset.connection")
    private let stateHandler: StateHandler
    private let eventHandler: EventHandler
    private let errorHandler: ErrorHandler

    private var connection: NWConnection?
    private var connectionGeneration: UUID?
    private var parser = VideohubProtocolParser()
    private var host = ""
    private var port: UInt16 = 9990
    private var reconnectAutomatically = true
    private var manuallyDisconnected = true
    private var reconnectBackoff = VideohubReconnectBackoff()
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var lastReceiveDate = Date.distantPast
    private var isReady = false

    init(
        stateHandler: @escaping StateHandler,
        eventHandler: @escaping EventHandler,
        errorHandler: @escaping ErrorHandler
    ) {
        self.stateHandler = stateHandler
        self.eventHandler = eventHandler
        self.errorHandler = errorHandler
    }

    func connect(host: String, port: UInt16 = 9990, reconnectAutomatically: Bool) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async { [weak self] in
            guard let self else { return }
            self.host = trimmedHost
            self.port = port
            self.reconnectAutomatically = reconnectAutomatically
            self.manuallyDisconnected = false
            self.reconnectBackoff.reset()
            self.cancelReconnect()
            self.stopCurrentConnection()
            self.beginConnection()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.manuallyDisconnected = true
            self.cancelReconnect()
            let sessionID = self.connectionGeneration
            self.stopCurrentConnection()
            self.stateHandler(.offline, sessionID)
        }
    }

    func setReconnectAutomatically(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconnectAutomatically = enabled
            if !enabled {
                self.cancelReconnect()
            } else if !self.manuallyDisconnected, self.connection == nil {
                self.scheduleReconnect()
            }
        }
    }

    func sendRoute(outputIndex: Int, inputIndex: Int) {
        sendRoutes([(output: outputIndex, input: inputIndex)])
    }

    /// Sends several crosspoints as one `VIDEO OUTPUT ROUTING` block.
    ///
    /// The protocol accepts multiple lines per block, and a Videohub applies a
    /// whole block together. Sending a salvo as one block is therefore the
    /// difference between a clean simultaneous change and a visible cascade of
    /// individual takes.
    func sendRoutes(_ crosspoints: [(output: Int, input: Int)]) {
        guard !crosspoints.isEmpty else { return }
        guard crosspoints.allSatisfy({ $0.output >= 0 && $0.input >= 0 }) else {
            errorHandler("Invalid route port number")
            return
        }

        let command = Self.routingCommand(for: crosspoints)
        let failureMessage = crosspoints.count == 1
            ? "Route command could not be sent"
            : "Salvo command could not be sent"

        queue.async { [weak self] in
            self?.send(command, failureMessage: failureMessage)
        }
    }

    /// Builds the wire representation of a routing block. Separated from the
    /// socket so the exact byte layout can be asserted without a connection.
    static func routingCommand(for crosspoints: [(output: Int, input: Int)]) -> String {
        let lines = crosspoints.map { "\($0.output) \($0.input)" }.joined(separator: "\n")
        return "VIDEO OUTPUT ROUTING:\n\(lines)\n\n"
    }

    /// Resets automatic retry backoff only when the store confirms that this
    /// exact connection generation received its authoritative state dump.
    func markSessionSynchronized(_ sessionID: SessionID) {
        queue.async { [weak self] in
            guard let self,
                  self.isReady,
                  self.connectionGeneration == sessionID else { return }
            self.reconnectBackoff.reset()
        }
    }

    private func beginConnection() {
        guard !manuallyDisconnected, !host.isEmpty else { return }

        parser.reset()
        isReady = false

        let generation = UUID()
        connectionGeneration = generation
        stateHandler(.connecting, generation)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state, generation: generation)
        }
        connection.start(queue: queue)
    }

    private func handle(state: NWConnection.State, generation: UUID) {
        guard generation == connectionGeneration else { return }

        switch state {
        case .ready:
            isReady = true
            lastReceiveDate = Date()
            stateHandler(.connected, generation)
            startPingTimer(generation: generation)
            receiveNext(generation: generation)

        case let .waiting(error):
            handleConnectionLoss(
                generation: generation,
                message: "Connection waiting: \(error.localizedDescription)"
            )

        case let .failed(error):
            handleConnectionLoss(
                generation: generation,
                message: "Connection lost: \(error.localizedDescription)"
            )

        case .cancelled:
            guard generation == connectionGeneration else { return }
            connection = nil
            connectionGeneration = nil
            isReady = false
            stopPingTimer()
            stateHandler(.offline, generation)
            if !manuallyDisconnected, reconnectAutomatically {
                scheduleReconnect()
            }

        case .setup, .preparing:
            break

        @unknown default:
            break
        }
    }

    private func receiveNext(generation: UUID) {
        guard generation == connectionGeneration, let connection else { return }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self, generation == self.connectionGeneration else { return }

            if let data, !data.isEmpty {
                self.lastReceiveDate = Date()
                for event in self.parser.feed(data) {
                    self.eventHandler(event, generation)
                }
            }

            if let error {
                self.handleConnectionLoss(
                    generation: generation,
                    message: "Connection lost: \(error.localizedDescription)"
                )
            } else if isComplete {
                self.handleConnectionLoss(
                    generation: generation,
                    message: "Connection closed by Videohub"
                )
            } else {
                self.receiveNext(generation: generation)
            }
        }
    }

    private func send(_ text: String, failureMessage: String) {
        guard isReady, let connection, let data = text.data(using: .utf8) else {
            errorHandler("Videohub is offline")
            return
        }

        let generation = connectionGeneration
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error, generation == self.connectionGeneration else { return }
            self.errorHandler("\(failureMessage): \(error.localizedDescription)")
            if let generation {
                self.handleConnectionLoss(
                    generation: generation,
                    message: "Connection lost: \(error.localizedDescription)"
                )
            }
        })
    }

    private func startPingTimer(generation: UUID) {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(15),
            repeating: .seconds(15),
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }

            if Date().timeIntervalSince(self.lastReceiveDate) > 45 {
                self.handleConnectionLoss(
                    generation: generation,
                    message: "Videohub stopped responding"
                )
                return
            }
            self.send("PING:\n\n", failureMessage: "Connection check failed")
        }
        pingTimer = timer
        timer.resume()
    }

    private func handleConnectionLoss(generation: UUID, message: String) {
        guard generation == connectionGeneration else { return }
        errorHandler(message)
        stateHandler(.offline, generation)
        stopCurrentConnection()
        if !manuallyDisconnected, reconnectAutomatically {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard reconnectWorkItem == nil, !host.isEmpty else { return }

        let delay = reconnectBackoff.nextDelay()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.manuallyDisconnected, self.reconnectAutomatically else { return }
            self.beginConnection()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func stopCurrentConnection() {
        isReady = false
        _ = parser.finish()
        stopPingTimer()
        let oldConnection = connection
        connection = nil
        connectionGeneration = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
    }

    private func stopPingTimer() {
        pingTimer?.setEventHandler {}
        pingTimer?.cancel()
        pingTimer = nil
    }
}

private extension NWError {
    var localizedDescription: String {
        String(describing: self)
    }
}
