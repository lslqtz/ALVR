// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ALVREncoderHelper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ALVREncoderHelper",
            path: "Sources/ALVREncoderHelper"
        ),
    ]
)
