// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cala",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cala", path: "Sources/Cala",
                          linkerSettings: [.linkedFramework("OpenDirectory")])
    ]
)
