import Foundation

struct Route: Equatable, Sendable {
    let output: PortNumber
    let input: PortNumber
}

enum OutputLockState: String, Codable, Sendable {
    case unlocked
    case ownedByThisClient
    case lockedByOther
    case unknown

    /// Unknown is deliberately fail-closed: routing is allowed only after the
    /// router has explicitly reported U or O for the destination.
    var preventsRouting: Bool {
        self == .lockedByOther || self == .unknown
    }
}

struct PendingRoute: Identifiable, Equatable, Sendable {
    let id: UUID
    let route: Route
    let startedAt: Date

    init(route: Route) {
        id = UUID()
        self.route = route
        startedAt = Date()
    }
}

/// A salvo awaiting confirmation.
///
/// A salvo is only complete once the router has reported every one of its
/// crosspoints. Tracking the outstanding destinations separately from the
/// expected sources lets a partial result be reported honestly rather than
/// optimistically shown as done.
struct PendingSalvo: Identifiable, Equatable, Sendable {
    let id: UUID
    let salvoID: UUID
    let name: String
    let expected: [PortNumber: PortNumber]
    private(set) var outstanding: Set<PortNumber>
    private(set) var conflicted: Set<PortNumber>
    let startedAt: Date

    init(salvo: Salvo, crosspoints: [SalvoCrosspoint]) {
        id = UUID()
        salvoID = salvo.id
        name = salvo.displayName
        expected = crosspoints.reduce(into: [:]) { $0[$1.output] = $1.input }
        outstanding = Set(crosspoints.map(\.output))
        conflicted = []
        startedAt = Date()
    }

    var isComplete: Bool { outstanding.isEmpty }
    var confirmedCount: Int { expected.count - outstanding.count }

    /// Records a router-reported route. Returns true when it belonged to this
    /// salvo, so callers can tell salvo traffic from unrelated routing.
    @discardableResult
    mutating func resolve(output: PortNumber, input: PortNumber) -> Bool {
        guard let expectedInput = expected[output],
              outstanding.contains(output) else { return false }
        outstanding.remove(output)
        if input != expectedInput {
            conflicted.insert(output)
        }
        return true
    }
}
