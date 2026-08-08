import Foundation

/// An operator-declared format badge shown on a tile.
///
/// This is asserted by the operator, never measured. The Videohub Ethernet
/// Protocol (v2.3) carries no video standard, resolution, or frame rate: its
/// `VIDEO INPUT STATUS` block reports connector type only (`BNC`, `Optical`,
/// `None`) and only on Universal Videohubs with pluggable cards. A Videohub is
/// a format-agnostic SDI crosspoint, so the badge cannot be derived from the
/// router and must not be presented as though it were.
enum SignalFormatBadge: String, Codable, CaseIterable, Hashable, Sendable {
    case hd
    case uhd
    case dci4K
    case uhd8K

    var displayName: String {
        switch self {
        case .hd: "HD"
        case .uhd: "UHD"
        case .dci4K: "4K"
        case .uhd8K: "8K"
        }
    }

    /// What appears on the tile itself. Kept to three characters so the badge
    /// never crowds the port number at the top of a tile.
    var badgeText: String { displayName }
}
