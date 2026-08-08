import Foundation

/// The deliberately small SF Symbols set offered by tile customization.
enum VideohubIcon: String, Codable, CaseIterable, Hashable, Sendable {
    case camera
    case monitor
    case playback
    case multiview
    case router
    case `return`
    case record
    case graphics
    case genericVideo

    // Virtual production and post pipeline sources.
    case scopes
    case motionCapture
    case retarget
    case simulcam
    case engine
    case laptop
    case converter

    var displayName: String {
        switch self {
        case .camera: "Camera"
        case .monitor: "Monitor"
        case .playback: "Playback"
        case .multiview: "Multiview"
        case .router: "Router"
        case .return: "Return"
        case .record: "Record"
        case .graphics: "Graphics"
        case .genericVideo: "Generic Video"
        case .scopes: "Scopes"
        case .motionCapture: "Motion Capture"
        case .retarget: "Retarget"
        case .simulcam: "Simulcam"
        case .engine: "Engine"
        case .laptop: "Laptop"
        case .converter: "Converter"
        }
    }

    /// A macOS 14-compatible SF Symbol name for the icon picker and tiles.
    ///
    /// Pipeline concepts have no literal symbol, so each is mapped to the
    /// closest shape that still reads at tile size. `engine` is named
    /// generically rather than after any one product, since the symbol set
    /// carries no third-party brand marks.
    var systemImageName: String {
        switch self {
        case .camera: "video.fill"
        case .monitor: "display"
        case .playback: "play.rectangle.fill"
        case .multiview: "rectangle.grid.2x2.fill"
        case .router: "point.3.connected.trianglepath.dotted"
        case .return: "arrow.uturn.backward.circle.fill"
        case .record: "record.circle"
        case .graphics: "photo.on.rectangle.angled"
        case .genericVideo: "rectangle.stack.fill"
        case .scopes: "waveform"
        case .motionCapture: "figure.walk.motion"
        case .retarget: "arrow.2.squarepath"
        case .simulcam: "camera.filters"
        case .engine: "cube.transparent"
        case .laptop: "laptopcomputer"
        case .converter: "arrow.left.arrow.right"
        }
    }
}
