import Foundation

/// One crosspoint within a salvo: send `input` to `output`.
///
/// Identity is the destination, because a salvo can never drive one output from
/// two sources. ``Salvo`` relies on that to keep its crosspoint list coherent.
struct SalvoCrosspoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    var output: PortNumber
    var input: PortNumber

    var id: Int { output.protocolIndex }

    init(output: PortNumber, input: PortNumber) {
        self.output = output
        self.input = input
    }
}

/// A named group of crosspoints taken together.
///
/// Salvos are stored per router identity, using the same identity string as
/// tile customizations, so the macros for one Videohub never appear when
/// connected to another.
struct Salvo: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var accentColor: PortAccentColor
    var icon: VideohubIcon
    private(set) var crosspoints: [SalvoCrosspoint]

    init(
        id: UUID = UUID(),
        name: String = "",
        accentColor: PortAccentColor = .blue,
        icon: VideohubIcon = .genericVideo,
        crosspoints: [SalvoCrosspoint] = []
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.accentColor = accentColor
        self.icon = icon
        self.crosspoints = Self.normalizedCrosspoints(crosspoints)
    }

    /// A salvo with no crosspoints would be a button that silently does
    /// nothing, so firing is gated on this rather than on a UI check alone.
    var isFireable: Bool { !crosspoints.isEmpty }

    var displayName: String {
        name.isEmpty ? "Untitled Salvo" : name
    }

    var summary: String {
        switch crosspoints.count {
        case 0: "No crosspoints"
        case 1: "1 crosspoint"
        case let count: "\(count) crosspoints"
        }
    }

    mutating func setName(_ value: String) {
        name = Self.normalizedName(value)
    }

    /// Adds or replaces the crosspoint for a destination. Setting a second
    /// source on the same output overwrites the first rather than appending a
    /// conflict that the router would resolve arbitrarily.
    mutating func setCrosspoint(output: PortNumber, input: PortNumber) {
        var updated = crosspoints.filter { $0.output != output }
        updated.append(SalvoCrosspoint(output: output, input: input))
        crosspoints = Self.normalizedCrosspoints(updated)
    }

    mutating func removeCrosspoint(output: PortNumber) {
        crosspoints = crosspoints.filter { $0.output != output }
    }

    func input(for output: PortNumber) -> PortNumber? {
        crosspoints.first(where: { $0.output == output })?.input
    }

    /// Drops crosspoints that fall outside the connected router's topology.
    /// A salvo authored against a 40x40 chassis must not blindly fire at a
    /// 12x12 one.
    func validated(inputCount: Int, outputCount: Int) -> Salvo {
        var copy = self
        copy.crosspoints = crosspoints.filter {
            $0.output.protocolIndex < outputCount && $0.input.protocolIndex < inputCount
        }
        return copy
    }

    func hasPortsOutsideTopology(inputCount: Int, outputCount: Int) -> Bool {
        crosspoints.contains {
            $0.output.protocolIndex >= outputCount || $0.input.protocolIndex >= inputCount
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One entry per destination, ordered by destination so the persisted file
    /// and the editor list are both stable.
    private static func normalizedCrosspoints(
        _ value: [SalvoCrosspoint]
    ) -> [SalvoCrosspoint] {
        var byOutput: [PortNumber: SalvoCrosspoint] = [:]
        for crosspoint in value {
            byOutput[crosspoint.output] = crosspoint
        }
        return byOutput.values.sorted { $0.output < $1.output }
    }
}
