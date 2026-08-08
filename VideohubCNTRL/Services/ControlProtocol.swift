import Foundation

/// Wire format for the local control API that surface controllers — currently
/// the Stream Deck plugin — speak to this app.
///
/// The app is the only thing that holds a session with the Videohub, so a
/// surface never opens its own port 9990 connection. That keeps one writer on
/// the router, and it means the surface inherits port names, colors, icons and
/// salvos without being configured twice.
///
/// The transport is newline-delimited JSON over loopback TCP. Both ends are
/// our own processes, so WebSocket framing would only add a dependency on the
/// Node side without buying anything.
///
/// Everything here is deliberately free of AppKit and of the stores, so the
/// encoding can be tested without standing up a router or a window.
enum ControlProtocol {
    /// Bumped only for breaking changes. The plugin refuses a mismatch rather
    /// than guessing, because a silently misparsed crosspoint routes the wrong
    /// signal on set.
    static let version = 1

    /// Loopback only. A surface controller runs on the same machine, and the
    /// router session is unauthenticated, so exposing this to the LAN would
    /// hand routing control to anyone who can reach the port.
    static let defaultPort: UInt16 = 9992
}

// MARK: - Server to client

/// A port as the surface should present it: the router's own label plus every
/// customization the operator has applied in the app.
struct ControlPortInfo: Codable, Equatable, Sendable {
    /// Zero-based, matching the Videohub protocol and the Companion `source`
    /// and `destination` option values.
    var index: Int
    /// One-based, matching the silkscreen on the chassis and the app's UI.
    var number: Int
    /// The label stored on the router itself.
    var routerLabel: String
    /// What the operator sees: the override when set, otherwise `routerLabel`.
    var name: String
    var color: String
    var icon: String
    var group: String?
    var format: String?
    /// Destinations only: which input is currently routed here.
    var routedInput: Int?
    /// Destinations only.
    var lock: String?
}

struct ControlCrosspoint: Codable, Equatable, Hashable, Sendable {
    var output: Int
    var input: Int
}

struct ControlSalvoInfo: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var color: String
    var icon: String
    var crosspoints: [ControlCrosspoint]
}

struct ControlRouterInfo: Codable, Equatable, Sendable {
    var identity: String
    var name: String
    var inputCount: Int
    var outputCount: Int
    var isReady: Bool
}

/// The complete picture a surface needs to draw every key.
///
/// Sent whole on connect and whenever anything changes. A 40x40 router encodes
/// to a few tens of kilobytes, which is cheap enough on loopback that diffing
/// would buy nothing but a class of bugs where a key shows a stale route.
struct ControlSnapshot: Codable, Equatable, Sendable {
    var connection: String
    var router: ControlRouterInfo
    var inputs: [ControlPortInfo]
    var outputs: [ControlPortInfo]
    /// Keyed by output index, rendered as a string because JSON object keys
    /// are strings. Duplicates `ControlPortInfo.routedInput` so a surface can
    /// evaluate feedback without walking the whole output list per key.
    var routes: [String: Int]
    var salvos: [ControlSalvoInfo]
}

enum ControlEvent: Encodable, Equatable, Sendable {
    /// First frame on every connection, before any snapshot.
    case hello(protocolVersion: Int, app: String, appVersion: String)
    case snapshot(ControlSnapshot)
    /// Result of a command carrying an `id`.
    case ack(id: String, ok: Bool, error: String?)
    /// Something the operator should see, mirroring the app's own notices.
    case notice(kind: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, app, appVersion, snapshot, id, ok, error, kind, message
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(protocolVersion, app, appVersion):
            try container.encode("hello", forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(app, forKey: .app)
            try container.encode(appVersion, forKey: .appVersion)
        case let .snapshot(snapshot):
            try container.encode("snapshot", forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case let .ack(id, ok, error):
            try container.encode("ack", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(ok, forKey: .ok)
            try container.encodeIfPresent(error, forKey: .error)
        case let .notice(kind, message):
            try container.encode("notice", forKey: .type)
            try container.encode(kind, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

// MARK: - Client to server

/// A command from a surface.
///
/// `route` carries a list rather than a single crosspoint so one key can drive
/// several destinations at once — the case Companion covers with a multi-action
/// button. The list is applied as a unit or refused as a unit; a key that
/// half-fires is worse than a key that does nothing.
enum ControlCommand: Equatable, Sendable {
    case route(id: String?, crosspoints: [ControlCrosspoint])
    case fireSalvo(id: String?, salvoID: String)
    case refresh(id: String?)
    case ping(id: String?)

    var requestID: String? {
        switch self {
        case let .route(id, _), let .fireSalvo(id, _), let .refresh(id), let .ping(id):
            id
        }
    }
}

enum ControlCommandDecodingError: Error, Equatable, LocalizedError {
    case notAnObject
    case missingType
    case unknownType(String)
    case missingField(String)
    case emptyCrosspoints
    /// A negative index can only come from a malformed surface config, and
    /// `PortNumber` would reject it later anyway. Failing here gives the
    /// surface an ack it can show on the key instead of silent inaction.
    case invalidCrosspoint

    var errorDescription: String? {
        switch self {
        case .notAnObject: "Command was not a JSON object"
        case .missingType: "Command is missing \"type\""
        case let .unknownType(type): "Unknown command type \"\(type)\""
        case let .missingField(field): "Command is missing \"\(field)\""
        case .emptyCrosspoints: "Route command carried no crosspoints"
        case .invalidCrosspoint: "Route command carried a negative port index"
        }
    }
}

extension ControlCommand {
    static func decode(from data: Data) throws -> ControlCommand {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ControlCommandDecodingError.notAnObject
        }
        guard let type = dictionary["type"] as? String else {
            throw ControlCommandDecodingError.missingType
        }
        let id = dictionary["id"] as? String

        switch type {
        case "route":
            guard let raw = dictionary["crosspoints"] as? [[String: Any]] else {
                throw ControlCommandDecodingError.missingField("crosspoints")
            }
            guard !raw.isEmpty else { throw ControlCommandDecodingError.emptyCrosspoints }
            var crosspoints: [ControlCrosspoint] = []
            for entry in raw {
                guard let output = entry["output"] as? Int,
                      let input = entry["input"] as? Int else {
                    throw ControlCommandDecodingError.missingField("output/input")
                }
                guard output >= 0, input >= 0 else {
                    throw ControlCommandDecodingError.invalidCrosspoint
                }
                crosspoints.append(ControlCrosspoint(output: output, input: input))
            }
            return .route(id: id, crosspoints: crosspoints)

        case "salvo":
            guard let salvoID = dictionary["salvoID"] as? String else {
                throw ControlCommandDecodingError.missingField("salvoID")
            }
            return .fireSalvo(id: id, salvoID: salvoID)

        case "refresh":
            return .refresh(id: id)

        case "ping":
            return .ping(id: id)

        default:
            throw ControlCommandDecodingError.unknownType(type)
        }
    }
}
