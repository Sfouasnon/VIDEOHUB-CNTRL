import SwiftUI

enum TileSearchField: Hashable {
    case sources
    case destinations
}

/// The two working surfaces: the live crosspoint matrix, and the salvo buttons.
enum WorkspacePage: String, CaseIterable, Hashable {
    case router
    case macros

    var title: String {
        switch self {
        case .router: "Router"
        case .macros: "Macros"
        }
    }

    var systemImageName: String {
        switch self {
        case .router: "square.grid.3x3"
        case .macros: "bolt.square"
        }
    }
}

struct ContentView: View {
    @Bindable var store: RouterStore
    @State private var sourceSearch = ""
    @State private var destinationSearch = ""
    @State private var sourceFilter: SourceFilter = .all
    @State private var relevantSearchField: TileSearchField = .sources
    @State private var page: WorkspacePage = .router
    @FocusState private var focusedSearchField: TileSearchField?

    var body: some View {
        HStack(spacing: 0) {
            ActionPanel(store: store)
                .frame(width: 242)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                pagePicker

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)

                switch page {
                case .router:
                    RouterGridView(
                        store: store,
                        sourceSearch: $sourceSearch,
                        destinationSearch: $destinationSearch,
                        sourceFilter: $sourceFilter,
                        focusedSearchField: $focusedSearchField,
                        relevantSearchField: $relevantSearchField
                    )
                case .macros:
                    MacrosView(store: store)
                }
            }
        }
        .frame(minWidth: 1_100, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(
            \.routeCommandActions,
            RouteCommandActions(
                canTake: store.canTake,
                canClearSelection: store.selectedInputID != nil || store.selectedOutputID != nil,
                take: { store.requestTake() },
                clearSelection: {
                    focusedSearchField = nil
                    store.clearSelection()
                },
                focusSearch: {
                    focusedSearchField = relevantSearchField
                }
            )
        )
        .confirmationDialog(
            "Take this route?",
            isPresented: $store.isTakeConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("TAKE ROUTE") { store.confirmTake() }
                .accessibilityIdentifier("confirm-take-button")
            Button("Cancel", role: .cancel) { store.cancelTakeConfirmation() }
                .accessibilityIdentifier("cancel-take-button")
        } message: {
            Text(confirmationDescription)
        }
    }

    private var pagePicker: some View {
        HStack {
            Picker("", selection: $page) {
                ForEach(WorkspacePage.allCases, id: \.self) { candidate in
                    Label(candidate.title, systemImage: candidate.systemImageName)
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .accessibilityIdentifier("workspace-page-picker")

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var confirmationDescription: String {
        let input = store.selectedInput.map { store.presentation(for: $0).displayName }
            ?? "Selected source"
        let output = store.selectedOutput.map { store.presentation(for: $0).displayName }
            ?? "selected destination"
        return "\(input) → \(output)"
    }
}
