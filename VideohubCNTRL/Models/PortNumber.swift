import Foundation

/// The single conversion boundary between Videohub's zero-based protocol ports
/// and the one-based numbers operators see on the chassis and in the UI.
struct PortNumber: Hashable, Codable, Comparable, Identifiable, Sendable {
    let protocolIndex: Int

    init?(protocolIndex: Int) {
        guard protocolIndex >= 0 else { return nil }
        self.protocolIndex = protocolIndex
    }

    init?(uiNumber: Int) {
        guard uiNumber > 0 else { return nil }
        protocolIndex = uiNumber - 1
    }

    var id: Int { protocolIndex }
    var uiNumber: Int { protocolIndex + 1 }

    var displayText: String {
        uiNumber.formatted(.number.grouping(.never))
    }

    static func < (lhs: PortNumber, rhs: PortNumber) -> Bool {
        lhs.protocolIndex < rhs.protocolIndex
    }
}
