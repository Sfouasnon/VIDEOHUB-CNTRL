import Foundation
import Network

/// Accepts control connections from surface controllers on loopback.
///
/// This is the mirror image of ``VideohubClient``: that owns one outbound
/// session to the router, this accepts many inbound sessions from surfaces.
/// All `NWListener` and `NWConnection` state is confined to `queue`; callers
/// receive commands on that queue and are expected to hop to the main actor,
/// which is what ``ControlBridge`` does.
///
/// The listener binds explicitly to 127.0.0.1 rather than to a port on every
/// interface. The Videohub protocol has no authentication, so a control API
/// reachable from the production network would let anyone on it re-route the
/// router through this app.
final class ControlServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    typealias StateHandler = @Sendable (State) -> Void
    typealias CommandHandler = @Sendable (ControlCommand, ClientID) -> Void
    typealias ClientCountHandler = @Sendable (Int) -> Void

    struct ClientID: Hashable, Sendable {
        let value: UUID
    }

    private final class Client {
        let connection: NWConnection
        var parser = ControlLineParser()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "com.videohubonset.controlserver")
    private let stateHandler: StateHandler
    private let commandHandler: CommandHandler
    private let clientCountHandler: ClientCountHandler

    private var listener: NWListener?
    private var clients: [ClientID: Client] = [:]
    /// The most recent snapshot frame, replayed to each new client so a deck
    /// that reconnects mid-show draws correct keys immediately rather than
    /// waiting for the next router change.
    private var latestSnapshotFrame: Data?

    init(
        stateHandler: @escaping StateHandler,
        commandHandler: @escaping CommandHandler,
        clientCountHandler: @escaping ClientCountHandler
    ) {
        self.stateHandler = stateHandler
        self.commandHandler = commandHandler
        self.clientCountHandler = clientCountHandler
    }

    // MARK: - Lifecycle

    func start(port: UInt16) {
        queue.async { [self] in
            stopLocked()
            stateHandler(.starting)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                stateHandler(.failed("Port \(port) is not valid"))
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Binding the local endpoint, rather than passing `on: port`, is
            // what restricts this to loopback.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            if let tcp = parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolTCP.Options {
                // Surfaces send short bursts of small commands; coalescing them
                // would add latency to a key press for no bandwidth benefit.
                tcp.noDelay = true
            }

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                stateHandler(.failed(Self.describe(error, port: port)))
                return
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    stateHandler(.running(port: port))
                case let .failed(error):
                    stateHandler(.failed(Self.describe(error, port: port)))
                    queue.async { self.stopLocked() }
                case .cancelled:
                    stateHandler(.stopped)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            stopLocked()
            stateHandler(.stopped)
        }
    }

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values {
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        clients.removeAll()
        latestSnapshotFrame = nil
        clientCountHandler(0)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ClientID(value: UUID())
        clients[id] = Client(connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                queue.async {
                    self.sendFrame(
                        Self.encode(
                            .hello(
                                protocolVersion: ControlProtocol.version,
                                app: "Videohub On-Set",
                                appVersion: Self.appVersion
                            )
                        ),
                        to: id
                    )
                    if let frame = self.latestSnapshotFrame {
                        self.sendFrame(frame, to: id)
                    }
                    self.clientCountHandler(self.clients.count)
                }
            case .failed, .cancelled:
                self.queue.async { self.drop(id) }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(id: id)
    }

    private func drop(_ id: ClientID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        clientCountHandler(clients.count)
    }

    private func receive(id: ClientID) {
        guard let client = clients[id] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // `receive` has no message boundaries, so a burst of key
                // presses can arrive coalesced and a long command can arrive
                // split. The parser owns reassembly.
                guard let client = self.clients[id] else { return }
                for line in client.parser.append(data) {
                    self.handle(line: line, from: id)
                }
            }

            if isComplete || error != nil {
                self.queue.async { self.drop(id) }
            } else {
                self.receive(id: id)
            }
        }
    }

    private func handle(line: Data, from id: ClientID) {
        do {
            commandHandler(try ControlCommand.decode(from: line), id)
        } catch {
            // A surface that sends a malformed frame keeps its connection;
            // only that one command is refused, and it is told why so the
            // failure is visible on the key rather than silent.
            sendFrame(
                Self.encode(
                    .ack(
                        id: Self.requestID(in: line) ?? "",
                        ok: false,
                        error: (error as? LocalizedError)?.errorDescription
                            ?? "Malformed command"
                    )
                ),
                to: id
            )
        }
    }

    /// Best-effort extraction of the request id from a frame that failed to
    /// decode, so the ack can still be correlated by the surface.
    private static func requestID(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["id"] as? String
    }

    // MARK: - Sending

    func broadcast(_ event: ControlEvent) {
        queue.async { [self] in
            guard let frame = Self.encode(event) else { return }
            if case .snapshot = event {
                latestSnapshotFrame = frame
            }
            for id in clients.keys {
                sendFrame(frame, to: id)
            }
        }
    }

    func send(_ event: ControlEvent, to id: ClientID) {
        queue.async { [self] in
            sendFrame(Self.encode(event), to: id)
        }
    }

    private func sendFrame(_ frame: Data?, to id: ClientID) {
        guard let frame, let client = clients[id] else { return }
        client.connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] error in
                guard error != nil, let self else { return }
                queue.async { self.drop(id) }
            }
        )
    }

    /// Encodes one frame including its terminating newline.
    ///
    /// `JSONEncoder` never emits a raw newline inside a JSON string — it
    /// escapes it as `\n` — so a newline in the byte stream unambiguously ends
    /// a frame.
    private static func encode(_ event: ControlEvent) -> Data? {
        guard var data = try? JSONEncoder().encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0"
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if let nwError = error as? NWError,
           case let .posix(code) = nwError,
           code == .EADDRINUSE {
            return "Port \(port) is already in use"
        }
        return "Control server failed: \(error.localizedDescription)"
    }
}

/// Reassembles newline-delimited frames from a TCP byte stream.
///
/// Kept separate from ``ControlServer`` so the framing — the part most likely
/// to be wrong under fragmentation — can be tested without a socket.
struct ControlLineParser {
    /// Guards against a peer that never sends a newline. Well past any real
    /// command; a 40x40 salvo encodes to a few kilobytes.
    static let maximumLineLength = 1 << 20

    private var buffer = Data()
    /// Set once a line overruns the cap, so the remainder of that line is
    /// discarded rather than being parsed as a truncated command.
    private var isDiscardingOverlongLine = false

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            if isDiscardingOverlongLine {
                isDiscardingOverlongLine = false
                continue
            }
            guard !line.isEmpty else { continue }
            lines.append(Data(line))
        }

        if buffer.count > Self.maximumLineLength {
            buffer.removeAll(keepingCapacity: false)
            isDiscardingOverlongLine = true
        }

        return lines
    }
}
