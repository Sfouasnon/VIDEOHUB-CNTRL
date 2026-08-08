import AppKit
import SwiftUI

struct DestinationTile: View {
    let output: VideoOutput
    let store: RouterStore
    let onSelect: () -> Void

    @State private var isCustomizing = false

    private var presentation: PortPresentation { store.presentation(for: output) }
    private var isSelected: Bool { store.selectedOutputID == output.id }
    private var isPending: Bool { store.isRoutePending(for: output.id) }
    private var lockState: OutputLockState { store.lockState(for: output.id) }
    private var styleTarget: TileStyleTarget {
        TileStyleTarget(kind: .destination, port: output.id)
    }
    private var isStyleSelected: Bool { store.isStyleSelected(styleTarget) }

    var body: some View {
        Button(action: handleTap) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tileBackground)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        Text(output.id.displayText)
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
                                .padding(.trailing, 2)
                        }

                        if isPending {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Routing")
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        } else if lockState != .unlocked {
                            Image(systemName: lockState == .unknown
                                ? "questionmark.diamond.fill"
                                : "lock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(lockIndicatorColor)
                                .help(lockIndicatorHelp)
                        }

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(presentation.accentColor.color)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: presentation.icon.systemImageName)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(presentation.accentColor.color)
                            .frame(width: 25)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(presentation.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Text(presentation.group ?? " ")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: 40)

                    Spacer(minLength: 4)

                    CurrentSourceBadge(output: output.id, store: store)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)

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
            .frame(height: 132)
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
        .accessibilityIdentifier("destination-tile-\(output.id.protocolIndex)")
        .contextMenu {
            Button("Customize Tile…") { isCustomizing = true }
                .accessibilityIdentifier("customize-tile-menu-item")

            Divider()

            TileStyleMenuItems(
                store: store,
                isStyleSelected: isStyleSelected,
                copyStyle: { store.copyStyle(from: output) },
                pasteStyle: { store.pasteStyle(onto: output) },
                toggleSelection: { store.toggleStyleSelection(styleTarget) }
            )
        }
        .sheet(isPresented: $isCustomizing) {
            TileCustomizationView(
                portKind: .destination,
                port: output.id,
                videohubLabel: output.videohubLabel,
                current: store.customizationStore.customization(
                    for: store.customizationKey(for: output)
                ) ?? store.fallbackCustomization(for: output)
            ) { customization in
                store.saveCustomization(customization, for: output)
            }
        }
        .accessibilityLabel(accessibilityDescription)
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

    private var lockIndicatorColor: Color {
        switch lockState {
        case .lockedByOther: .orange
        case .unknown: .yellow
        case .ownedByThisClient, .unlocked: .secondary
        }
    }

    private var lockIndicatorHelp: String {
        switch lockState {
        case .lockedByOther: "Locked by another controller"
        case .ownedByThisClient: "Locked by this controller"
        case .unknown: "Lock status unavailable"
        case .unlocked: "Unlocked"
        }
    }

    private var accessibilityDescription: String {
        var value = "Destination \(output.id.uiNumber), \(presentation.displayName)"
        if let input = store.routedInput(for: output.id) {
            value += ", routed from \(store.presentation(for: input).displayName)"
        }
        switch lockState {
        case .lockedByOther:
            value += ", locked by another controller"
        case .unknown:
            value += ", lock status unavailable"
        case .unlocked, .ownedByThisClient:
            break
        }
        return value
    }

    private var accessibilityValue: String {
        var components = [
            "Icon \(presentation.icon.displayName)",
            "Color \(presentation.accentColor.displayName)"
        ]
        if let group = presentation.group {
            components.append("Group \(group)")
        }
        if let input = store.routedInput(for: output.id) {
            let source = store.presentation(for: input)
            components.append("Source color \(source.accentColor.displayName)")
        }
        return components.joined(separator: ", ")
    }
}

private struct CurrentSourceBadge: View {
    let output: PortNumber
    let store: RouterStore

    var body: some View {
        Group {
            if let source = store.routedInput(for: output) {
                let sourcePresentation = store.presentation(for: source)
                HStack(spacing: 6) {
                    Text(source.id.displayText)
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(sourcePresentation.accentColor.color, in: Capsule())

                    Text(sourcePresentation.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .frame(height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sourcePresentation.accentColor.color.opacity(0.13))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(sourcePresentation.accentColor.color.opacity(0.32))
                }
            } else if let inputID = store.route(for: output) {
                HStack(spacing: 6) {
                    Text(inputID.displayText)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    Text("Input \(inputID.uiNumber)")
                        .font(.system(size: 10.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 27)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "minus")
                    Text("Unrouted")
                    Spacer()
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .frame(height: 27)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
