// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GPConnect",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gpconnect", targets: ["gpconnect-cli"]),
    ],
    targets: [
        .executableTarget(
            name: "gpconnect-cli",
            path: "CLI"
        )
    ]
)
