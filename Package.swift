// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NtfyMe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NtfyKit", targets: ["NtfyKit"]),
        .executable(name: "NtfyMe", targets: ["NtfyMe"]),
    ],
    dependencies: [
        // Auto-updates for GitHub-binary distribution. The de-facto standard
        // for non-App-Store Mac apps; consumed via `Updater.swift` in the
        // app target and embedded by `Scripts/build-app.sh`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "NtfyKit"),
        .executableTarget(name: "NtfyMe", dependencies: ["NtfyKit", "Sparkle"]),
        .testTarget(
            name: "NtfyKitTests",
            dependencies: ["NtfyKit"],
            // A store written by an older schema, used to prove the current
            // schema can still open it. See SchemaMigrationSafetyTests.
            resources: [.copy("Fixtures")]),
        .testTarget(name: "NtfyMeTests", dependencies: ["NtfyMe"]),
    ]
)
