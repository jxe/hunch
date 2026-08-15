// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Quagmire",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "Quagmire", targets: ["Quagmire"])
    ],
    dependencies: [
        .package(url: "https://github.com/danielsaidi/EmojiKit.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "Quagmire",
            dependencies: [
                .product(name: "EmojiKit", package: "EmojiKit")
            ],
            resources: [.process("Resources/Sounds")]
        ),
        .testTarget(
            name: "QuagmireTests",
            dependencies: ["Quagmire"]
        ),
        .testTarget(
            name: "QuagmirePublicAPITests",
            dependencies: ["Quagmire"]
        )
    ],
    swiftLanguageModes: [.v6]
)
