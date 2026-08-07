import Foundation
import Observation

enum RouterConnectionState: Equatable, Sendable {
    case offline
    case connecting
    case connected

    var label: String {
        switch self {
        case .offline: "Offline"
        case .connecting: "Connecting"
        case .connected: "Connected"
        }
    }
}

struct OperatorNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case information
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

@MainActor
@Observable
final class RouterStore {
    private struct InitialSyncState {
        var receivedDevice = false
        var receivedInputLabels = false
        var receivedOutputLabels = false
        var receivedRoutes = false
        var receivedLocks = false

        var isComplete: Bool {
            receivedDevice
                && receivedInputLabels
                && receivedOutputLabels
                && receivedRoutes
                && receivedLocks
        }
    }

    private enum DefaultsKey {
        static let host = "videohub.host"
        static let reconnectAutomatically = "videohub.reconnectAutomatically"
        static let confirmBeforeTake = "videohub.confirmBeforeTake"
    }

    var connectionState: RouterConnectionState = .offline
    var device = VideohubDevice()
    var inputs: [VideoInput] = []
    var outputs: [VideoOutput] = []
    var routes: [PortNumber: PortNumber] = [:]
    var locks: [PortNumber: OutputLockState] = [:]
    var selectedInputID: PortNumber?
    var selectedOutputID: PortNumber?
    var pendingRoute: PendingRoute?
    var pendingSalvo: PendingSalvo?
    var notice: OperatorNotice?
    var isTakeConfirmationPresented = false
    var discoveredDevices: [DiscoveredVideohub] = []
    var isDiscovering = false

    /// The most recently copied tile style, if any. In-memory only: a copied
    /// look is a working-session convenience, not something to persist.
    var copiedStyle: TileStyle?

    /// Tiles marked for a bulk style paste. Kept entirely separate from
    /// `selectedInputID`/`selectedOutputID` so that marking tiles for styling
    /// can never change what a TAKE would route.
    var styleSelection: Set<TileStyleTarget> = []

    var host: String {
        didSet { defaults.set(host, forKey: DefaultsKey.host) }
    }

    var reconnectAutomatically: Bool {
        didSet {
            defaults.set(reconnectAutomatically, forKey: DefaultsKey.reconnectAutomatically)
            client.setReconnectAutomatically(reconnectAutomatically)
        }
    }

    var confirmBeforeTake: Bool {
        didSet { defaults.set(confirmBeforeTake, forKey: DefaultsKey.confirmBeforeTake) }
    }

    let customizationStore: CustomizationStore
    let salvoStore: SalvoStore

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isDemoMode: Bool
    @ObservationIgnored private let connectionPort: UInt16
    @ObservationIgnored private var activeHost: String?
    @ObservationIgnored private var inputLabels: [Int: String] = [:]
    @ObservationIgnored private var outputLabels: [Int: String] = [:]
    @ObservationIgnored private var initialSyncState = InitialSyncState()
    @ObservationIgnored private var activeClientSessionID: VideohubClient.SessionID?
    @ObservationIgnored private var pendingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var salvoTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var noticeDismissTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryRequestCount = 0

    @ObservationIgnored private lazy var client = VideohubClient(
        stateHandler: { [weak self] state, sessionID in
            // The client invokes callbacks from one serial queue. Dispatching
            // each callback onto the same main queue preserves wire order.
            DispatchQueue.main.async { [weak self] in
                self?.handleTransportState(state, sessionID: sessionID)
            }
        },
        eventHandler: { [weak self] event, sessionID in
            DispatchQueue.main.async { [weak self] in
                self?.handleProtocolEvent(event, sessionID: sessionID)
            }
        },
        errorHandler: { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.publishNotice(.error, message)
            }
        }
    )

    @ObservationIgnored private lazy var discovery = VideohubDiscovery(
        controlPort: connectionPort,
        resultsHandler: { [weak self] devices in
            DispatchQueue.main.async { [weak self] in
                self?.discoveredDevices = devices
            }
        },
        failureHandler: { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                self?.publishNotice(.error, message)
            }
        }
    )

    init(
        defaults: UserDefaults = .standard,
        customizationStore: CustomizationStore? = nil,
        salvoStore: SalvoStore? = nil,
        demoPortCount: Int? = nil,
        connectionPort: UInt16 = 9990
    ) {
        self.defaults = defaults
        self.customizationStore = customizationStore ?? CustomizationStore()
        self.salvoStore = salvoStore ?? SalvoStore()
        host = defaults.string(forKey: DefaultsKey.host) ?? "192.168.1.50"
        reconnectAutomatically = defaults.object(
            forKey: DefaultsKey.reconnectAutomatically
        ) as? Bool ?? true
        confirmBeforeTake = defaults.object(
            forKey: DefaultsKey.confirmBeforeTake
        ) as? Bool ?? false
        isDemoMode = demoPortCount != nil
        self.connectionPort = connectionPort

        if let demoPortCount {
            loadDemoData(portCount: max(1, demoPortCount))
        }
    }

    var selectedInput: VideoInput? {
        guard let selectedInputID else { return nil }
        return inputs.first(where: { $0.id == selectedInputID })
    }

    var selectedOutput: VideoOutput? {
        guard let selectedOutputID else { return nil }
        return outputs.first(where: { $0.id == selectedOutputID })
    }

    var routerDisplayName: String {
        device.modelName.isEmpty ? "Videohub" : device.modelName
    }

    var routerIdentity: String {
        if isDemoMode { return "demo-router" }
        let identity = (activeHost ?? host).trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? "unconfigured-router" : identity.lowercased()
    }

    var canTake: Bool { takeDisabledReason == nil }

    var takeDisabledReason: String? {
        guard connectionState == .connected else {
            return connectionState == .connecting ? "Connecting to router" : "Router is offline"
        }
        guard selectedInputID != nil else { return "Select a source" }
        guard let selectedOutputID else { return "Select a destination" }
        guard pendingRoute == nil else { return "A route is already pending" }
        switch lockState(for: selectedOutputID) {
        case .lockedByOther:
            return "Output locked by another controller"
        case .unknown:
            return "Output lock status unavailable"
        case .unlocked, .ownedByThisClient:
            break
        }
        return nil
    }

    func start() {
        guard !isDemoMode, reconnectAutomatically else { return }
        connect()
    }

    func connect() {
        guard !isDemoMode else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            publishNotice(.error, "Enter a Videohub host or IP address")
            return
        }

        if let activeHost,
           activeHost.caseInsensitiveCompare(trimmedHost) != .orderedSame {
            resetProtocolState()
        }
        activeHost = trimmedHost
        host = trimmedHost
        client.connect(
            host: trimmedHost,
            port: connectionPort,
            reconnectAutomatically: reconnectAutomatically
        )
    }

    func disconnect() {
        guard !isDemoMode else { return }
        client.disconnect()
        cancelPendingRoute()
        cancelPendingSalvo()
        connectionState = .offline
    }

    /// True when the operator has typed a host that differs from the one the
    /// current session is using. The host field stays editable at all times, so
    /// this drives the "reconnect to apply" affordance rather than disabling
    /// the control.
    var hasUnappliedHostChange: Bool {
        guard !isDemoMode, connectionState != .offline, let activeHost else { return false }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return false }
        return activeHost.caseInsensitiveCompare(trimmedHost) != .orderedSame
    }

    /// Applies a newly typed host. `connect()` already tears down the previous
    /// session and clears protocol state when the host changes, so committing
    /// the field can route straight through it.
    func applyHostChange() {
        guard !isDemoMode, hasUnappliedHostChange else { return }
        connect()
    }

    // MARK: - Discovery

    /// Discovery is requested independently by the action panel and the
    /// Settings window, so requests are counted. Closing Settings must not stop
    /// the browse the main window still depends on.
    func startDiscovery() {
        discoveryRequestCount += 1
        guard !isDemoMode else {
            isDiscovering = true
            discoveredDevices = Self.demoDiscoveredDevices
            return
        }
        guard discoveryRequestCount == 1 else { return }
        isDiscovering = true
        discovery.start()
    }

    func stopDiscovery() {
        guard discoveryRequestCount > 0 else { return }
        discoveryRequestCount -= 1
        guard discoveryRequestCount == 0 else { return }
        isDiscovering = false
        guard !isDemoMode else { return }
        discovery.stop()
    }

    /// Clears the current results and browses again. Bonjour caches
    /// withdrawals, so a router that was unplugged without deregistering only
    /// disappears on an explicit rescan.
    func rescanDiscovery() {
        guard !isDemoMode else {
            discoveredDevices = Self.demoDiscoveredDevices
            return
        }
        isDiscovering = true
        discoveredDevices = []
        discovery.restart()
    }

    func connect(to device: DiscoveredVideohub) {
        guard let deviceHost = device.host else {
            publishNotice(.information, "Still resolving \(device.serviceName)")
            return
        }
        host = deviceHost
        connect()
    }

    private static let demoDiscoveredDevices: [DiscoveredVideohub] = [
        DiscoveredVideohub(
            id: "demo-a",
            serviceName: "Rack A Videohub",
            serviceType: "_videohub._tcp",
            host: "192.168.1.50",
            modelName: "Blackmagic Smart Videohub 40 x 40",
            isReachable: true
        ),
        DiscoveredVideohub(
            id: "demo-b",
            serviceName: "Truck Videohub",
            serviceType: "_blackmagic._tcp",
            host: "192.168.1.77",
            modelName: "Blackmagic Videohub 20x20 12G",
            isReachable: true
        )
    ]

    func toggleConnection() {
        switch connectionState {
        case .offline:
            connect()
        case .connecting, .connected:
            disconnect()
        }
    }

    func selectInput(_ id: PortNumber) {
        guard inputs.contains(where: { $0.id == id }) else { return }
        selectedInputID = id
    }

    func selectOutput(_ id: PortNumber) {
        guard outputs.contains(where: { $0.id == id }) else { return }
        selectedOutputID = id
        switch lockState(for: id) {
        case .lockedByOther:
            publishNotice(.information, "Output locked by another controller")
        case .unknown:
            publishNotice(.information, "Output lock status unavailable")
        case .unlocked, .ownedByThisClient:
            break
        }
    }

    func clearSelection() {
        selectedInputID = nil
        selectedOutputID = nil
        isTakeConfirmationPresented = false
    }

    func requestTake() {
        guard canTake else {
            if let takeDisabledReason {
                publishNotice(.information, takeDisabledReason)
            }
            return
        }

        if confirmBeforeTake {
            isTakeConfirmationPresented = true
        } else {
            performTake()
        }
    }

    func confirmTake() {
        isTakeConfirmationPresented = false
        guard canTake else {
            if let takeDisabledReason {
                publishNotice(.information, takeDisabledReason)
            }
            return
        }
        performTake()
    }

    func cancelTakeConfirmation() {
        isTakeConfirmationPresented = false
    }

    // MARK: - Salvos

    var salvos: [Salvo] {
        salvoStore.salvos(forRouter: routerIdentity)
    }

    @discardableResult
    func saveSalvo(_ salvo: Salvo) -> Bool {
        guard salvoStore.save(salvo, forRouter: routerIdentity) else {
            publishNotice(
                .error,
                salvoStore.lastError?.localizedDescription ?? "Salvo could not be saved"
            )
            return false
        }
        return true
    }

    @discardableResult
    func deleteSalvo(id: UUID) -> Bool {
        guard salvoStore.delete(id: id, forRouter: routerIdentity) else {
            publishNotice(
                .error,
                salvoStore.lastError?.localizedDescription ?? "Salvo could not be deleted"
            )
            return false
        }
        return true
    }

    func canFire(_ salvo: Salvo) -> Bool {
        fireDisabledReason(for: salvo) == nil
    }

    /// Why a salvo cannot currently be fired, or `nil` when it can.
    ///
    /// Lock handling matches TAKE and is deliberately fail-closed: a salvo is
    /// refused whole rather than partially applied, because a half-executed
    /// salvo leaves the router in a state the operator never asked for.
    func fireDisabledReason(for salvo: Salvo) -> String? {
        guard connectionState == .connected else {
            return connectionState == .connecting ? "Connecting to router" : "Router is offline"
        }
        guard salvo.isFireable else { return "Salvo has no crosspoints" }
        guard pendingRoute == nil else { return "A route is already pending" }
        guard pendingSalvo == nil else { return "A salvo is already running" }

        let usable = salvo.validated(
            inputCount: device.videoInputCount,
            outputCount: device.videoOutputCount
        )
        guard usable.isFireable else { return "No crosspoints match this router" }

        let blocked = usable.crosspoints
            .filter { lockState(for: $0.output).preventsRouting }
            .map(\.output)
        if !blocked.isEmpty {
            let names = blocked.sorted().prefix(3).map { "\($0.uiNumber)" }.joined(separator: ", ")
            let suffix = blocked.count > 3 ? " and \(blocked.count - 3) more" : ""
            return blocked.count == 1
                ? "Destination \(names) is locked"
                : "Destinations \(names)\(suffix) are locked"
        }
        return nil
    }

    func fireSalvo(_ salvo: Salvo) {
        guard let reason = fireDisabledReason(for: salvo) else {
            performSalvo(salvo)
            return
        }
        publishNotice(.information, reason)
    }

    private func performSalvo(_ salvo: Salvo) {
        let usable = salvo.validated(
            inputCount: device.videoInputCount,
            outputCount: device.videoOutputCount
        )
        guard usable.isFireable else { return }

        if salvo.hasPortsOutsideTopology(
            inputCount: device.videoInputCount,
            outputCount: device.videoOutputCount
        ) {
            let dropped = salvo.crosspoints.count - usable.crosspoints.count
            publishNotice(
                .information,
                "Skipped \(dropped) crosspoint\(dropped == 1 ? "" : "s") outside this router"
            )
        }

        let pending = PendingSalvo(salvo: salvo, crosspoints: usable.crosspoints)
        pendingSalvo = pending
        scheduleSalvoTimeout(for: pending)

        let crosspoints = usable.crosspoints.map {
            (output: $0.output.protocolIndex, input: $0.input.protocolIndex)
        }

        if isDemoMode {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 550_000_000)
                self?.applyRoutes(
                    Dictionary(uniqueKeysWithValues: crosspoints.map { ($0.output, $0.input) })
                )
            }
        } else {
            client.sendRoutes(crosspoints)
        }
    }

    private func scheduleSalvoTimeout(for pending: PendingSalvo) {
        salvoTimeoutTask?.cancel()
        salvoTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  let current = self.pendingSalvo,
                  current.id == pending.id else { return }
            let confirmed = current.confirmedCount
            self.pendingSalvo = nil
            self.publishNotice(
                .error,
                "\(current.name): only \(confirmed) of \(current.expected.count) confirmed"
            )
        }
    }

    private func cancelPendingSalvo() {
        salvoTimeoutTask?.cancel()
        salvoTimeoutTask = nil
        pendingSalvo = nil
    }

    func route(for output: PortNumber) -> PortNumber? {
        routes[output]
    }

    func routedInput(for output: PortNumber) -> VideoInput? {
        guard let inputID = routes[output] else { return nil }
        return inputs.first(where: { $0.id == inputID })
    }

    func lockState(for output: PortNumber) -> OutputLockState {
        locks[output] ?? .unknown
    }

    func isRoutePending(for output: PortNumber) -> Bool {
        pendingRoute?.route.output == output
    }

    func customizationKey(for input: VideoInput) -> PortCustomizationKey {
        PortCustomizationKey(
            routerIdentity: routerIdentity,
            kind: .source,
            protocolPortIndex: input.id.protocolIndex
        )
    }

    func customizationKey(for output: VideoOutput) -> PortCustomizationKey {
        PortCustomizationKey(
            routerIdentity: routerIdentity,
            kind: .destination,
            protocolPortIndex: output.id.protocolIndex
        )
    }

    func fallbackCustomization(for input: VideoInput) -> PortCustomization {
        PortPresentationResolver.fallback(
            kind: .source,
            port: input.id,
            videohubLabel: input.videohubLabel
        )
    }

    func fallbackCustomization(for output: VideoOutput) -> PortCustomization {
        PortPresentationResolver.fallback(
            kind: .destination,
            port: output.id,
            videohubLabel: output.videohubLabel
        )
    }

    func saveCustomization(_ customization: PortCustomization, for input: VideoInput) {
        saveCustomization(customization, for: customizationKey(for: input))
    }

    func saveCustomization(_ customization: PortCustomization, for output: VideoOutput) {
        saveCustomization(customization, for: customizationKey(for: output))
    }

    // MARK: - Tile style copy and paste

    func currentStyle(for input: VideoInput) -> TileStyle {
        TileStyle(resolvedCustomization(for: input))
    }

    func currentStyle(for output: VideoOutput) -> TileStyle {
        TileStyle(resolvedCustomization(for: output))
    }

    func copyStyle(from input: VideoInput) {
        copyStyle(currentStyle(for: input))
    }

    func copyStyle(from output: VideoOutput) {
        copyStyle(currentStyle(for: output))
    }

    private func copyStyle(_ style: TileStyle) {
        copiedStyle = style
        publishNotice(.information, "Copied style: \(style.summary)")
    }

    func isStyleSelected(_ target: TileStyleTarget) -> Bool {
        styleSelection.contains(target)
    }

    func toggleStyleSelection(_ target: TileStyleTarget) {
        if styleSelection.contains(target) {
            styleSelection.remove(target)
        } else {
            styleSelection.insert(target)
        }
    }

    func clearStyleSelection() {
        styleSelection.removeAll()
    }

    var styleSelectionCount: Int { styleSelection.count }

    /// Pastes onto one tile, leaving its display name untouched.
    func pasteStyle(onto input: VideoInput) {
        guard let copiedStyle else {
            publishNotice(.information, "No style copied yet")
            return
        }
        applyStyle(copiedStyle, toSource: input.id)
        publishNotice(.success, "Pasted style")
    }

    func pasteStyle(onto output: VideoOutput) {
        guard let copiedStyle else {
            publishNotice(.information, "No style copied yet")
            return
        }
        applyStyle(copiedStyle, toDestination: output.id)
        publishNotice(.success, "Pasted style")
    }

    /// Pastes onto every tile currently marked for styling.
    ///
    /// The selection is cleared afterwards so a second paste cannot silently
    /// restyle tiles the operator has stopped thinking about.
    func pasteStyleOntoSelection() {
        guard let copiedStyle else {
            publishNotice(.information, "No style copied yet")
            return
        }
        guard !styleSelection.isEmpty else {
            publishNotice(.information, "No tiles selected")
            return
        }

        var applied = 0
        for target in styleSelection {
            switch target.kind {
            case .source:
                guard inputs.contains(where: { $0.id == target.port }) else { continue }
                applyStyle(copiedStyle, toSource: target.port)
            case .destination:
                guard outputs.contains(where: { $0.id == target.port }) else { continue }
                applyStyle(copiedStyle, toDestination: target.port)
            }
            applied += 1
        }

        clearStyleSelection()
        publishNotice(
            .success,
            "Pasted style to \(applied) tile\(applied == 1 ? "" : "s")"
        )
    }

    private func applyStyle(_ style: TileStyle, toSource port: PortNumber) {
        guard let input = inputs.first(where: { $0.id == port }) else { return }
        saveCustomization(style.applied(to: resolvedCustomization(for: input)), for: input)
    }

    private func applyStyle(_ style: TileStyle, toDestination port: PortNumber) {
        guard let output = outputs.first(where: { $0.id == port }) else { return }
        saveCustomization(style.applied(to: resolvedCustomization(for: output)), for: output)
    }

    private func resolvedCustomization(for input: VideoInput) -> PortCustomization {
        customizationStore.customization(for: customizationKey(for: input))
            ?? fallbackCustomization(for: input)
    }

    private func resolvedCustomization(for output: VideoOutput) -> PortCustomization {
        customizationStore.customization(for: customizationKey(for: output))
            ?? fallbackCustomization(for: output)
    }

    func presentation(for input: VideoInput) -> PortPresentation {
        presentation(
            key: customizationKey(for: input),
            fallback: fallbackCustomization(for: input),
            videohubLabel: input.videohubLabel
        )
    }

    func presentation(for output: VideoOutput) -> PortPresentation {
        presentation(
            key: customizationKey(for: output),
            fallback: fallbackCustomization(for: output),
            videohubLabel: output.videohubLabel
        )
    }

    private func presentation(
        key: PortCustomizationKey,
        fallback: PortCustomization,
        videohubLabel: String
    ) -> PortPresentation {
        let customization = customizationStore.customization(for: key) ?? fallback
        return PortPresentation(
            displayName: customization.displayName(videohubLabel: videohubLabel),
            group: customization.group,
            accentColor: customization.accentColor,
            icon: customization.icon,
            formatBadge: customization.formatBadge
        )
    }

    private func saveCustomization(
        _ customization: PortCustomization,
        for key: PortCustomizationKey
    ) {
        guard !customizationStore.set(customization, for: key) else { return }
        publishNotice(
            .error,
            customizationStore.lastError?.localizedDescription
                ?? "Tile customization could not be saved"
        )
    }

    private func performTake() {
        guard canTake,
              let selectedInputID,
              let selectedOutputID else { return }

        let route = Route(output: selectedOutputID, input: selectedInputID)
        let pending = PendingRoute(route: route)
        pendingRoute = pending
        schedulePendingTimeout(for: pending)

        if isDemoMode {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 550_000_000)
                self?.applyRoutes([
                    route.output.protocolIndex: route.input.protocolIndex
                ])
            }
        } else {
            client.sendRoute(
                outputIndex: route.output.protocolIndex,
                inputIndex: route.input.protocolIndex
            )
        }
    }

    private func handleTransportState(
        _ state: VideohubTransportState,
        sessionID: VideohubClient.SessionID?
    ) {
        switch state {
        case .offline:
            if let sessionID, sessionID != activeClientSessionID { return }
            connectionState = .offline
            cancelPendingRoute()
            cancelPendingSalvo()
            activeClientSessionID = nil
        case .connecting:
            activeClientSessionID = sessionID
            connectionState = .connecting
        case .connected:
            guard sessionID == activeClientSessionID else { return }
            if isDemoMode {
                connectionState = .connected
            } else {
                initialSyncState = InitialSyncState()
                resetProtocolState()
                connectionState = .connecting
            }
        }
    }

    private func handleProtocolEvent(
        _ event: VideohubProtocolEvent,
        sessionID: VideohubClient.SessionID
    ) {
        guard sessionID == activeClientSessionID else { return }
        applyProtocolEvent(event)
    }

    /// Applies only server-reported protocol events. Keeping this boundary
    /// internal also lets the state semantics be unit tested without a socket.
    func applyProtocolEvent(_ event: VideohubProtocolEvent) {
        switch event {
        case let .protocolVersion(version):
            device.protocolVersion = version

        case let .device(update):
            if !isDemoMode, connectionState == .connected {
                // A device block after initial synchronization starts a new
                // snapshot on the same TCP connection (for example, hardware
                // was replaced). Gate TAKE until the replacement dump's
                // labels, routes, and locks are all authoritative again.
                let protocolVersion = device.protocolVersion
                initialSyncState = InitialSyncState()
                resetProtocolState()
                device.protocolVersion = protocolVersion
                connectionState = .connecting
            }
            initialSyncState.receivedDevice = true
            applyDeviceUpdate(update)

        case let .inputLabels(labels):
            initialSyncState.receivedInputLabels = true
            inputLabels.merge(labels, uniquingKeysWith: { _, new in new })
            applyInputLabels(labels)

        case let .outputLabels(labels):
            initialSyncState.receivedOutputLabels = true
            outputLabels.merge(labels, uniquingKeysWith: { _, new in new })
            applyOutputLabels(labels)

        case let .videoOutputRouting(routeUpdates):
            initialSyncState.receivedRoutes = true
            applyRoutes(routeUpdates)

        case let .videoOutputLocks(lockUpdates):
            initialSyncState.receivedLocks = true
            for (index, lock) in lockUpdates {
                guard let port = PortNumber(protocolIndex: index) else { continue }
                switch lock {
                case .unlocked: locks[port] = .unlocked
                case .owned: locks[port] = .ownedByThisClient
                case .lockedByOther: locks[port] = .lockedByOther
                case .unknown:
                    locks[port] = .unknown
                    publishNotice(.error, "Invalid output lock status")
                }
            }

        case .ack:
            // ACK confirms that a command was understood, never that a route
            // changed. Only VIDEO OUTPUT ROUTING mutates `routes`.
            break

        case .nak:
            if let pendingSalvo {
                let name = pendingSalvo.name
                cancelPendingSalvo()
                publishNotice(.error, "\(name) rejected")
            } else if pendingRoute != nil {
                cancelPendingRoute()
                publishNotice(.error, "Route rejected")
            } else {
                publishNotice(.error, "Videohub rejected a command")
            }
        }

        completeInitialSyncIfPossible()
    }

    private func applyDeviceUpdate(_ update: VideohubDeviceInfoUpdate) {
        if let presence = update.presence {
            switch presence {
            case .present: device.presence = .present
            case .absent: device.presence = .absent
            case .needsUpdate: device.presence = .needsUpdate
            case let .unknown(value): device.presence = .unknown(value)
            }
        }
        if let modelName = update.modelName { device.modelName = modelName }
        if let count = update.videoInputCount { device.videoInputCount = count }
        if let count = update.videoOutputCount { device.videoOutputCount = count }

        switch device.presence {
        case .present:
            rebuildPorts()
        case .absent:
            inputLabels = [:]
            outputLabels = [:]
            clearDevicePorts()
            publishNotice(.error, "No Videohub device is present")
        case .needsUpdate:
            inputLabels = [:]
            outputLabels = [:]
            clearDevicePorts()
            publishNotice(.error, "Videohub firmware needs an update")
        case .unknown:
            break
        }
    }

    private func rebuildPorts() {
        inputs = (0..<device.videoInputCount).compactMap { index in
            guard let port = PortNumber(protocolIndex: index) else { return nil }
            return VideoInput(id: port, videohubLabel: inputLabels[index])
        }
        outputs = (0..<device.videoOutputCount).compactMap { index in
            guard let port = PortNumber(protocolIndex: index) else { return nil }
            return VideoOutput(id: port, videohubLabel: outputLabels[index])
        }

        let validInputs = Set(inputs.map(\.id))
        let validOutputs = Set(outputs.map(\.id))
        routes = routes.filter { validOutputs.contains($0.key) && validInputs.contains($0.value) }
        locks = locks.filter { validOutputs.contains($0.key) }
        if let selectedInputID, !validInputs.contains(selectedInputID) { self.selectedInputID = nil }
        if let selectedOutputID, !validOutputs.contains(selectedOutputID) { self.selectedOutputID = nil }

        // A smaller replacement chassis must not leave tiles marked for styling
        // that no longer exist.
        styleSelection = styleSelection.filter { target in
            switch target.kind {
            case .source: validInputs.contains(target.port)
            case .destination: validOutputs.contains(target.port)
            }
        }
    }

    private func applyInputLabels(_ labels: [Int: String]) {
        for (index, label) in labels {
            guard let port = PortNumber(protocolIndex: index),
                  let arrayIndex = inputs.firstIndex(where: { $0.id == port }) else { continue }
            inputs[arrayIndex].videohubLabel = label
        }
    }

    private func applyOutputLabels(_ labels: [Int: String]) {
        for (index, label) in labels {
            guard let port = PortNumber(protocolIndex: index),
                  let arrayIndex = outputs.firstIndex(where: { $0.id == port }) else { continue }
            outputs[arrayIndex].videohubLabel = label
        }
    }

    private func applyRoutes(_ routeUpdates: [Int: Int]) {
        for (outputIndex, inputIndex) in routeUpdates {
            guard let output = PortNumber(protocolIndex: outputIndex),
                  let input = PortNumber(protocolIndex: inputIndex) else { continue }
            routes[output] = input

            if let pendingRoute, pendingRoute.route.output == output {
                let expectedInput = pendingRoute.route.input
                cancelPendingRoute()
                if input == expectedInput {
                    publishNotice(.success, "Route confirmed")
                } else {
                    publishNotice(.error, "Route changed by another controller")
                }
            }

            pendingSalvo?.resolve(output: output, input: input)
        }

        completePendingSalvoIfFinished()
    }

    /// A salvo reports only once every crosspoint has been accounted for, so a
    /// partially applied salvo is never shown as a success.
    private func completePendingSalvoIfFinished() {
        guard let pending = pendingSalvo, pending.isComplete else { return }
        cancelPendingSalvo()

        if pending.conflicted.isEmpty {
            publishNotice(.success, "\(pending.name) confirmed")
        } else {
            let count = pending.conflicted.count
            publishNotice(
                .error,
                "\(pending.name): \(count) crosspoint\(count == 1 ? "" : "s") "
                    + "changed by another controller"
            )
        }
    }

    private func clearDevicePorts() {
        inputs = []
        outputs = []
        routes = [:]
        locks = [:]
        selectedInputID = nil
        selectedOutputID = nil
        styleSelection.removeAll()
        cancelPendingRoute()
        cancelPendingSalvo()
    }

    private func resetProtocolState() {
        device = VideohubDevice()
        inputLabels = [:]
        outputLabels = [:]
        clearDevicePorts()
    }

    private func completeInitialSyncIfPossible() {
        guard !isDemoMode, connectionState == .connecting,
              initialSyncState.receivedDevice else { return }

        switch device.presence {
        case .absent, .needsUpdate:
            finishInitialSynchronization()
        case .present:
            if initialSyncState.isComplete, hasCompleteKnownLockCoverage {
                finishInitialSynchronization()
            }
        case .unknown:
            break
        }
    }

    private func finishInitialSynchronization() {
        connectionState = .connected
        if let activeClientSessionID {
            client.markSessionSynchronized(activeClientSessionID)
        }
    }

    private var hasCompleteKnownLockCoverage: Bool {
        guard initialSyncState.receivedLocks else { return false }

        for index in 0..<device.videoOutputCount {
            guard let port = PortNumber(protocolIndex: index),
                  let lock = locks[port],
                  lock != .unknown else {
                return false
            }
        }
        return true
    }

    private func schedulePendingTimeout(for pending: PendingRoute) {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, self?.pendingRoute?.id == pending.id else { return }
            self?.pendingRoute = nil
            self?.publishNotice(.error, "No route confirmation received")
        }
    }

    private func cancelPendingRoute() {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        pendingRoute = nil
    }

    private func publishNotice(_ kind: OperatorNotice.Kind, _ message: String) {
        noticeDismissTask?.cancel()
        let newNotice = OperatorNotice(kind: kind, message: message)
        notice = newNotice
        noticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self?.notice?.id == newNotice.id else { return }
            self?.notice = nil
        }
    }

    private func loadDemoData(portCount: Int) {
        activeHost = "demo-router"
        connectionState = .connected
        device = VideohubDevice(
            presence: .present,
            modelName: "Videohub",
            videoInputCount: portCount,
            videoOutputCount: portCount,
            protocolVersion: "2.3"
        )

        inputs = (0..<portCount).compactMap { index in
            guard let port = PortNumber(protocolIndex: index) else { return nil }
            return VideoInput(id: port)
        }
        outputs = (0..<portCount).compactMap { index in
            guard let port = PortNumber(protocolIndex: index) else { return nil }
            return VideoOutput(id: port)
        }
        routes = Dictionary(uniqueKeysWithValues: outputs.compactMap { output in
            guard let input = PortNumber(protocolIndex: (output.id.protocolIndex * 3) % portCount)
            else { return nil }
            return (output.id, input)
        })
        locks = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, .unlocked) })
        if let lockedOutput = PortNumber(protocolIndex: min(9, portCount - 1)) {
            locks[lockedOutput] = .lockedByOther
        }
        selectedInputID = PortNumber(protocolIndex: min(2, portCount - 1))
        selectedOutputID = PortNumber(protocolIndex: 0)
    }
}
