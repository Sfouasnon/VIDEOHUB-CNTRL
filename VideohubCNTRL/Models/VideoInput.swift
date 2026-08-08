import Foundation

struct VideoInput: Identifiable, Hashable, Sendable {
    let id: PortNumber
    var videohubLabel: String

    init(id: PortNumber, videohubLabel: String? = nil) {
        self.id = id
        self.videohubLabel = videohubLabel ?? "Input \(id.uiNumber)"
    }
}
