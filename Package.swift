// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EPUBEdit",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "EPUBEdit", targets: ["EPUBEdit"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "EPUBCore", dependencies: ["CZlib"]),
        .executableTarget(
            name: "EPUBEdit",
            dependencies: ["EPUBCore"],
            path: "App",
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "EPUBCoreTests", dependencies: ["EPUBCore"]),
        .testTarget(name: "EPUBServiceTests", dependencies: ["EPUBEdit"])
    ],
    swiftLanguageModes: [.v5]
)
