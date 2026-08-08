import Foundation

struct VideohubDevice: Equatable, Sendable {
    enum Presence: Equatable, Sendable {
        case present
        case absent
        case needsUpdate
        case unknown(String)
    }

    var presence: Presence = .absent
    var modelName = "Videohub"
    var videoInputCount = 0
    var videoOutputCount = 0
    var protocolVersion: String?

    var isReady: Bool {
        presence == .present && videoInputCount > 0 && videoOutputCount > 0
    }
}
