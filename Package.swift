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
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoxFlowApp",
            dependencies: [
                "VoxFlowObjCSupport",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/VoxFlowApp"
        ),
        // Objective-C only because Swift cannot catch NSException: it wraps
        // AVAudioEngine calls that raise (see VFCatchObjCException).
        .target(
            name: "VoxFlowObjCSupport",
            path: "Sources/VoxFlowObjCSupport"
        ),
        .testTarget(
            name: "VoxFlowAppTests",
            dependencies: ["VoxFlowApp"],
            path: "Tests/VoxFlowAppTests"
        )
    ]
)
