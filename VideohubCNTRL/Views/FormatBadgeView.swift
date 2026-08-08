import SwiftUI

/// The small format chip on a tile.
///
/// Rendered in a neutral grey rather than the tile's accent colour so it never
/// reads as part of the colour coding, and so it stays legible whichever
/// accent the operator picked.
struct FormatBadgeView: View {
    let badge: SignalFormatBadge

    var body: some View {
        Text(badge.badgeText)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.16))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.16))
            }
            .accessibilityLabel("Format \(badge.displayName)")
            .help("Operator-set format label — the router does not report format")
    }
}
