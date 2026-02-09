// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "voxflow-local",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoxFlowLocal", targets: ["VoxFlowApp"])
    ],
    targets: [
        .executableTarget(
            name: "VoxFlowApp",
            path: "Sources/VoxFlowApp"
        ),
        .testTarget(
            name: "VoxFlowAppTests",
            dependencies: ["VoxFlowApp"],
            path: "Tests/VoxFlowAppTests"
        )
    ]
)
