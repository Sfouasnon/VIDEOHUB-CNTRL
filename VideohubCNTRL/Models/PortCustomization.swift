import Foundation

/// Whether a customization belongs to a Videohub input or output.
enum PortKind: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case destination
}

/// A stable customization key. Videohub port indices are always zero-based here.
struct PortCustomizationKey: Codable, Hashable, Sendable {
    let routerIdentity: String
    let kind: PortKind
    let protocolPortIndex: Int

    init(routerIdentity: String, kind: PortKind, protocolPortIndex: Int) {
        self.routerIdentity = routerIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.protocolPortIndex = protocolPortIndex
    }

    var isValid: Bool {
        !routerIdentity.isEmpty && protocolPortIndex >= 0
    }
}

enum PortAccentColor: String, Codable, CaseIterable, Hashable, Sendable {
    case blue
    case cyan
    case green
    case yellow
    case orange
    case red
    case purple
    case pink

    // Added later. Raw values are the persistence keys, so existing names must
    // never change and new cases must be appended rather than inserted.
    case teal
    case indigo
    case mint
    case lime
    case amber
    case brown
    case slate

    var displayName: String {
        switch self {
        case .slate: "Slate"
        default: rawValue.capitalized
        }
    }
}

/// Local-only presentation settings. The Videohub label is deliberately not stored.
struct PortCustomization: Codable, Equatable, Sendable {
    var displayNameOverride: String?
    var accentColor: PortAccentColor
    var icon: VideohubIcon
    var group: String?

    /// Operator-declared signal format. Optional because most tiles will not
    /// carry one, and decoded leniently so files written before this existed
    /// still load.
    var formatBadge: SignalFormatBadge?

    init(
        displayNameOverride: String? = nil,
        accentColor: PortAccentColor = .blue,
        icon: VideohubIcon = .genericVideo,
        group: String? = nil,
        formatBadge: SignalFormatBadge? = nil
    ) {
        self.displayNameOverride = Self.normalizedOptionalText(displayNameOverride)
        self.accentColor = accentColor
        self.icon = icon
        self.group = Self.normalizedOptionalText(group)
        self.formatBadge = formatBadge
    }

    /// Resolves the locally overridden name, falling back to the live router label.
    func displayName(videohubLabel: String) -> String {
        Self.normalizedOptionalText(displayNameOverride) ?? videohubLabel
    }

    mutating func setDisplayNameOverride(_ value: String?) {
        displayNameOverride = Self.normalizedOptionalText(value)
    }

    mutating func resetToVideohubLabel() {
        displayNameOverride = nil
    }

    mutating func setGroup(_ value: String?) {
        group = Self.normalizedOptionalText(value)
    }

    mutating func setFormatBadge(_ value: SignalFormatBadge?) {
        formatBadge = value
    }

    func normalized() -> PortCustomization {
        PortCustomization(
            displayNameOverride: displayNameOverride,
            accentColor: accentColor,
            icon: icon,
            group: group,
            formatBadge: formatBadge
        )
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
