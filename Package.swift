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
    platforms: [.macOS(.v14), .iOS("27.0")],
    products: [
        .executable(name: "MusicLibrary", targets: ["MusicLibrary"]),
        .library(name: "MusicLibraryCore", targets: ["MusicLibraryCore"]),
    ],
    targets: [
        .target(name: "MusicLibraryCore"),
        .executableTarget(name: "MusicLibrary", dependencies: ["MusicLibraryCore"]),
        .testTarget(
            name: "MusicLibraryCoreTests",
            dependencies: ["MusicLibraryCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings
        ),
    ]
)
