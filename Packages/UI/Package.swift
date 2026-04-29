// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UI",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "UI", targets: ["UI"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "UI",
            dependencies: [
                .product(name: "Core", package: "Core")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
