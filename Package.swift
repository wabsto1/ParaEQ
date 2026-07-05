// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParaEQ",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "ParaEQ",
            path: "Sources"
        ),
        .executableTarget(
            name: "TapProto",
            path: "Prototypes/TapProto",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ParaEQTests",
            dependencies: ["ParaEQ"],
            path: "Tests/ParaEQTests"
        )
    ]
)
