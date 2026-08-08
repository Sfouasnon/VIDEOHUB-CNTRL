import SwiftUI

struct ActionPanel: View {
    @Bindable var store: RouterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            connectionHeader

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 13)

            Text("SOURCE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.25)
                .foregroundStyle(.secondary)

            sourceSelection
                .padding(.top, 6)

            HStack {
                Spacer()
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: 27)

            Text("DESTINATION")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.25)
                .foregroundStyle(.secondary)

            destinationSelection
                .padding(.top, 6)

            Button { store.requestTake() } label: {
                HStack(spacing: 8) {
                    if store.pendingRoute != nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(store.pendingRoute == nil ? "TAKE ROUTE" : "ROUTING…")
                        .font(.system(size: 14, weight: .heavy))
                        .tracking(0.65)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(TakeRouteButtonStyle(isEnabled: store.canTake))
            .accessibilityIdentifier("take-route-button")
            .disabled(!store.canTake)
            .help(store.takeDisabledReason ?? "Send the selected source to the selected destination")
            .padding(.top, 15)

            if let reason = store.takeDisabledReason,
               store.selectedInputID != nil || store.selectedOutputID != nil {
                Text(reason)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(reason.contains("locked") ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .padding(.top, 6)
            }

            routePreview
                .padding(.top, 11)

            Button("Clear Selection") { store.clearSelection() }
                .buttonStyle(.plain)
                .accessibilityIdentifier("clear-selection-button")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .disabled(store.selectedInputID == nil && store.selectedOutputID == nil)
                .padding(.top, 10)

            Spacer(minLength: 12)

            routerConnectionControl
        }
        .padding(14)
        .background(Color.black.opacity(0.26))
        .overlay(alignment: .bottomLeading) {
            if let notice = store.notice {
                OperatorNoticeView(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 108)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.notice?.id)
    }

    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.routerDisplayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.7), radius: 3)
                Text(store.connectionState.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("connection-status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private var sourceSelection: some View {
        if let input = store.selectedInput {
            let presentation = store.presentation(for: input)
            RouteSelectionCard(
                port: input.id,
                name: presentation.displayName,
                group: presentation.group,
                icon: presentation.icon,
                accent: presentation.accentColor.color
            )
        } else {
            EmptyRouteSelectionCard(text: "Choose a source")
        }
    }

    @ViewBuilder
    private var destinationSelection: some View {
        if let output = store.selectedOutput {
            let presentation = store.presentation(for: output)
            RouteSelectionCard(
                port: output.id,
                name: presentation.displayName,
                group: presentation.group,
                icon: presentation.icon,
                accent: presentation.accentColor.color,
                lockState: store.lockState(for: output.id)
            )
        } else {
            EmptyRouteSelectionCard(text: "Choose a destination")
        }
    }

    private var routePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTE PREVIEW")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)

            HStack(spacing: 7) {
                Text(selectedInputName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(selectedOutputName)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(store.selectedInputID != nil && store.selectedOutputID != nil
                ? AnyShapeStyle(Color.primary)
                : AnyShapeStyle(Color.secondary))
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06))
        }
    }

    private var routerConnectionControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            Text("ROUTER")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                TextField("192.168.1.50", text: $store.host)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("router-host-field")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(store.hasUnappliedHostChange
                                ? Color.orange.opacity(0.55)
                                : Color.white.opacity(0.08))
                    }
                    .onSubmit { store.applyHostChange() }

                discoveryMenu
            }

            if store.hasUnappliedHostChange {
                Text("Press Return to switch routers")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Button(store.connectionState == .offline ? "Connect" : "Disconnect") {
                store.toggleConnection()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("connection-button")
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.startDiscovery() }
        .onDisappear { store.stopDiscovery() }
    }

    private var discoveryMenu: some View {
        Menu {
            if store.discoveredDevices.isEmpty {
                Text(store.isDiscovering ? "Searching…" : "No Videohubs found yet")
            } else {
                ForEach(store.discoveredDevices) { device in
                    Button {
                        store.connect(to: device)
                    } label: {
                        Text(device.isReachable
                            ? "\(device.displayName) — \(device.subtitle)"
                            : "\(device.displayName) — \(device.subtitle) (unverified)")
                    }
                    .disabled(!device.isConnectable)
                }
            }

            Divider()

            Button("Scan Again") { store.rescanDiscovery() }
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 28)
        .accessibilityIdentifier("discovery-menu")
        .help("Find Videohubs on this network")
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .offline: .red
        case .connecting: .orange
        case .connected: .green
        }
    }

    private var selectedInputName: String {
        store.selectedInput.map { store.presentation(for: $0).displayName } ?? "Source"
    }

    private var selectedOutputName: String {
        store.selectedOutput.map { store.presentation(for: $0).displayName } ?? "Destination"
    }
}

private struct RouteSelectionCard: View {
    let port: PortNumber
    let name: String
    let group: String?
    let icon: VideohubIcon
    let accent: Color
    var lockState: OutputLockState = .unlocked

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", port.uiNumber))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
                .frame(width: 38, height: 29)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accent.opacity(0.35))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let group, !group.isEmpty {
                    Text(group)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: statusIconName ?? icon.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusIconColor ?? accent)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(accent)
                .frame(height: 2)
                .clipShape(.rect(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
        }
    }

    private var statusIconName: String? {
        switch lockState {
        case .unlocked: nil
        case .ownedByThisClient, .lockedByOther: "lock.fill"
        case .unknown: "questionmark.diamond.fill"
        }
    }

    private var statusIconColor: Color? {
        switch lockState {
        case .unlocked: nil
        case .ownedByThisClient: .secondary
        case .lockedByOther: .orange
        case .unknown: .yellow
        }
    }
}

private struct EmptyRouteSelectionCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.dashed")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), style: StrokeStyle(dash: [4]))
        }
    }
}

private struct TakeRouteButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.38))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isEnabled
                        ? Color.accentColor
                        : Color.white.opacity(0.055))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isEnabled ? Color.cyan.opacity(0.38) : Color.white.opacity(0.06))
            }
            .shadow(
                color: isEnabled ? Color.blue.opacity(configuration.isPressed ? 0.18 : 0.38) : .clear,
                radius: configuration.isPressed ? 3 : 8
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct OperatorNoticeView: View {
    let notice: OperatorNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(color.opacity(0.2))
        }
    }

    private var icon: String {
        switch notice.kind {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .information: .cyan
        case .success: .green
        case .error: .orange
        }
    }
}
