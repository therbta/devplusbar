// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevPlusBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DevPlusBar",
            dependencies: [.product(name: "Defaults", package: "Defaults")],
            path: "Sources/DevPlusBar"
        ),
        .testTarget(
            name: "DevPlusBarTests",
            dependencies: ["DevPlusBar"],
            path: "Tests/DevPlusBarTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
