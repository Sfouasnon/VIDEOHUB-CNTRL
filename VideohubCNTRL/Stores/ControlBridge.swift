import Foundation
import Observation

/// Connects ``RouterStore`` to ``ControlServer``: publishes app state to
/// surface controllers and applies the commands they send back.
///
/// It exists so neither side has to know about the other. ``RouterStore`` keeps
/// no concept of a surface, and ``ControlServer`` keeps no concept of a router;
/// the translation lives here and is the only place that has to change when the
/// wire format moves.
@MainActor
@Observable
final class ControlBridge {
    enum Status: Equatable, Sendable {
        case disabled
        case starting
        case running(port: UInt16)
        case failed(String)

        var summary: String {
            switch self {
            case .disabled: "Off"
            case .starting: "Starting…"
            case let .running(port): "Listening on 127.0.0.1:\(port)"
            case let .failed(message): message
            }
        }
    }

    private enum DefaultsKey {
        static let enabled = "control.enabled"
        static let port = "control.port"
    }

    private(set) var status: Status = .disabled
    private(set) var connectedSurfaces = 0

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.enabled)
            isEnabled ? startServer() : stopServer()
        }
    }

    /// Applied on the next start rather than immediately, so typing a port
    /// digit by digit does not thrash the listener.
    var port: UInt16 {
        didSet {
            guard port != oldValue else { return }
            defaults.set(Int(port), forKey: DefaultsKey.port)
        }
    }

    var hasUnappliedPortChange: Bool {
        if case let .running(running) = status { return running != port }
        return false
    }

    @ObservationIgnored private let store: RouterStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private var isTracking = false
    /// Suppresses a redundant broadcast when nothing a surface can see moved.
    @ObservationIgnored private var lastSnapshot: ControlSnapshot?

    init(store: RouterStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        isEnabled = defaults.object(forKey: DefaultsKey.enabled) as? Bool ?? false
        let storedPort = defaults.object(forKey: DefaultsKey.port) as? Int
        port = UInt16(exactly: storedPort ?? Int(ControlProtocol.defaultPort))
            ?? ControlProtocol.defaultPort
    }

    func start() {
        guard isEnabled else { return }
        startServer()
    }

    /// Stops and restarts on the current port, which is how a port change is
    /// committed.
    func restart() {
        guard isEnabled else { return }
        startServer()
    }

    // MARK: - Server lifecycle

    private func startServer() {
        status = .starting
        lastSnapshot = nil

        let server = ControlServer(
            stateHandler: { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            },
            commandHandler: { [weak self] command, client in
                Task { @MainActor in self?.handle(command, from: client) }
            },
            clientCountHandler: { [weak self] count in
                Task { @MainActor in self?.connectedSurfaces = count }
            }
        )
        self.server = server
        server.start(port: port)
        beginTrackingIfNeeded()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        status = .disabled
        connectedSurfaces = 0
        lastSnapshot = nil
    }

    private func handle(_ state: ControlServer.State) {
        switch state {
        case .stopped:
            status = isEnabled ? .starting : .disabled
        case .starting:
            status = .starting
        case let .running(port):
            status = .running(port: port)
            publishSnapshot(force: true)
        case let .failed(message):
            status = .failed(message)
        }
    }

    // MARK: - Commands

    private func handle(_ command: ControlCommand, from client: ControlServer.ClientID) {
        let requestID = command.requestID

        func ack(_ error: String?) {
            guard let requestID else { return }
            server?.send(
                .ack(id: requestID, ok: error == nil, error: error),
                to: client
            )
        }

        switch command {
        case let .route(_, crosspoints):
            ack(store.applyRemoteRoute(crosspoints))

        case let .fireSalvo(_, salvoID):
            guard let uuid = UUID(uuidString: salvoID) else {
                ack("Salvo identifier is not a UUID")
                return
            }
            ack(store.fireSalvo(id: uuid))

        case .refresh:
            publishSnapshot(force: true)
            ack(nil)

        case .ping:
            ack(nil)
        }
    }

    // MARK: - Snapshots

    /// Re-registers itself after every change, because `withObservationTracking`
    /// fires once per registration. Building the snapshot inside the tracked
    /// closure is what subscribes to the properties a surface can see, so any
    /// new field added to ``makeSnapshot`` is tracked automatically.
    private func beginTrackingIfNeeded() {
        guard !isTracking else { return }
        isTracking = true
        track()
    }

    private func track() {
        _ = withObservationTracking {
            makeSnapshot()
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, isEnabled else {
                    self?.isTracking = false
                    return
                }
                publishSnapshot(force: false)
                track()
            }
        }
    }

    private func publishSnapshot(force: Bool) {
        guard let server else { return }
        let snapshot = makeSnapshot()
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        server.broadcast(.snapshot(snapshot))
    }

    func makeSnapshot() -> ControlSnapshot {
        let inputs = store.inputs.map { input -> ControlPortInfo in
            let key = store.customizationKey(for: input)
            let customization = store.customizationStore.customization(for: key)
                ?? store.fallbackCustomization(for: input)
            return ControlPortInfo(
                index: input.id.protocolIndex,
                number: input.id.uiNumber,
                routerLabel: input.videohubLabel,
                name: customization.displayName(videohubLabel: input.videohubLabel),
                color: customization.accentColor.rawValue,
                icon: customization.icon.rawValue,
                group: customization.group,
                format: customization.formatBadge?.rawValue,
                routedInput: nil,
                lock: nil
            )
        }

        let outputs = store.outputs.map { output -> ControlPortInfo in
            let key = store.customizationKey(for: output)
            let customization = store.customizationStore.customization(for: key)
                ?? store.fallbackCustomization(for: output)
            return ControlPortInfo(
                index: output.id.protocolIndex,
                number: output.id.uiNumber,
                routerLabel: output.videohubLabel,
                name: customization.displayName(videohubLabel: output.videohubLabel),
                color: customization.accentColor.rawValue,
                icon: customization.icon.rawValue,
                group: customization.group,
                format: customization.formatBadge?.rawValue,
                routedInput: store.route(for: output.id)?.protocolIndex,
                lock: store.lockState(for: output.id).rawValue
            )
        }

        var routes: [String: Int] = [:]
        for (output, input) in store.routes {
            routes[String(output.protocolIndex)] = input.protocolIndex
        }

        let salvos = store.salvos.map { salvo in
            ControlSalvoInfo(
                id: salvo.id.uuidString,
                name: salvo.displayName,
                color: salvo.accentColor.rawValue,
                icon: salvo.icon.rawValue,
                crosspoints: salvo.crosspoints.map {
                    ControlCrosspoint(
                        output: $0.output.protocolIndex,
                        input: $0.input.protocolIndex
                    )
                }
            )
        }

        return ControlSnapshot(
            connection: connectionText(store.connectionState),
            router: ControlRouterInfo(
                identity: store.routerIdentity,
                name: store.routerDisplayName,
                inputCount: store.device.videoInputCount,
                outputCount: store.device.videoOutputCount,
                isReady: store.device.isReady
            ),
            inputs: inputs,
            outputs: outputs,
            routes: routes,
            salvos: salvos
        )
    }

    private func connectionText(_ state: RouterConnectionState) -> String {
        switch state {
        case .offline: "offline"
        case .connecting: "connecting"
        case .connected: "connected"
        }
    }
}
