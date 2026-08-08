import SwiftUI

struct RouterGridView: View {
    let store: RouterStore
    @Binding var sourceSearch: String
    @Binding var destinationSearch: String
    @Binding var sourceFilter: SourceFilter
    var focusedSearchField: FocusState<TileSearchField?>.Binding
    @Binding var relevantSearchField: TileSearchField

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                SourceSection(
                    store: store,
                    searchText: $sourceSearch,
                    selectedFilter: $sourceFilter,
                    focusedSearchField: focusedSearchField,
                    onInteraction: { relevantSearchField = .sources }
                )

                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)

                DestinationSection(
                    store: store,
                    searchText: $destinationSearch,
                    focusedSearchField: focusedSearchField,
                    onInteraction: { relevantSearchField = .destinations }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }
}
