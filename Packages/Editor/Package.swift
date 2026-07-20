// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Editor",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "Editor", type: .static, targets: ["Editor"])
    ],
    dependencies: [
        .package(url: "https://github.com/danielsaidi/EmojiKit.git", exact: "3.0.0")
    ],
    targets: [
        .target(
            name: "Editor",
            dependencies: [
                .product(name: "EmojiKit", package: "EmojiKit")
            ],
            resources: [.process("Resources/Sounds")]
        ),
        .testTarget(
            name: "EditorTests",
            dependencies: ["Editor"]
        )
    ],
    swiftLanguageModes: [.v6]
)
