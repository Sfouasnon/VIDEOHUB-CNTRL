import SwiftUI

struct DestinationSection: View {
    let store: RouterStore
    @Binding var searchText: String
    var focusedSearchField: FocusState<TileSearchField?>.Binding
    let onInteraction: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 224), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("DESTINATIONS")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.25)

                Text("\(filteredOutputs.count)/\(store.outputs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                CompactSearchField(
                    prompt: "Search destinations",
                    text: $searchText,
                    field: .destinations,
                    focusedField: focusedSearchField,
                    onInteraction: onInteraction
                )
                .frame(width: 210)
            }

            if filteredOutputs.isEmpty {
                RouterSectionEmptyState(
                    icon: "display.trianglebadge.exclamationmark",
                    text: emptyStateText
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(filteredOutputs) { output in
                        DestinationTile(output: output, store: store) {
                            onInteraction()
                            store.selectOutput(output.id)
                        }
                    }
                }
            }
        }
    }

    private var filteredOutputs: [VideoOutput] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.outputs.filter { output in
            let presentation = store.presentation(for: output)
            guard !query.isEmpty else { return true }
            if presentation.displayName.localizedCaseInsensitiveContains(query)
                || (presentation.group?.localizedCaseInsensitiveContains(query) ?? false)
                || output.id.displayText == query {
                return true
            }
            if let input = store.routedInput(for: output.id) {
                return store.presentation(for: input).displayName.localizedCaseInsensitiveContains(query)
            }
            return false
        }
    }

    private var emptyStateText: String {
        if store.outputs.isEmpty {
            return store.connectionState == .connected
                ? "Waiting for Videohub outputs…"
                : "Connect to a Videohub to load destinations"
        }
        return "No destinations match this search"
    }
}
