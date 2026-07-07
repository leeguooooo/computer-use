// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "opencua",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "opencua",
            path: "Sources/opencua"
        )
    ]
)
