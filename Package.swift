// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ParaEQ",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ParaEQ",
            path: "Sources"
        )
    ]
)
