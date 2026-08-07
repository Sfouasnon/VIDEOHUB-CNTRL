import SwiftUI

/// The salvo surface: a grid of operator-authored buttons, each taking several
/// crosspoints at once.
struct MacrosView: View {
    // Observation tracks @Observable reads in `body` without @Bindable; this
    // view never needs a binding into the store itself.
    let store: RouterStore
    @State private var editingSalvo: Salvo?
    @State private var salvoPendingDeletion: Salvo?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.35)

            if store.salvos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.salvos) { salvo in
                            SalvoButton(
                                salvo: salvo,
                                isRunning: store.pendingSalvo?.salvoID == salvo.id,
                                disabledReason: store.fireDisabledReason(for: salvo),
                                fire: { store.fireSalvo(salvo) },
                                edit: { editingSalvo = salvo },
                                delete: { salvoPendingDeletion = salvo }
                            )
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingSalvo) { salvo in
            SalvoEditorView(store: store, salvo: salvo)
        }
        .confirmationDialog(
            "Delete this salvo?",
            isPresented: Binding(
                get: { salvoPendingDeletion != nil },
                set: { if !$0 { salvoPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let salvoPendingDeletion {
                    store.deleteSalvo(id: salvoPendingDeletion.id)
                }
                salvoPendingDeletion = nil
            }
            .accessibilityIdentifier("confirm-delete-salvo-button")
            Button("Cancel", role: .cancel) { salvoPendingDeletion = nil }
        } message: {
            Text(salvoPendingDeletion?.displayName ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SALVOS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.25)
                    .foregroundStyle(.secondary)
                Text(store.routerDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editingSalvo = Salvo()
            } label: {
                Label("New Salvo", systemImage: "plus")
            }
            .controlSize(.small)
            .accessibilityIdentifier("new-salvo-button")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No salvos yet")
                .font(.system(size: 14, weight: .semibold))
            Text("A salvo takes several crosspoints at once — "
                + "one button for a whole camera or record setup.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Create a Salvo") { editingSalvo = Salvo() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Salvo button

private struct SalvoButton: View {
    let salvo: Salvo
    let isRunning: Bool
    let disabledReason: String?
    let fire: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    private var accent: Color { salvo.accentColor.color }
    private var isEnabled: Bool { disabledReason == nil }

    var body: some View {
        Button(action: fire) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: salvo.icon.systemImageName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer(minLength: 0)
                    if isRunning {
                        ProgressView().controlSize(.small)
                    }
                }

                Spacer(minLength: 8)

                Text(salvo.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(salvo.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(isEnabled ? 0.13 : 0.05))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(accent.opacity(isEnabled ? 0.42 : 0.14))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(accent.opacity(isEnabled ? 1 : 0.3))
                    .frame(height: 2)
                    .clipShape(.rect(bottomLeadingRadius: 9, bottomTrailingRadius: 9))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(disabledReason ?? "Fire \(salvo.displayName)")
        .accessibilityIdentifier("salvo-button-\(salvo.id.uuidString)")
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

// MARK: - Editor

private struct SalvoEditorView: View {
    let store: RouterStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Salvo
    @State private var selectedOutput: PortNumber?
    @State private var selectedInput: PortNumber?

    init(store: RouterStore, salvo: Salvo) {
        self.store = store
        _draft = State(initialValue: salvo)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Salvo") {
                    TextField("Name", text: Binding(
                        get: { draft.name },
                        set: { draft.setName($0) }
                    ))
                    .accessibilityIdentifier("salvo-name-field")

                    Picker("Colour", selection: $draft.accentColor) {
                        ForEach(PortAccentColor.allCases, id: \.self) { colour in
                            Text(colour.displayName).tag(colour)
                        }
                    }

                    Picker("Icon", selection: $draft.icon) {
                        ForEach(VideohubIcon.allCases, id: \.self) { icon in
                            Label(icon.displayName, systemImage: icon.systemImageName)
                                .tag(icon)
                        }
                    }
                }

                Section {
                    if draft.crosspoints.isEmpty {
                        Text("No crosspoints yet.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(draft.crosspoints) { crosspoint in
                            HStack(spacing: 8) {
                                Text(sourceName(crosspoint.input))
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                Text(destinationName(crosspoint.output))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    draft.removeCrosspoint(output: crosspoint.output)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this crosspoint")
                            }
                            .font(.callout)
                        }
                    }
                } header: {
                    Text("Crosspoints")
                } footer: {
                    Text("Each destination can appear once. Adding a destination "
                        + "again replaces its source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Add Crosspoint") {
                    Picker("Source", selection: $selectedInput) {
                        Text("Choose…").tag(PortNumber?.none)
                        ForEach(store.inputs) { input in
                            Text(sourceName(input.id)).tag(PortNumber?.some(input.id))
                        }
                    }
                    Picker("Destination", selection: $selectedOutput) {
                        Text("Choose…").tag(PortNumber?.none)
                        ForEach(store.outputs) { output in
                            Text(destinationName(output.id)).tag(PortNumber?.some(output.id))
                        }
                    }
                    Button("Add") {
                        if let selectedInput, let selectedOutput {
                            draft.setCrosspoint(output: selectedOutput, input: selectedInput)
                            self.selectedOutput = nil
                        }
                    }
                    .disabled(selectedInput == nil || selectedOutput == nil)
                    .accessibilityIdentifier("add-crosspoint-button")

                    if store.inputs.isEmpty || store.outputs.isEmpty {
                        Text("Connect to a router to pick ports by name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    if store.saveSalvo(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isFireable)
                .help(draft.isFireable ? "Save this salvo" : "Add at least one crosspoint")
                .accessibilityIdentifier("save-salvo-button")
            }
            .padding(12)
        }
        .frame(width: 470, height: 560)
    }

    private func sourceName(_ port: PortNumber) -> String {
        guard let input = store.inputs.first(where: { $0.id == port }) else {
            return "Source \(port.uiNumber)"
        }
        return "\(port.uiNumber). \(store.presentation(for: input).displayName)"
    }

    private func destinationName(_ port: PortNumber) -> String {
        guard let output = store.outputs.first(where: { $0.id == port }) else {
            return "Destination \(port.uiNumber)"
        }
        return "\(port.uiNumber). \(store.presentation(for: output).displayName)"
    }
}
