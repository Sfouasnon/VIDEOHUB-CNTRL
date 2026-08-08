import AppKit
import SwiftUI

struct SourceTile: View {
    let input: VideoInput
    let store: RouterStore
    let onSelect: () -> Void

    @State private var isCustomizing = false

    private var presentation: PortPresentation { store.presentation(for: input) }
    private var isSelected: Bool { store.selectedInputID == input.id }
    private var styleTarget: TileStyleTarget {
        TileStyleTarget(kind: .source, port: input.id)
    }
    private var isStyleSelected: Bool { store.isStyleSelected(styleTarget) }

    var body: some View {
        Button(action: handleTap) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tileBackground)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        Text(input.id.displayText)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let badge = presentation.formatBadge {
                            FormatBadgeView(badge: badge)
                        }

                        Spacer()

                        if isStyleSelected {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .help("Marked for style paste")
                        }

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(presentation.accentColor.color)
                        }
                    }

                    HStack {
                        Spacer()
                        Image(systemName: presentation.icon.systemImageName)
                            .font(.system(size: 27, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(presentation.accentColor.color)
                        Spacer()
                    }
                    .frame(height: 38)

                    Spacer(minLength: 1)

                    Text(presentation.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(presentation.group ?? " ")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 9)

                Rectangle()
                    .fill(presentation.accentColor.color)
                    .frame(height: isSelected ? 5 : 4)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 9,
                            bottomTrailingRadius: 9
                        )
                    )
            }
            .frame(height: 112)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? presentation.accentColor.color
                            : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .overlay {
                // A dashed ring reads as "marked" without competing with the
                // solid accent ring that means "routing selection".
                if isStyleSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [5, 3])
                        )
                }
            }
            .shadow(
                color: isSelected ? presentation.accentColor.color.opacity(0.42) : .clear,
                radius: 8
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("source-tile-\(input.id.protocolIndex)")
        .contextMenu {
            Button("Customize Tile…") { isCustomizing = true }
                .accessibilityIdentifier("customize-tile-menu-item")

            Divider()

            TileStyleMenuItems(
                store: store,
                isStyleSelected: isStyleSelected,
                copyStyle: { store.copyStyle(from: input) },
                pasteStyle: { store.pasteStyle(onto: input) },
                toggleSelection: { store.toggleStyleSelection(styleTarget) }
            )
        }
        .sheet(isPresented: $isCustomizing) {
            TileCustomizationView(
                portKind: .source,
                port: input.id,
                videohubLabel: input.videohubLabel,
                current: store.customizationStore.customization(
                    for: store.customizationKey(for: input)
                ) ?? store.fallbackCustomization(for: input)
            ) { customization in
                store.saveCustomization(customization, for: input)
            }
        }
        .accessibilityLabel("Source \(input.id.uiNumber), \(presentation.displayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Command-click marks a tile for a bulk style paste; a plain click still
    /// does the routing selection it always did. Reading the live modifier
    /// flags keeps the button's own hit testing and styling intact, which a
    /// competing tap gesture would otherwise disturb.
    private func handleTap() {
        if NSEvent.modifierFlags.contains(.command) {
            store.toggleStyleSelection(styleTarget)
        } else {
            onSelect()
        }
    }

    private var tileBackground: Color {
        isSelected
            ? presentation.accentColor.color.opacity(0.15)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var accessibilityValue: String {
        var components = [
            "Icon \(presentation.icon.displayName)",
            "Color \(presentation.accentColor.displayName)"
        ]
        if let group = presentation.group {
            components.append("Group \(group)")
        }
        return components.joined(separator: ", ")
    }
}
