import SwiftUI

struct TileCustomizationView: View {
    let portKind: PortKind
    let port: PortNumber
    let videohubLabel: String
    let onSave: (PortCustomization) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var accentColor: PortAccentColor
    @State private var icon: VideohubIcon
    @State private var group: String
    @State private var formatBadge: SignalFormatBadge?

    init(
        portKind: PortKind,
        port: PortNumber,
        videohubLabel: String,
        current: PortCustomization,
        onSave: @escaping (PortCustomization) -> Void
    ) {
        self.portKind = portKind
        self.port = port
        self.videohubLabel = videohubLabel
        self.onSave = onSave
        _displayName = State(initialValue: current.displayNameOverride ?? videohubLabel)
        _accentColor = State(initialValue: current.accentColor)
        _icon = State(initialValue: current.icon)
        _group = State(initialValue: current.group ?? "")
        _formatBadge = State(initialValue: current.formatBadge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                Text("Customize \(portKind == .source ? "Source" : "Destination")")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Port \(port.uiNumber)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("DISPLAY NAME")
                    .fieldCaptionStyle()
                TextField("Display Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("customization-display-name-field")
                HStack {
                    Text("Videohub: \(videohubLabel)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("Reset to Videohub Label") { displayName = videohubLabel }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier("customization-reset-label-button")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("COLOR")
                    .fieldCaptionStyle()
                // The palette outgrew a single row, so it wraps rather than
                // clipping swatches off the edge of the sheet.
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(24), spacing: 12),
                        count: 8
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(PortAccentColor.allCases, id: \.self) { color in
                        Button {
                            accentColor = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if accentColor == color {
                                        Circle()
                                            .stroke(Color.white, lineWidth: 2)
                                            .padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(color.displayName)
                        .accessibilityIdentifier("customization-color-\(color.rawValue)")
                        .accessibilityLabel(color.displayName)
                        .accessibilityAddTraits(accentColor == color ? .isSelected : [])
                    }
                }
                .padding(.vertical, 5)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ICON")
                    .fieldCaptionStyle()
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                    spacing: 7
                ) {
                    ForEach(VideohubIcon.allCases, id: \.self) { choice in
                        Button {
                            icon = choice
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: choice.systemImageName)
                                    .foregroundStyle(accentColor.color)
                                    .frame(width: 18)
                                Text(choice.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 31)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(icon == choice
                                        ? accentColor.color.opacity(0.16)
                                        : Color.white.opacity(0.035))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(icon == choice
                                        ? accentColor.color.opacity(0.7)
                                        : Color.white.opacity(0.06))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("customization-icon-\(choice.rawValue)")
                        .accessibilityLabel(choice.displayName)
                        .accessibilityAddTraits(icon == choice ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("GROUP")
                    .fieldCaptionStyle()
                TextField("Optional group", text: $group)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("customization-group-field")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("FORMAT BADGE")
                    .fieldCaptionStyle()
                HStack(spacing: 7) {
                    FormatBadgeChoice(
                        title: "None",
                        isSelected: formatBadge == nil
                    ) { formatBadge = nil }

                    ForEach(SignalFormatBadge.allCases, id: \.self) { candidate in
                        FormatBadgeChoice(
                            title: candidate.displayName,
                            isSelected: formatBadge == candidate
                        ) { formatBadge = candidate }
                    }
                }
                Text("Set by you — a Videohub does not report video format.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("customization-cancel-button")
                Button("Save") {
                    onSave(customization)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("customization-save-button")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var customization: PortCustomization {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVideohubLabel = videohubLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return PortCustomization(
            displayNameOverride: normalizedDisplayName == normalizedVideohubLabel
                ? nil
                : normalizedDisplayName,
            accentColor: accentColor,
            icon: icon,
            group: group,
            formatBadge: formatBadge
        )
    }
}

private struct FormatBadgeChoice: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: 44)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected
                            ? Color.accentColor.opacity(0.22)
                            : Color.white.opacity(0.035))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected
                            ? Color.accentColor.opacity(0.8)
                            : Color.white.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("customization-badge-\(title.lowercased())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    func fieldCaptionStyle() -> some View {
        font(.system(size: 9.5, weight: .bold))
            .tracking(1.05)
            .foregroundStyle(.secondary)
    }
}
