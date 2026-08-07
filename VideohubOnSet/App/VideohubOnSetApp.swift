import AppKit
import SwiftUI

@main
struct VideohubOnSetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: RouterStore
    @State private var bridge: ControlBridge
    private let developmentWindowSize: NSSize?

    init() {
        let routerStore: RouterStore
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let demoPortCount: Int?
        if let sizeFlag = arguments.firstIndex(of: "--demo-size"),
           arguments.indices.contains(sizeFlag + 1),
           let requestedSize = Int(arguments[sizeFlag + 1]) {
            demoPortCount = max(1, requestedSize)
        } else {
            demoPortCount = arguments.contains("--demo") ? 40 : nil
        }
        if let sizeFlag = arguments.firstIndex(of: "--window-size"),
           arguments.indices.contains(sizeFlag + 2),
           let width = Double(arguments[sizeFlag + 1]),
           let height = Double(arguments[sizeFlag + 2]) {
            developmentWindowSize = NSSize(
                width: max(1_100, width),
                height: max(700, height)
            )
        } else {
            developmentWindowSize = nil
        }
        let qaDefaults: UserDefaults
        let qaCustomizationStore: CustomizationStore?
        if let sessionFlag = arguments.firstIndex(of: "--qa-session"),
           arguments.indices.contains(sessionFlag + 1) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let session = arguments[sessionFlag + 1]
                .unicodeScalars
                .filter { allowed.contains($0) }
                .map(String.init)
                .joined()
            let safeSession = session.isEmpty ? "session" : session
            qaDefaults = UserDefaults(
                suiteName: "com.videohubonset.VideohubOnSet.QA.\(safeSession)"
            ) ?? .standard
            let customizationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "VideohubOnSet-QA-\(safeSession)-Customizations.json",
                    isDirectory: false
                )
            qaCustomizationStore = CustomizationStore(fileURL: customizationURL)
        } else {
            qaDefaults = .standard
            qaCustomizationStore = nil
        }
        let developmentPort: UInt16
        if let portFlag = arguments.firstIndex(of: "--port"),
           arguments.indices.contains(portFlag + 1),
           let parsedPort = UInt16(arguments[portFlag + 1]) {
            developmentPort = parsedPort
        } else {
            developmentPort = 9990
        }
        routerStore = RouterStore(
            defaults: qaDefaults,
            customizationStore: qaCustomizationStore,
            demoPortCount: demoPortCount,
            connectionPort: developmentPort
        )
        if let hostFlag = arguments.firstIndex(of: "--host"),
           arguments.indices.contains(hostFlag + 1) {
            routerStore.host = arguments[hostFlag + 1]
        }
#else
        developmentWindowSize = nil
        routerStore = RouterStore()
#endif
        _store = State(initialValue: routerStore)
#if DEBUG
        _bridge = State(initialValue: ControlBridge(store: routerStore, defaults: qaDefaults))
#else
        _bridge = State(initialValue: ControlBridge(store: routerStore))
#endif
    }

    var body: some Scene {
        Window("Videohub On-Set", id: "main") {
            ContentView(store: store)
                .preferredColorScheme(.dark)
                .background {
                    WindowConfigurationView(
                        autosaveName: "VideohubOnSet.MainWindowFrame",
                        forcedFrameSize: developmentWindowSize
                    )
                    .frame(width: 0, height: 0)
                }
                .task {
                    store.start()
                    bridge.start()
                    await runDevelopmentRouteIfRequested()
                }
        }
        .defaultSize(width: 1_360, height: 860)
        .windowResizability(.contentMinSize)
        .commands { VideohubCommands() }

        Settings {
            SettingsView(store: store, bridge: bridge)
                .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private func runDevelopmentRouteIfRequested() async {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--integration-route"),
              arguments.indices.contains(flagIndex + 2),
              let inputUI = Int(arguments[flagIndex + 1]),
              let outputUI = Int(arguments[flagIndex + 2]),
              let input = PortNumber(uiNumber: inputUI),
              let output = PortNumber(uiNumber: outputUI) else { return }

        for _ in 0..<100 {
            if store.connectionState == .connected,
               store.inputs.contains(where: { $0.id == input }),
               store.outputs.contains(where: { $0.id == output }) {
                store.selectInput(input)
                store.selectOutput(output)
                store.requestTake()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
#endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
#if DEBUG
        captureDevelopmentSnapshotIfRequested()
#endif
    }

#if DEBUG
    private func captureDevelopmentSnapshotIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--capture-ui"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let destination = URL(fileURLWithPath: arguments[flagIndex + 1])
        let delay: TimeInterval
        if let delayFlag = arguments.firstIndex(of: "--capture-delay"),
           arguments.indices.contains(delayFlag + 1),
           let parsedDelay = TimeInterval(arguments[delayFlag + 1]) {
            delay = max(0.1, parsedDelay)
        } else {
            delay = 1.5
        }

        captureDevelopmentSnapshot(
            to: destination,
            attemptsRemaining: 20,
            delay: delay
        )
    }

    private func captureDevelopmentSnapshot(
        to destination: URL,
        attemptsRemaining: Int,
        delay: TimeInterval = 0.5
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let contentView = window.contentView else {
                if attemptsRemaining > 1 {
                    self.captureDevelopmentSnapshot(
                        to: destination,
                        attemptsRemaining: attemptsRemaining - 1,
                        delay: 0.5
                    )
                }
                return
            }

            if destination.pathExtension.lowercased() == "pdf" {
                let pdf = contentView.dataWithPDF(inside: contentView.bounds)
                try? pdf.write(to: destination, options: .atomic)
                return
            }

            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(
                in: contentView.bounds
            ) else { return }
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: destination, options: .atomic)
        }
    }
#endif
}
