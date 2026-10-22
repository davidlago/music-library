// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed, SwiftPM does not pass the swift-testing macro plugin path to the
// compiler. Xcode's toolchain finds it on its own (and is what CI uses), so only add it without Xcode.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let usesCommandLineTools = !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
let testSwiftSettings: [SwiftSetting] = usesCommandLineTools && FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "MusicLibrary",
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .executable(name: "MusicLibrary", targets: ["MusicLibrary"]),
        .library(name: "MusicLibraryCore", targets: ["MusicLibraryCore"]),
        // What the iPhone's widgets and the watch app show; Foundation only, so they don't need the core.
        .library(name: "MusicLibraryGlance", targets: ["MusicLibraryGlance"]),
    ],
    targets: [
        .target(name: "MusicLibraryGlance"),
        .target(name: "MusicLibraryCore", dependencies: ["MusicLibraryGlance"]),
        .executableTarget(name: "MusicLibrary", dependencies: ["MusicLibraryCore"]),
        // Makes the iPhone app's sample library (scripts/make-sample-library.sh).
        .executableTarget(name: "SampleLibraryMaker", dependencies: ["MusicLibraryCore"]),
        .testTarget(
            name: "MusicLibraryCoreTests",
            dependencies: ["MusicLibraryCore", "MusicLibraryGlance"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        ),
    ]
)
