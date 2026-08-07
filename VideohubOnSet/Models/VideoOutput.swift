import Foundation

struct VideoOutput: Identifiable, Hashable, Sendable {
    let id: PortNumber
    var videohubLabel: String

    init(id: PortNumber, videohubLabel: String? = nil) {
        self.id = id
        self.videohubLabel = videohubLabel ?? "Output \(id.uiNumber)"
    }
}
