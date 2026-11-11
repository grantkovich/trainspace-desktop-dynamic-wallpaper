// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Trainspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Trainspace", targets: ["Trainspace"]),
    ],
    targets: [
        .target(name: "TrainspaceCore"),
        .executableTarget(name: "Trainspace", dependencies: ["TrainspaceCore"]),
        .testTarget(
            name: "TrainspaceCoreTests",
            dependencies: ["TrainspaceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
