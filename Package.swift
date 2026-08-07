// swift-tools-version: 5.10

import PackageDescription
import Foundation

let commandLineToolsDeveloperDirectory = "/Library/Developer/CommandLineTools"
let commandLineToolsFrameworkDirectory =
    "\(commandLineToolsDeveloperDirectory)/Library/Developer/Frameworks"
let commandLineToolsTestingFramework =
    "\(commandLineToolsFrameworkDirectory)/Testing.framework"

let selectedDeveloperDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(
        atPath: "/var/db/xcode_select_link"
    ))

let usesCommandLineToolsTestingFramework =
    selectedDeveloperDirectory?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        == commandLineToolsDeveloperDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    && FileManager.default.fileExists(atPath: commandLineToolsTestingFramework)

let testSwiftSettings: [SwiftSetting] = usesCommandLineToolsTestingFramework
    ? [.unsafeFlags(["-F", commandLineToolsFrameworkDirectory])]
    : []

let testLinkerSettings: [LinkerSetting] = usesCommandLineToolsTestingFramework
    ? [
        .unsafeFlags([
            "-F", commandLineToolsFrameworkDirectory,
            "-framework", "Testing"
        ])
    ]
    : []

let package = Package(
    name: "VideohubOnSet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VideohubOnSet",
            targets: ["VideohubOnSet"]
        )
    ],
    targets: [
        .executableTarget(
            name: "VideohubOnSet",
            path: "VideohubOnSet",
            // The asset catalog is consumed by the Xcode app target. SwiftPM
            // builds a bare executable with no bundle, so it would only warn
            // about an unhandled resource.
            exclude: ["VideohubOnSet.entitlements", "Assets.xcassets"]
        ),
        .testTarget(
            name: "VideohubOnSetTests",
            dependencies: ["VideohubOnSet"],
            path: "VideohubOnSetTests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ],
    swiftLanguageVersions: [.v5]
)
