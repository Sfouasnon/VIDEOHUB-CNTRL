import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: RouterStore
    @Bindable var bridge: ControlBridge

    @State private var isChoosingCompanionConfig = false
    @State private var companionPreview: CompanionConfigImport.Preview?
    @State private var companionFileURL: URL?
    @State private var companionError: String?
    @State private var companionSummary: String?

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

            companionSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .padding(8)
        .onAppear { store.startDiscovery() }
        .onDisappear { store.stopDiscovery() }
        .fileImporter(
            isPresented: $isChoosingCompanionConfig,
            allowedContentTypes: Self.companionConfigTypes,
            allowsMultipleSelection: false
        ) { result in
            handleCompanionSelection(result)
        }
        .sheet(item: $companionPreview) { preview in
            CompanionImportSheet(
                preview: preview,
                fileName: companionFileURL?.lastPathComponent ?? "Companion export",
                existingCustomizationCount: existingCustomizationCount,
                onSelectConnection: { reparseCompanion(connectionID: $0) },
                onApply: applyCompanionImport,
                onCancel: dismissCompanionPreview
            )
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { companionError != nil },
                set: { if !$0 { companionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { companionError = nil }
        } message: {
            Text(companionError ?? "")
        }
    }

    // MARK: - Companion import

    /// Companion writes `.companionconfig`, which is not a registered system
    /// type, so it is declared here by filename extension. `.json` is accepted
    /// too because older exports are plain JSON.
    private static let companionConfigTypes: [UTType] = {
        var types: [UTType] = [.json, .data]
        if let companion = UTType(filenameExtension: "companionconfig") {
            types.insert(companion, at: 0)
        }
        return types
    }()

    private var canImportCompanion: Bool {
        store.connectionState == .connected
    }

    private var existingCustomizationCount: Int {
        store.customizationStore.customizations.keys
            .filter { $0.routerIdentity == store.routerIdentity }
            .count
    }

    @ViewBuilder
    private var companionSection: some View {
        Section {
            Button("Import from Companion…") {
                companionSummary = nil
                isChoosingCompanionConfig = true
            }
            .disabled(!canImportCompanion)
            .accessibilityIdentifier("settings-companion-import-button")

            if let companionSummary {
                Label(companionSummary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Tile Names")
        } footer: {
            Text(companionFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Built as a plain `String` rather than inline in the `Text`: a ternary
    /// wrapping concatenated literals inside a view initializer is one of the
    /// expressions the Swift type checker struggles with.
    private var companionFooterText: String {
        guard canImportCompanion else {
            return "Connect to a router first — imported names are stored per router."
        }
        var text = "Reads port names, colors and icons out of a Bitfocus Companion export "
        text += "and applies them to this router's tiles. "
        text += "You get a preview before anything changes."
        return text
    }

    private func handleCompanionSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            companionFileURL = url
            reparseCompanion(connectionID: nil)
        case let .failure(error):
            companionError = error.localizedDescription
        }
    }

    /// Parses, or re-parses after the operator narrows to one connection.
    private func reparseCompanion(connectionID: String?) {
        guard let url = companionFileURL else { return }

        // A file chosen through the panel arrives security-scoped; without
        // this the sandbox refuses the read even though the user picked it.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            companionPreview = try CompanionConfigImport.preview(
                fileURL: url,
                routerIdentity: store.routerIdentity,
                connectionID: connectionID
            )
        } catch {
            companionPreview = nil
            companionError = error.localizedDescription
        }
    }

    private func applyCompanionImport(_ preview: CompanionConfigImport.Preview) {
        let applied = store.customizationStore.replaceCustomizations(
            forRouter: preview.routerIdentity,
            with: preview.customizations
        )

        if applied {
            let sourceCount: Int = preview.sources.count
            let destinationCount: Int = preview.destinations.count
            companionSummary = "Imported \(sourceCount) sources and \(destinationCount) destinations."
        } else {
            companionError = store.customizationStore.lastError?.localizedDescription
                ?? "The customizations could not be saved."
        }

        dismissCompanionPreview()
    }

    private func dismissCompanionPreview() {
        companionPreview = nil
        companionFileURL = nil
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
