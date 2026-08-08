import Foundation

/// The reusable part of a tile's appearance.
///
/// Deliberately excludes ``PortCustomization/displayNameOverride``: a name
/// belongs to one physical port, so carrying it between tiles would produce
/// duplicate names rather than a shared look. Group *is* included, because
/// tagging a whole bank of ports into one group is the main reason to copy a
/// style in the first place.
struct TileStyle: Equatable, Hashable, Sendable {
    var accentColor: PortAccentColor
    var icon: VideohubIcon
    var group: String?

    init(accentColor: PortAccentColor, icon: VideohubIcon, group: String? = nil) {
        self.accentColor = accentColor
        self.icon = icon
        self.group = Self.normalizedGroup(group)
    }

    init(_ customization: PortCustomization) {
        self.init(
            accentColor: customization.accentColor,
            icon: customization.icon,
            group: customization.group
        )
    }

    var summary: String {
        var parts = [accentColor.displayName, icon.displayName]
        if let group, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " · ")
    }

    /// Applies this style to an existing customization, leaving its name and
    /// format badge alone. Both describe the individual signal on that port,
    /// so a bulk paste must never overwrite them.
    func applied(to customization: PortCustomization) -> PortCustomization {
        PortCustomization(
            displayNameOverride: customization.displayNameOverride,
            accentColor: accentColor,
            icon: icon,
            group: group,
            formatBadge: customization.formatBadge
        )
    }

    private static func normalizedGroup(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A tile identified for styling purposes.
///
/// Sources and destinations occupy independent port-number spaces, so the kind
/// has to travel with the port or source 3 and destination 3 would collide.
struct TileStyleTarget: Hashable, Sendable {
    let kind: PortKind
    let port: PortNumber
}
