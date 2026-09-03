// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NtfyMe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NtfyKit", targets: ["NtfyKit"]),
        .executable(name: "NtfyMe", targets: ["NtfyMe"]),
    ],
    targets: [
        .target(name: "NtfyKit"),
        .executableTarget(name: "NtfyMe", dependencies: ["NtfyKit"]),
        .testTarget(
            name: "NtfyKitTests",
            dependencies: ["NtfyKit"],
            // A store written by an older schema, used to prove the current
            // schema can still open it. See SchemaMigrationSafetyTests.
            resources: [.copy("Fixtures")]),
        .testTarget(name: "NtfyMeTests", dependencies: ["NtfyMe"]),
    ]
)
