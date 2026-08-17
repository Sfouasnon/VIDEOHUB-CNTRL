import SwiftUI

/// Shows what a Companion export would do before it does it.
///
/// The CLI equivalent prints a preview and only writes when passed `--write`.
/// Import replaces every tile customization for the router, so the same
/// deliberate second step is worth keeping on screen: an operator who picked
/// the wrong cart's export should see that before their labels are gone.
struct CompanionImportSheet: View {
    let preview: CompanionConfigImport.Preview
    let fileName: String
    let existingCustomizationCount: Int
    let onSelectConnection: (String?) -> Void
    let onApply: (CompanionConfigImport.Preview) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if preview.entries.isEmpty {
                emptyState
            } else {
                entryList
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from Companion")
                .font(.headline)

            Text(fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 16) {
                Label(sourceCountText, systemImage: "arrow.right.circle")
                Label(destinationCountText, systemImage: "target")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            LabeledContent("Router") {
                Text(preview.routerIdentity)
                    .font(.callout.monospaced())
            }

            if preview.connections.count > 1 {
                Picker("Companion connection", selection: connectionBinding) {
                    Text("All Videohub connections").tag(String?.none)
                    ForEach(preview.connections) { connection in
                        Text(Self.connectionLabel(connection))
                            .tag(String?.some(connection.id))
                    }
                }
                .accessibilityIdentifier("companion-import-connection-picker")

                Text(Self.multipleConnectionsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private static let multipleConnectionsHint =
        "This export drives more than one router. Pick the connection that matches "
        + "the Videohub you are importing onto."

    private var sourceCountText: String {
        let count: Int = preview.sources.count
        return "\(count) sources"
    }

    private var destinationCountText: String {
        let count: Int = preview.destinations.count
        return "\(count) destinations"
    }

    private static func connectionLabel(_ connection: CompanionConfigImport.Connection) -> String {
        let count: Int = connection.routeKeyCount
        return "\(connection.label) — \(count) keys"
    }

    private var connectionBinding: Binding<String?> {
        Binding(
            get: { preview.selectedConnectionID },
            set: { onSelectConnection($0) }
        )
    }

    private var entryList: some View {
        List {
            if !preview.sources.isEmpty {
                Section("Sources") {
                    ForEach(preview.sources) { entry in
                        CompanionImportRow(entry: entry)
                    }
                }
            }
            if !preview.destinations.isEmpty {
                Section("Destinations") {
                    ForEach(preview.destinations) { entry in
                        CompanionImportRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("companion-import-list")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Nothing to import from this connection.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Composed as a `String` first. Interpolation wrapping a ternary, inside a
    /// concatenation, inside a view initializer is exactly the shape that makes
    /// the Swift type checker time out.
    private var replacementWarning: String {
        let noun: String = existingCustomizationCount == 1 ? "tile" : "tiles"
        return "Replaces \(existingCustomizationCount) existing \(noun) on this router."
    }

    private var importButtonTitle: String {
        "Import \(preview.entries.count) Tiles"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if existingCustomizationCount > 0 {
                Label(replacementWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Names, colors and icons only. Crosspoints are never imported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("companion-import-cancel")

                Button(importButtonTitle) { onApply(preview) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(preview.entries.isEmpty)
                    .accessibilityIdentifier("companion-import-apply")
            }
        }
        .padding(16)
    }
}

private struct CompanionImportRow: View {
    let entry: CompanionConfigImport.Entry

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.uiNumber)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            Image(systemName: entry.icon.systemImageName)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(entry.accentColor.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("companion-import-row-\(entry.id)")
    }
}
