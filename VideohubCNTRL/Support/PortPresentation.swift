import SwiftUI

struct PortPresentation: Equatable {
    var displayName: String
    var group: String?
    var accentColor: PortAccentColor
    var icon: VideohubIcon
    var formatBadge: SignalFormatBadge?
}

extension PortAccentColor {
    /// Tile accents sit on a dark surface, so the custom values are chosen for
    /// separation against each other and against the neighbouring system
    /// colours rather than for fidelity to any named swatch.
    var color: Color {
        switch self {
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .pink: .pink
        case .teal: .teal
        case .indigo: .indigo
        case .mint: .mint
        case .lime: Color(red: 0.62, green: 0.86, blue: 0.20)
        case .amber: Color(red: 1.00, green: 0.70, blue: 0.12)
        case .brown: .brown
        case .slate: Color(red: 0.55, green: 0.60, blue: 0.68)
        }
    }
}

enum PortPresentationResolver {
    static func fallback(
        kind: PortKind,
        port: PortNumber,
        videohubLabel: String
    ) -> PortCustomization {
        // Videohub does not supply presentation metadata. Defaults never
        // infer meaning from a router label; every value remains editable via
        // Customize Tile, while the live label remains the source of truth.
        _ = kind
        _ = port
        _ = videohubLabel
        return PortCustomization(
            accentColor: .blue,
            icon: .genericVideo,
            group: nil
        )
    }
}
