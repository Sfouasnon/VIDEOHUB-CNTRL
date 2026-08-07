import Foundation
import Network

/// Finds Videohubs on the local network over Bonjour.
///
/// Blackmagic's own Videohub Control browses `_videohub._tcp` and
/// `_blackmagic._tcp`, so this browses both. Firmware that publishes on both
/// types produces two advertisements for one chassis; they are collapsed by
/// instance name so the operator sees a single row.
///
/// An advertisement only proves that something answered mDNS, never that the
/// control port is usable, so each resolved endpoint is probed on the Videohub
/// control port and is marked reachable only once a `VIDEOHUB DEVICE` block
/// parses. That also supplies the model name for the device list.
///
/// All browser, connection, and parser state is confined to `queue`; results
/// are handed to the caller, which moves them onto the main actor.
final class VideohubDiscovery: @unchecked Sendable {
    typealias ResultsHandler = @Sendable ([DiscoveredVideohub]) -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    /// Service types advertised by Videohub hardware.
    static let serviceTypes = ["_videohub._tcp", "_blackmagic._tcp"]

    private let queue = DispatchQueue(label: "com.videohubonset.discovery")
    private let resultsHandler: ResultsHandler
    private let failureHandler: FailureHandler
    private let controlPort: UInt16
    private let probeTimeout: TimeInterval

    private var browsers: [NWBrowser] = []
    private var devices: [String: DiscoveredVideohub] = [:]
    private var probes: [String: NWConnection] = [:]
    private var probeTimeoutItems: [String: DispatchWorkItem] = [:]
    private var probeParsers: [String: VideohubProtocolParser] = [:]
    private var isRunning = false

    init(
        controlPort: UInt16 = 9990,
        probeTimeout: TimeInterval = 5,
        resultsHandler: @escaping ResultsHandler,
        failureHandler: @escaping FailureHandler
    ) {
        self.controlPort = controlPort
        self.probeTimeout = probeTimeout
        self.resultsHandler = resultsHandler
        self.failureHandler = failureHandler
    }

    deinit {
        browsers.forEach { $0.cancel() }
        probes.values.forEach { $0.cancel() }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.devices.removeAll()
            self.publish()

            for serviceType in Self.serviceTypes {
                self.beginBrowsing(serviceType: serviceType)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.browsers.forEach { $0.cancel() }
            self.browsers.removeAll()
            self.cancelAllProbes()
        }
    }

    /// Drops everything found so far and browses again. Bonjour caches
    /// aggressively, so a manual rescan is the only way to clear a device that
    /// was unplugged without withdrawing its advertisement.
    func restart() {
        stop()
        start()
    }

    private func beginBrowsing(serviceType: String) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(error):
                self.failureHandler(
                    "Discovery failed for \(serviceType): \(String(describing: error))"
                )
            case .cancelled, .ready, .setup, .waiting:
                break
            @unknown default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.applyBrowseResults(results, serviceType: serviceType)
        }

        browsers.append(browser)
        browser.start(queue: queue)
    }

    private func applyBrowseResults(
        _ results: Set<NWBrowser.Result>,
        serviceType: String
    ) {
        guard isRunning else { return }

        var seenForThisType: Set<String> = []

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            let key = Self.identity(name: name, domain: domain)
            seenForThisType.insert(key)

            if devices[key] == nil {
                devices[key] = DiscoveredVideohub(
                    id: key,
                    serviceName: name,
                    serviceType: type,
                    port: controlPort
                )
                beginProbe(key: key, endpoint: result.endpoint)
            }
        }

        // Only withdraw entries this browser owns. Each device is owned by
        // whichever service type saw it first, so the second browser never
        // removes rows it did not create.
        let stale = devices.keys.filter { key in
            devices[key]?.serviceType == serviceType && !seenForThisType.contains(key)
        }
        for key in stale {
            devices.removeValue(forKey: key)
            cancelProbe(key: key)
        }

        publish()
    }

    /// Resolves the Bonjour endpoint to a concrete address and confirms the
    /// control port really speaks the Videohub protocol.
    private func beginProbe(key: String, endpoint: NWEndpoint) {
        cancelProbe(key: key)

        let connection = NWConnection(to: endpoint, using: .tcp)
        probes[key] = connection
        probeParsers[key] = VideohubProtocolParser()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A resolved address with no protocol response is still worth
            // offering: the operator can try it manually.
            self.finishProbe(key: key)
        }
        probeTimeoutItems[key] = timeout
        queue.asyncAfter(deadline: .now() + probeTimeout, execute: timeout)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.probes[key] === connection else { return }
            switch state {
            case .ready:
                self.recordResolvedAddress(key: key, connection: connection)
                self.receiveProbe(key: key, connection: connection)
            case .failed, .cancelled:
                self.finishProbe(key: key)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func recordResolvedAddress(key: String, connection: NWConnection) {
        guard let remote = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, port) = remote else { return }

        devices[key]?.host = Self.addressString(from: host)
        devices[key]?.port = port.rawValue
        publish()
    }

    private func receiveProbe(key: String, connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self] data, _, isComplete, error in
            guard let self, self.probes[key] === connection else { return }

            if let data, !data.isEmpty, let parser = self.probeParsers[key] {
                var updatedParser = parser
                let events = updatedParser.feed(data)
                self.probeParsers[key] = updatedParser

                for event in events {
                    guard case let .device(update) = event else { continue }
                    self.devices[key]?.isReachable = true
                    if let modelName = update.modelName {
                        self.devices[key]?.modelName = modelName
                    }
                }

                if self.devices[key]?.isReachable == true {
                    self.publish()
                    // The device block is the last thing needed from a probe.
                    // Holding the socket open would consume a control session
                    // slot on the router for no reason.
                    self.finishProbe(key: key)
                    return
                }
            }

            if error != nil || isComplete {
                self.finishProbe(key: key)
            } else {
                self.receiveProbe(key: key, connection: connection)
            }
        }
    }

    private func finishProbe(key: String) {
        cancelProbe(key: key)
        publish()
    }

    private func cancelProbe(key: String) {
        probeTimeoutItems[key]?.cancel()
        probeTimeoutItems.removeValue(forKey: key)
        probeParsers.removeValue(forKey: key)
        if let connection = probes.removeValue(forKey: key) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private func cancelAllProbes() {
        for key in probes.keys { cancelProbe(key: key) }
    }

    private func publish() {
        let sorted = devices.values.sorted {
            $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending
        }
        resultsHandler(sorted)
    }

    private static func identity(name: String, domain: String) -> String {
        "\(name)|\(domain)"
    }

    /// `NWEndpoint.Host` stringifies IPv6 with a scope suffix such as
    /// `fe80::1%en0`. That form is required to reconnect to a link-local
    /// address, so it is deliberately preserved.
    static func addressString(from host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(address):
            return "\(address)"
        case let .ipv6(address):
            return "\(address)"
        case let .name(name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
