import AppKit
import SwiftUI

/// A deliberately narrow AppKit bridge for macOS 14: SwiftUI does not expose
/// NSWindow's frame autosave name, so this view configures it once and leaves
/// all application state and layout in SwiftUI.
struct WindowConfigurationView: NSViewRepresentable {
    let autosaveName: String
    var forcedFrameSize: NSSize? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowProbeView(frame: .zero)
        view.onWindowAvailable = { window in
            context.coordinator.configure(
                window,
                autosaveName: autosaveName,
                forcedFrameSize: forcedFrameSize
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.configure(
            window,
            autosaveName: autosaveName,
            forcedFrameSize: forcedFrameSize
        )
    }

    final class Coordinator {
        weak var window: NSWindow?

        func configure(
            _ window: NSWindow,
            autosaveName: String,
            forcedFrameSize: NSSize?
        ) {
            guard self.window !== window else { return }
            self.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.sharingType = .readOnly
            window.minSize = NSSize(width: 1_100, height: 700)
            if let forcedFrameSize {
                let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                let origin: NSPoint
                if let visibleFrame {
                    origin = NSPoint(
                        x: visibleFrame.midX - forcedFrameSize.width / 2,
                        y: visibleFrame.midY - forcedFrameSize.height / 2
                    )
                } else {
                    origin = window.frame.origin
                }
                window.setFrame(
                    NSRect(origin: origin, size: forcedFrameSize),
                    display: true
                )
            } else {
                _ = window.setFrameUsingName(autosaveName)
                window.setFrameAutosaveName(autosaveName)
            }
        }
    }

    final class WindowProbeView: NSView {
        var onWindowAvailable: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAvailable?(window)
            }
        }
    }
}
