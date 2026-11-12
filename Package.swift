// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Trainspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Trainspace", targets: ["Trainspace"]),
    ],
    dependencies: [
        // Updates for the direct download. Pinned; SwiftPM checks the framework's checksum.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "TrainspaceCore"),
        .executableTarget(
            name: "Trainspace",
            dependencies: ["TrainspaceCore", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle keeps Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "TrainspaceCoreTests",
            dependencies: ["TrainspaceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
