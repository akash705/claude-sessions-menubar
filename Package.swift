// swift-tools-version:5.9
import PackageDescription

// This Package.swift is a *compile-check* harness — it lets `swift build` type-check
// all sources without needing Xcode. For running as a proper menubar app, build the
// Xcode project (see project.yml for XcodeGen, or add the sources to a new Xcode
// macOS App target).
let package = Package(
    name: "ClaudeSessions",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSessions",
            path: "ClaudeSessions",
            exclude: ["Info.plist"]
        )
    ]
)
