import SwiftUI

enum SourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case cameras = "Cameras"
    case playback = "Playback"
    case graphics = "Graphics"
    case utility = "Utility"
    case village = "Village"
    case returns = "Returns"

    var id: String { rawValue }

    func matches(_ presentation: PortPresentation) -> Bool {
        if self == .all { return true }

        if presentation.group?.localizedCaseInsensitiveCompare(rawValue) == .orderedSame {
            return true
        }

        switch presentation.icon {
        case .camera:
            return self == .cameras
        case .playback:
            return self == .playback
        case .graphics:
            return self == .graphics
        case .return:
            return self == .returns
        case .monitor:
            return self == .village
        case .simulcam:
            // Simulcam is a camera feed with CG composited in, so it belongs
            // with cameras rather than in the utility catch-all.
            return self == .cameras
        case .engine, .retarget, .motionCapture:
            // Rendered and performance-driven imagery is graphics-side.
            return self == .graphics
        case .router, .multiview, .record, .genericVideo,
             .scopes, .laptop, .converter:
            return self == .utility
        }
    }
}

struct SourceSection: View {
    let store: RouterStore
    @Binding var searchText: String
    @Binding var selectedFilter: SourceFilter
    var focusedSearchField: FocusState<TileSearchField?>.Binding
    let onInteraction: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 158, maximum: 224), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("SOURCES")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.25)

                Text("\(filteredInputs.count)/\(store.inputs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                filterChips

                Spacer(minLength: 8)

                CompactSearchField(
                    prompt: "Search sources",
                    text: $searchText,
                    field: .sources,
                    focusedField: focusedSearchField,
                    onInteraction: onInteraction
                )
                .frame(width: 190)
            }

            if filteredInputs.isEmpty {
                RouterSectionEmptyState(
                    icon: "video.slash",
                    text: emptyStateText
                )
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(filteredInputs) { input in
                        SourceTile(input: input, store: store) {
                            onInteraction()
                            store.selectInput(input.id)
                        }
                    }
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 4) {
            ForEach(SourceFilter.allCases) { filter in
                Button {
                    onInteraction()
                    selectedFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: selectedFilter == filter ? .semibold : .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 23)
                        .background(
                            Capsule()
                                .fill(selectedFilter == filter
                                    ? Color.white.opacity(0.14)
                                    : Color.white.opacity(0.045))
                        )
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(selectedFilter == filter ? 0.16 : 0.06))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("source-filter-\(filter.rawValue.lowercased())")
                .accessibilityLabel(filter.rawValue)
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
            }
        }
    }

    private var filteredInputs: [VideoInput] {
        store.inputs.filter { input in
            let presentation = store.presentation(for: input)
            let filterMatches = selectedFilter.matches(presentation)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty
                || presentation.displayName.localizedCaseInsensitiveContains(query)
                || (presentation.group?.localizedCaseInsensitiveContains(query) ?? false)
                || input.id.displayText == query
            return filterMatches && searchMatches
        }
    }

    private var emptyStateText: String {
        if store.inputs.isEmpty {
            return store.connectionState == .connected
                ? "Waiting for Videohub inputs…"
                : "Connect to a Videohub to load sources"
        }
        return "No sources match these filters"
    }
}

struct CompactSearchField: View {
    let prompt: String
    @Binding var text: String
    let field: TileSearchField
    var focusedField: FocusState<TileSearchField?>.Binding
    let onInteraction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier(field == .sources
                    ? "source-search-field"
                    : "destination-search-field")
                .focused(focusedField, equals: field)
                .onTapGesture { onInteraction() }

            if !text.isEmpty {
                Button {
                    text = ""
                    onInteraction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(field == .sources
                    ? "clear-source-search-button"
                    : "clear-destination-search-button")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.08))
        }
    }
}

struct RouterSectionEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), style: StrokeStyle(dash: [5]))
        }
    }
}
