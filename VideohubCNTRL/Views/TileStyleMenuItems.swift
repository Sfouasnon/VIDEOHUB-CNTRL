import SwiftUI

/// The style copy/paste block shared by source and destination tile menus.
///
/// A tile's colour, icon, and group travel together; its display name never
/// does, because a name belongs to one physical port.
struct TileStyleMenuItems: View {
    let store: RouterStore
    let isStyleSelected: Bool
    let copyStyle: () -> Void
    let pasteStyle: () -> Void
    let toggleSelection: () -> Void

    var body: some View {
        Button("Copy Style", action: copyStyle)
            .accessibilityIdentifier("copy-style-menu-item")

        Button(pasteTitle, action: pasteStyle)
            .disabled(store.copiedStyle == nil)
            .accessibilityIdentifier("paste-style-menu-item")

        Divider()

        Button(isStyleSelected ? "Remove from Selection" : "Add to Selection",
               action: toggleSelection)
            .accessibilityIdentifier("toggle-style-selection-menu-item")

        if store.styleSelectionCount > 0 {
            Button(bulkPasteTitle) { store.pasteStyleOntoSelection() }
                .disabled(store.copiedStyle == nil)
                .accessibilityIdentifier("paste-style-to-selection-menu-item")

            Button("Clear Selection (\(store.styleSelectionCount))") {
                store.clearStyleSelection()
            }
            .accessibilityIdentifier("clear-style-selection-menu-item")
        }
    }

    private var pasteTitle: String {
        guard let copied = store.copiedStyle else { return "Paste Style" }
        return "Paste Style — \(copied.summary)"
    }

    private var bulkPasteTitle: String {
        let count = store.styleSelectionCount
        return "Paste Style to \(count) Selected Tile\(count == 1 ? "" : "s")"
    }
}
