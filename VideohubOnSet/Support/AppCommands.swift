import SwiftUI

struct RouteCommandActions {
    let canTake: Bool
    let canClearSelection: Bool
    let take: () -> Void
    let clearSelection: () -> Void
    let focusSearch: () -> Void
}

private struct RouteCommandActionsKey: FocusedValueKey {
    typealias Value = RouteCommandActions
}

extension FocusedValues {
    var routeCommandActions: RouteCommandActions? {
        get { self[RouteCommandActionsKey.self] }
        set { self[RouteCommandActionsKey.self] = newValue }
    }
}

struct VideohubCommands: Commands {
    @FocusedValue(\.routeCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Route") {
            Button("Take Route") { actions?.take() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.canTake != true)

            Button("Clear Selection") { actions?.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(actions?.canClearSelection != true)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find Tiles") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}
