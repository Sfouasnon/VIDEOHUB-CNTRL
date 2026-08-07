import SwiftUI

struct SettingsView: View {
    @Bindable var store: RouterStore
    @Bindable var bridge: ControlBridge

    var body: some View {
        Form {
            Section("Router") {
                TextField("Videohub Host/IP", text: $store.host)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-host-field")
                    .onSubmit { store.applyHostChange() }
                    .help("The host used for the next connection")

                if store.hasUnappliedHostChange {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Reconnect to switch to this host")
                        Spacer()
                        Button("Reconnect") { store.applyHostChange() }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings-reconnect-button")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                LabeledContent("TCP Port", value: "9990")
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.discoveredDevices.isEmpty {
                    HStack(spacing: 7) {
                        if store.isDiscovering {
                            ProgressView().controlSize(.small)
                        }
                        Text(store.isDiscovering
                            ? "Searching for Videohubs…"
                            : "No Videohubs found on this network.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else {
                    ForEach(store.discoveredDevices) { device in
                        DiscoveredVideohubRow(
                            device: device,
                            isCurrent: isCurrent(device),
                            connect: { store.connect(to: device) }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Discovered on Network")
                    Spacer()
                    Button("Scan Again") { store.rescanDiscovery() }
                        .controlSize(.small)
                        .accessibilityIdentifier("settings-rescan-button")
                }
            } footer: {
                Text("Videohubs advertise themselves over Bonjour. "
                    + "Routers on another subnet won't appear — enter those by IP above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Routing") {
                Toggle("Reconnect automatically", isOn: $store.reconnectAutomatically)
                    .accessibilityIdentifier("settings-reconnect-toggle")
                Toggle("Confirm before TAKE", isOn: $store.confirmBeforeTake)
                    .accessibilityIdentifier("settings-confirm-toggle")
            }

            Section {
                Toggle("Enable surface control", isOn: $bridge.isEnabled)
                    .accessibilityIdentifier("settings-control-toggle")

                if bridge.isEnabled {
                    LabeledContent("Port") {
                        TextField(
                            "Port",
                            value: $bridge.port,
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit { bridge.restart() }
                        .accessibilityIdentifier("settings-control-port-field")
                    }

                    if bridge.hasUnappliedPortChange {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Restart to listen on this port")
                            Spacer()
                            Button("Restart") { bridge.restart() }
                                .controlSize(.small)
                                .accessibilityIdentifier("settings-control-restart-button")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    LabeledContent("Status", value: bridge.status.summary)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("settings-control-status")

                    LabeledContent(
                        "Connected surfaces",
                        value: "\(bridge.connectedSurfaces)"
                    )
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Stream Deck & Surface Control")
            } footer: {
                Text("Lets the Stream Deck plugin drive this router using the "
                    + "names, colors, icons, and salvos configured here. "
                    + "Listens on 127.0.0.1 only — never on the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .padding(8)
        .onAppear { store.startDiscovery() }
        .onDisappear { store.stopDiscovery() }
    }

    private var statusColor: Color {
        switch bridge.status {
        case .running: .green
        case .failed: .orange
        case .starting, .disabled: .secondary
        }
    }

    private func isCurrent(_ device: DiscoveredVideohub) -> Bool {
        guard let host = device.host else { return false }
        return host.caseInsensitiveCompare(
            store.host.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }
}

private struct DiscoveredVideohubRow: View {
    let device: DiscoveredVideohub
    let isCurrent: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isReachable
                ? "checkmark.circle.fill"
                : "questionmark.circle")
                .foregroundStyle(device.isReachable ? Color.green : Color.secondary)
                .help(device.isReachable
                    ? "Responded on the Videohub control port"
                    : "Advertised over Bonjour but did not answer the control port")

            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { connect() }
                    .controlSize(.small)
                    .disabled(!device.isConnectable)
            }
        }
        .accessibilityIdentifier("discovered-device-\(device.id)")
    }
}
