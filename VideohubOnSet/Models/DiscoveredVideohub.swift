import Foundation

/// A Videohub found by ``VideohubDiscovery``.
///
/// Discovery reports a device as soon as Bonjour advertises it, so `host` and
/// `modelName` fill in later once the endpoint has been resolved and probed.
/// The identity is the Bonjour service triple, which stays stable across
/// address changes (DHCP lease renewal, for example).
struct DiscoveredVideohub: Identifiable, Equatable, Sendable {
    /// Bonjour service name, type, and domain joined into a stable key.
    let id: String

    /// The advertised instance name, which operators usually rename to match
    /// the rack position rather than the model.
    var serviceName: String

    /// Which service type advertised this device. Blackmagic publishes both
    /// `_videohub._tcp` and `_blackmagic._tcp`, and some firmware publishes on
    /// both at once, so this exists mainly for diagnostics.
    var serviceType: String

    /// Resolved address, `nil` until the endpoint has been resolved.
    var host: String?

    /// Port reported by the Bonjour SRV record. Videohubs use 9990, but the
    /// record is authoritative.
    var port: UInt16 = 9990

    /// Model reported by the `VIDEOHUB DEVICE` block, `nil` until probed.
    var modelName: String?

    /// Whether a probe reached the device and parsed a Videohub device block.
    /// A Bonjour advertisement alone does not prove the control port is usable.
    var isReachable = false

    var isConnectable: Bool { host != nil }

    /// What the operator should see in a device list.
    var displayName: String {
        if let modelName, !modelName.isEmpty, modelName != serviceName {
            return "\(serviceName) — \(modelName)"
        }
        return serviceName
    }

    var subtitle: String {
        guard let host else { return "Resolving…" }
        return port == 9990 ? host : "\(host):\(port)"
    }
}
